// A JSON-RPC proxy that gives the devnet two properties a bare Anvil does not have: the
// `eth_getLogs` block-range cap every real endpoint enforces, and the *absence* of the
// test-only `anvil_*` / `evm_*` / `hardhat_*` namespaces. Everything else is forwarded
// verbatim, so the chain behind this port is exactly the chain behind the direct one.
//
// The point is not to protect Anvil. It is that code written against an uncapped devnet —
// an indexer, a backfill, any log scan — silently fails the first time it meets a real
// endpoint. With the cap here, it has to chunk its queries to work at all; and with the
// test-only namespaces gone, it cannot quietly grow a dependency on a cheatcode either.
import http from "node:http";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { pathToFileURL } from "node:url";

/**
 * Block tags whose height only the chain knows. They are resolved to concrete numbers
 * *before* any span is measured, because they are not interchangeable: `finalized` and `safe`
 * trail `latest`, so measuring a `finalized`-bounded window against the latest head refuses
 * compliant queries and lets oversized ones through.
 */
const CHAIN_TAGS = new Set(["latest", "pending", "safe", "finalized"]);
/** JSON-RPC "limit exceeded" — what range-capped endpoints answer. */
const CAP_ERROR_CODE = -32005;
/** JSON-RPC "method not found" — what a chain without these namespaces answers. */
const METHOD_NOT_FOUND_CODE = -32601;
/** Namespaces that exist on a test node and nowhere else. */
const TEST_ONLY_PREFIXES = ["anvil_", "evm_", "hardhat_"];

export interface ProxyOptions {
  /** Upstream JSON-RPC endpoint. Every request ends up here. */
  anvilUrl: string;
  /** Port to listen on. `0` picks a free one, reported back as `port`. */
  port: number;
  /** Largest `eth_getLogs` span allowed through, in blocks, bounds inclusive. */
  rangeCap: number;
}

export interface RunningProxy {
  /** The port actually bound — the interesting case is `port: 0`. */
  port: number;
  close: () => Promise<void>;
}

/** Resolved heights, keyed by tag. A tag the chain would not answer is simply absent. */
type Heights = Map<string, bigint>;
const NO_HEIGHTS: Heights = new Map();

/**
 * A JSON-RPC quantity read as a block number: hex, decimal, or a block tag. `undefined`
 * means "not a shape this proxy understands, or a tag the chain would not resolve", which is
 * always the signal to forward the entry and let the chain answer — never to invent an error
 * of our own.
 */
function blockNumber(quantity: unknown, heights: Heights): bigint | undefined {
  if (typeof quantity === "number") {
    return Number.isSafeInteger(quantity) && quantity >= 0 ? BigInt(quantity) : undefined;
  }
  if (typeof quantity !== "string") return undefined;
  if (quantity === "earliest") return 0n;
  if (CHAIN_TAGS.has(quantity)) return heights.get(quantity);
  return /^(0x[0-9a-fA-F]+|\d+)$/.test(quantity) ? BigInt(quantity) : undefined;
}

/**
 * The error this proxy answers a test-only method with, or `undefined` for every method a
 * real chain would recognise. Prefix match on the namespace, so `anvilx_` and
 * `eth_anvil_` are somebody else's methods and go to the chain.
 */
function testOnlyError(entry: any): { code: number; message: string } | undefined {
  const method = entry && typeof entry === "object" && !Array.isArray(entry) ? entry.method : undefined;
  if (typeof method !== "string") return undefined;
  if (!TEST_ONLY_PREFIXES.some(prefix => method.startsWith(prefix))) return undefined;
  return {
    code: METHOD_NOT_FOUND_CODE,
    message: `method not found: ${method} is a test-only namespace and is not exposed on this RPC`,
  };
}

/**
 * The filter object whose block range this proxy is responsible for, or `undefined` when the
 * entry has no such range: any other method, params in a shape we do not recognise, or a
 * `blockHash` filter — that names one single block, so no range applies to it.
 */
function rangeFilter(entry: any): any {
  if (!entry || typeof entry !== "object" || Array.isArray(entry)) return undefined;
  if (entry.method !== "eth_getLogs") return undefined;
  const filter = Array.isArray(entry.params) ? entry.params[0] : undefined;
  if (!filter || typeof filter !== "object" || Array.isArray(filter)) return undefined;
  return filter.blockHash === undefined || filter.blockHash === null ? filter : undefined;
}

/** The chain tags this filter's bounds are written in. A missing `toBlock` means `latest`. */
function chainTags(filter: any): string[] {
  const tags: string[] = [];
  for (const bound of [filter.fromBlock, filter.toBlock]) {
    if (typeof bound === "string" && CHAIN_TAGS.has(bound)) tags.push(bound);
  }
  if (filter.toBlock === undefined || filter.toBlock === null) tags.push("latest");
  return tags;
}

/** `toBlock − fromBlock + 1 > rangeCap`, with the defaults a real endpoint applies first. */
function exceedsCap(filter: any, heights: Heights, rangeCap: bigint): boolean {
  const fromMissing = filter.fromBlock === undefined || filter.fromBlock === null;
  const toMissing = filter.toBlock === undefined || filter.toBlock === null;
  const from = fromMissing ? 0n : blockNumber(filter.fromBlock, heights);
  const to = toMissing ? heights.get("latest") : blockNumber(filter.toBlock, heights);
  if (from === undefined || to === undefined) return false;
  return to - from + 1n > rangeCap;
}

export function startProxy(options: ProxyOptions): Promise<RunningProxy> {
  const { anvilUrl, rangeCap } = options;
  const cap = BigInt(rangeCap);
  const capError = { code: CAP_ERROR_CODE, message: `block range exceeded: cap ${rangeCap}` };

  const send = (body: string) =>
    fetch(anvilUrl, { method: "POST", headers: { "content-type": "application/json" }, body });

  /**
   * Every tag the request mentions, resolved in a single upstream round trip — not one per
   * tag, and not one per batch entry. `latest` and `pending` ride on the one `eth_blockNumber`
   * this proxy has always made; `safe` and `finalized` come off their own block header,
   * because they trail the head by an amount only the chain knows. A lookup that comes back
   * useless leaves its tag unresolved, which downgrades the entries using it to "forward it".
   */
  async function resolveTags(tags: Set<string>): Promise<Heights> {
    const heights: Heights = new Map();
    if (tags.size === 0) return heights;
    const wanted: string[] = [];
    const calls: any[] = [];
    const ask = (tag: string, method: string, params: unknown[]) => {
      calls.push({ jsonrpc: "2.0", id: wanted.length, method, params });
      wanted.push(tag);
    };
    // `pending` has always been read as the head here, and stays that way: the pending block
    // holds no logs yet, so as a log-range bound it is the head.
    if (tags.has("latest") || tags.has("pending")) ask("latest", "eth_blockNumber", []);
    for (const tag of ["safe", "finalized"]) {
      if (tags.has(tag)) ask(tag, "eth_getBlockByNumber", [tag, false]);
    }
    try {
      const answer: any = await (await send(JSON.stringify(calls.length === 1 ? calls[0] : calls))).json();
      for (const entry of Array.isArray(answer) ? answer : [answer]) {
        const tag = typeof entry?.id === "number" ? wanted[entry.id] : undefined;
        if (tag === undefined) continue;
        const raw = tag === "latest" ? entry.result : entry.result?.number;
        const height = blockNumber(raw, NO_HEIGHTS);
        if (height !== undefined) heights.set(tag, height);
      }
    } catch {
      return new Map(); // nothing resolved, so nothing is measured — every tagged entry forwards
    }
    const head = heights.get("latest");
    if (head !== undefined) heights.set("pending", head);
    return heights;
  }

  /**
   * Forward the bytes we were given and stream the answer straight back: on this path
   * nothing is parsed, re-serialised or held in memory, and ids survive byte for byte.
   */
  async function passThrough(raw: string, res: http.ServerResponse): Promise<void> {
    const upstream = await send(raw);
    // Deliberately not mirroring content-length or content-encoding: fetch has already
    // decoded the body, so the upstream's own values describe bytes we are not sending.
    res.writeHead(upstream.status, {
      "content-type": upstream.headers.get("content-type") ?? "application/json",
    });
    if (!upstream.body) {
      res.end();
      return;
    }
    await pipeline(Readable.fromWeb(upstream.body as any), res);
  }

  function respond(res: http.ServerResponse, status: number, body: string): void {
    res.writeHead(status, {
      "content-type": "application/json",
      "content-length": Buffer.byteLength(body),
    });
    res.end(body);
  }

  async function handle(raw: string, res: http.ServerResponse): Promise<void> {
    let payload: any;
    try {
      payload = JSON.parse(raw);
    } catch {
      return passThrough(raw, res); // not our business to answer — the chain does
    }

    const batch = Array.isArray(payload);
    const entries: any[] = batch ? payload : [payload];

    // Two reasons this proxy answers an entry itself instead of forwarding it: a method a real
    // chain does not have, and a range a real endpoint would not serve. Both are decided per
    // entry, before anything is sent upstream.
    const refusals = entries.map(testOnlyError);
    const filters = entries.map((entry, i) => (refusals[i] ? undefined : rangeFilter(entry)));
    const tags = new Set<string>();
    for (const filter of filters) {
      if (filter) for (const tag of chainTags(filter)) tags.add(tag);
    }
    const heights = await resolveTags(tags);
    const errors = filters.map((filter, i) =>
      refusals[i] ?? (filter && exceedsCap(filter, heights, cap) ? capError : undefined));
    if (!errors.some(Boolean)) return passThrough(raw, res);

    // Per-entry, so a refused query never takes its siblings down with it. A request whose
    // every entry is answered here needs no upstream call at all.
    const survivors = entries.filter((_, i) => !errors[i]);
    let answers: any[] = [];
    if (survivors.length > 0) {
      const answer: any = await (await send(JSON.stringify(batch ? survivors : survivors[0]))).json();
      answers = Array.isArray(answer) ? answer : [answer];
    }

    // Rebuilt in request order: a refused entry gets its error under its own id, every other
    // entry gets the next upstream answer. Should the upstream answer with more entries than
    // it was asked for, the extras are appended rather than dropped.
    const merged: any[] = [];
    let next = 0;
    entries.forEach((entry, i) => {
      const error = errors[i];
      if (error) merged.push({ jsonrpc: "2.0", id: entry.id ?? null, error });
      else if (next < answers.length) merged.push(answers[next++]);
    });
    merged.push(...answers.slice(next));

    respond(res, 200, JSON.stringify(batch ? merged : merged[0]));
  }

  const server = http.createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", chunk => chunks.push(chunk as Buffer));
    req.on("error", () => res.destroy());
    req.on("end", () => {
      handle(Buffer.concat(chunks).toString("utf8"), res).catch(() => {
        // The upstream is unreachable, or answered something that is not JSON. That is an
        // infrastructure failure rather than a rejected query, so it gets the standard
        // internal error — never the range-cap one. Nothing to say at all if the answer has
        // already started, or if the client gave up on us.
        if (res.headersSent || res.writableEnded || res.destroyed) {
          res.destroy();
          return;
        }
        const body = { jsonrpc: "2.0", id: null, error: { code: -32603, message: "upstream request failed" } };
        respond(res, 502, JSON.stringify(body));
      });
    });
  });

  return new Promise<RunningProxy>((resolve, reject) => {
    server.once("error", reject);
    server.listen(options.port, () => {
      const address = server.address();
      resolve({
        port: typeof address === "object" && address !== null ? address.port : options.port,
        close: () =>
          new Promise<void>((closed, failed) => {
            server.close(error => (error ? failed(error) : closed()));
            // Clients keep their sockets alive, and `close` alone waits for every one of them.
            server.closeAllConnections();
          }),
      });
    });
  });
}

function envInt(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 0) {
    console.error(`rpc-proxy: ${name} must be a non-negative integer, got "${raw}"`);
    process.exit(1);
  }
  return value;
}

async function main(): Promise<void> {
  const anvilUrl = process.env.ANVIL_URL;
  if (!anvilUrl) {
    console.error("rpc-proxy: ANVIL_URL is required — the upstream JSON-RPC endpoint to forward to");
    process.exit(1);
  }
  const rangeCap = envInt("RANGE_CAP", 5000);
  const running = await startProxy({ anvilUrl, port: envInt("PORT", 8545), rangeCap });
  console.log(`rpc-proxy: :${running.port} -> ${anvilUrl}, eth_getLogs range cap ${rangeCap} blocks`);
}

// Both a library (the tests import `startProxy`) and the container entrypoint.
if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
