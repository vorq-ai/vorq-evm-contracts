import { describe, it, expect, beforeAll, beforeEach, afterAll } from "vitest";
import http from "node:http";
import { startProxy } from "../src/proxy";

let upstream: http.Server; let proxyClose: () => Promise<void>; let base: string;

/** Every JSON-RPC payload the stub upstream received during the current test, in order. */
const seen: any[] = [];
/** The stub's `eth_blockNumber` answer: block 196608, so any tag resolves far past the cap. */
const HEAD = "0x30000";
/**
 * The stub's `safe` and `finalized` heads, deliberately *behind* `latest` by the 32/64 blocks a
 * default-epoch chain lags by. That gap is the whole point: a span measured against the wrong
 * head is off by exactly it, and every tag-resolution test below is sized to fall in the gap.
 */
const FINALIZED = 0x30000 - 64; // 196544
const SAFE = 0x30000 - 32; // 196576
const hex = (n: number) => `0x${n.toString(16)}`;

// `: Promise<any>` only because Response.json() is typed `unknown`; the assertions below
// read the decoded JSON-RPC answer directly.
const rpc = (body: unknown): Promise<any> =>
  fetch(base, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) })
    .then(r => r.json());

/** Same POST, but with the body sent as given — for payloads that are not valid JSON. */
const rawRpc = (body: string) =>
  fetch(base, { method: "POST", headers: { "content-type": "application/json" }, body })
    .then(r => r.text());

/** Every entry the upstream saw, batches flattened. */
const upstreamEntries = () => seen.flatMap(b => (Array.isArray(b) ? b : [b]));
const blockNumberCalls = () => upstreamEntries().filter(m => m?.method === "eth_blockNumber").length;

beforeAll(async () => {
  upstream = http.createServer((req, res) => {
    let raw = ""; req.on("data", c => (raw += c));
    req.on("end", () => {
      res.setHeader("content-type", "application/json");
      let b: any;
      try { b = JSON.parse(raw); } catch {
        // A real node answers an unparseable body itself; recording it proves it got there.
        seen.push({ unparseable: raw });
        res.end(JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } }));
        return;
      }
      seen.push(b);
      const one = (m: any) => {
        if (m.method === "eth_blockNumber") return { jsonrpc: "2.0", id: m.id, result: HEAD };
        if (m.method === "eth_getBlockByNumber") {
          const tag = Array.isArray(m.params) ? m.params[0] : undefined;
          const number = tag === "finalized" ? hex(FINALIZED) : tag === "safe" ? hex(SAFE) : HEAD;
          return { jsonrpc: "2.0", id: m.id, result: { number } };
        }
        return { jsonrpc: "2.0", id: m.id, result: "ok" };
      };
      res.end(JSON.stringify(Array.isArray(b) ? b.map(one) : one(b)));
    });
  }).listen(0);
  const port = (upstream.address() as any).port;
  const p = await startProxy({ anvilUrl: `http://localhost:${port}`, port: 0, rangeCap: 5000 });
  base = `http://localhost:${p.port}`; proxyClose = p.close;
});
afterAll(async () => { await proxyClose(); upstream.close(); });
beforeEach(() => { seen.length = 0; });

describe("range-cap proxy", () => {
  it("forwards eth_call untouched", async () => {
    const r = await rpc({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [] });
    expect(r.result).toBe("ok");
  });
  it("caps oversized eth_getLogs with -32005", async () => {
    const r = await rpc({ jsonrpc: "2.0", id: 2, method: "eth_getLogs",
      params: [{ fromBlock: "0x0", toBlock: "0x2710" }] }); // 10001 > 5000
    expect(r.error.code).toBe(-32005);
  });
  it("passes eth_getLogs at or under the cap", async () => {
    const r = await rpc({ jsonrpc: "2.0", id: 3, method: "eth_getLogs",
      params: [{ fromBlock: "0x1", toBlock: "0x1388" }] }); // exactly 5000
    expect(r.result).toBe("ok");
  });
  it("applies the cap per-entry inside a batch", async () => {
    const r = await rpc([
      { jsonrpc: "2.0", id: 4, method: "eth_getLogs", params: [{ fromBlock: "0x0", toBlock: "0xffff" }] },
      { jsonrpc: "2.0", id: 5, method: "eth_chainId", params: [] },
    ]);
    expect(r.find((x: any) => x.id === 4).error.code).toBe(-32005);
    expect(r.find((x: any) => x.id === 5).result).toBe("ok");
  });

  it("answers the cap entirely itself, with the exact error object", async () => {
    const r = await rpc({ jsonrpc: "2.0", id: "cap", method: "eth_getLogs",
      params: [{ fromBlock: "0x0", toBlock: "0x2710" }] });
    expect(r).toEqual({
      jsonrpc: "2.0",
      id: "cap",
      error: { code: -32005, message: "block range exceeded: cap 5000" },
    });
    expect(seen).toEqual([]); // never forwarded — the proxy refused it on its own
  });

  it("makes the inclusive boundary exactly RANGE_CAP blocks", async () => {
    const at = await rpc({ jsonrpc: "2.0", id: 1, method: "eth_getLogs",
      params: [{ fromBlock: "0x0", toBlock: "0x1387" }] }); // 0..4999 = 5000 blocks
    const exact = await rpc({ jsonrpc: "2.0", id: 2, method: "eth_getLogs",
      params: [{ fromBlock: "0x64", toBlock: "0x13eb" }] }); // 100..5099 = 5000 blocks
    const over = await rpc({ jsonrpc: "2.0", id: 3, method: "eth_getLogs",
      params: [{ fromBlock: "0x0", toBlock: "0x1388" }] }); // 0..5000 = 5001 blocks
    expect(at.result).toBe("ok");
    expect(exact.result).toBe("ok");
    expect(over.error.code).toBe(-32005);
  });

  it("accepts decimal quantities as well as hex", async () => {
    const under = await rpc({ jsonrpc: "2.0", id: 1, method: "eth_getLogs",
      params: [{ fromBlock: 1, toBlock: 5000 }] }); // 5000 blocks
    const over = await rpc({ jsonrpc: "2.0", id: 2, method: "eth_getLogs",
      params: [{ fromBlock: "1", toBlock: "5001" }] }); // 5001 blocks
    expect(under.result).toBe("ok");
    expect(over.error.code).toBe(-32005);
  });

  it("treats a missing fromBlock as block 0", async () => {
    const over = await rpc({ jsonrpc: "2.0", id: 1, method: "eth_getLogs",
      params: [{ toBlock: "0x2710" }] }); // 0..10000
    const under = await rpc({ jsonrpc: "2.0", id: 2, method: "eth_getLogs",
      params: [{ toBlock: "0x100" }] }); // 0..256
    expect(over.error.code).toBe(-32005);
    expect(under.result).toBe("ok");
  });

  // Ambiguity 15, shape 1: a missing toBlock resolves to latest *before* the cap check.
  it("resolves a missing toBlock to latest before checking the cap", async () => {
    const over = await rpc({ jsonrpc: "2.0", id: 1, method: "eth_getLogs",
      params: [{ fromBlock: "0x0" }] }); // 0..head(196608)
    expect(over.error.code).toBe(-32005);
    expect(blockNumberCalls()).toBe(1);

    seen.length = 0;
    const under = await rpc({ jsonrpc: "2.0", id: 2, method: "eth_getLogs",
      params: [{ fromBlock: "0x2ff00" }] }); // 196352..head(196608) = 257 blocks
    expect(under.result).toBe("ok");
    expect(blockNumberCalls()).toBe(1);
  });

  it("resolves every head tag with one upstream eth_blockNumber per request", async () => {
    const r = await rpc([
      { jsonrpc: "2.0", id: 1, method: "eth_getLogs", params: [{ fromBlock: "0x0", toBlock: "latest" }] },
      { jsonrpc: "2.0", id: 2, method: "eth_getLogs", params: [{ fromBlock: "0x0", toBlock: "finalized" }] },
      { jsonrpc: "2.0", id: 3, method: "eth_getLogs", params: [{ fromBlock: "0x0", toBlock: "pending" }] },
      { jsonrpc: "2.0", id: 4, method: "eth_getLogs", params: [{ fromBlock: "0x0", toBlock: "safe" }] },
      { jsonrpc: "2.0", id: 5, method: "eth_getLogs", params: [{ fromBlock: "latest", toBlock: "latest" }] },
    ]);
    expect(r.map((x: any) => x.error?.code)).toEqual([-32005, -32005, -32005, -32005, undefined]);
    expect(r.find((x: any) => x.id === 5).result).toBe("ok"); // head..head = 1 block
    expect(blockNumberCalls()).toBe(1);
  });

  // The cap has to measure the span the caller actually asked for. `finalized` and `safe` are
  // their own heights, not `latest`, and on this devnet they sit 64 and 32 blocks behind it —
  // so a proxy that resolved them to `latest` would refuse compliant windows and wave oversized
  // ones through. These pin the resolution, not the lag: the stub's gap stands in for whatever
  // the live chain's is.
  it("measures a finalized-tagged span against the finalized head, not latest", async () => {
    // exactly RANGE_CAP against `finalized`; 5064 blocks against `latest`, which would be refused
    const at = await rpc({ jsonrpc: "2.0", id: 1, method: "eth_getLogs",
      params: [{ fromBlock: hex(FINALIZED - 4999), toBlock: "finalized" }] });
    expect(at.result).toBe("ok");
    expect(blockNumberCalls()).toBe(0); // finalized comes off the header, not eth_blockNumber
  });

  it("keeps the inclusive boundary on a finalized-tagged span", async () => {
    const over = await rpc({ jsonrpc: "2.0", id: 1, method: "eth_getLogs",
      params: [{ fromBlock: hex(FINALIZED - 5000), toBlock: "finalized" }] }); // 5001 blocks
    expect(over.error.code).toBe(-32005);
    expect(over.error.message).toBe("block range exceeded: cap 5000");
  });

  it("measures a safe-tagged span against the safe head", async () => {
    const at = await rpc({ jsonrpc: "2.0", id: 1, method: "eth_getLogs",
      params: [{ fromBlock: hex(SAFE - 4999), toBlock: "safe" }] }); // exactly 5000
    const over = await rpc({ jsonrpc: "2.0", id: 2, method: "eth_getLogs",
      params: [{ fromBlock: hex(SAFE - 5000), toBlock: "safe" }] }); // 5001
    expect(at.result).toBe("ok");
    expect(over.error.code).toBe(-32005);
  });

  it("resolves a fromBlock tag too, not only toBlock", async () => {
    // finalized..latest is the 64-block gap plus one — comfortably inside the cap, and only
    // measurable at all if the *lower* bound resolves to the finalized head.
    const r = await rpc({ jsonrpc: "2.0", id: 1, method: "eth_getLogs",
      params: [{ fromBlock: "finalized", toBlock: "latest" }] });
    expect(r.result).toBe("ok");
  });

  it("resolves every distinct tag in a batch in one upstream round trip", async () => {
    const r = await rpc([
      { jsonrpc: "2.0", id: 1, method: "eth_getLogs",
        params: [{ fromBlock: hex(FINALIZED - 4999), toBlock: "finalized" }] }, // 5000, passes
      { jsonrpc: "2.0", id: 2, method: "eth_getLogs",
        params: [{ fromBlock: hex(FINALIZED - 5000), toBlock: "finalized" }] }, // 5001, capped
      { jsonrpc: "2.0", id: 3, method: "eth_getLogs",
        params: [{ fromBlock: hex(SAFE - 4999), toBlock: "safe" }] }, // 5000, passes
      { jsonrpc: "2.0", id: 4, method: "eth_getLogs", params: [{ fromBlock: "0x0" }] }, // capped
    ]);
    expect(r.map((x: any) => x.error?.code)).toEqual([undefined, -32005, undefined, -32005]);
    expect(blockNumberCalls()).toBe(1); // still exactly one, for the two `latest`-shaped bounds
    // one resolution round trip carrying all three lookups, then one forwarded batch
    expect(seen.length).toBe(2);
    expect(upstreamEntries().filter(m => m?.method === "eth_getBlockByNumber").map(m => m.params[0]))
      .toEqual(["safe", "finalized"]);
  });

  it("makes no upstream eth_blockNumber when nothing needs the head", async () => {
    const body = { jsonrpc: "2.0", id: 1, method: "eth_getLogs", params: [{ fromBlock: "0x0", toBlock: "0x10" }] };
    const r = await rpc(body);
    expect(r.result).toBe("ok");
    expect(blockNumberCalls()).toBe(0);
    expect(seen).toEqual([body]); // forwarded verbatim, nothing else sent
  });

  // Ambiguity 15, shape 2: a blockHash filter names one block, so no range applies.
  it("forwards blockHash-form filters untouched", async () => {
    const body = {
      jsonrpc: "2.0", id: 1, method: "eth_getLogs",
      params: [{ blockHash: `0x${"ab".repeat(32)}`, address: "0x0000000000000000000000000000000000000001", topics: [null] }],
    };
    const r = await rpc(body);
    expect(r.result).toBe("ok");
    expect(seen).toEqual([body]);
    expect(blockNumberCalls()).toBe(0);
  });

  // Ambiguity 15, shape 3: params the proxy does not recognise go to the chain unchanged.
  it("forwards malformed eth_getLogs params and lets the chain answer", async () => {
    const shapes: unknown[] = [
      [],
      "nonsense",
      [`0x${"cd".repeat(32)}`],
      [{ fromBlock: {}, toBlock: [] }],
      [{ fromBlock: "0xnothex", toBlock: "0x10" }],
      [{ fromBlock: "0x0", toBlock: "whenever" }],
      [null],
    ];
    for (const params of shapes) {
      seen.length = 0;
      const body = { jsonrpc: "2.0", id: 1, method: "eth_getLogs", params };
      const r = await rpc(body);
      expect(r, `params ${JSON.stringify(params)}`).toEqual({ jsonrpc: "2.0", id: 1, result: "ok" });
      expect(seen, `params ${JSON.stringify(params)}`).toEqual([body]);
    }
  });

  it("inspects only eth_getLogs, never a getLogs-shaped sibling method", async () => {
    const oversized = [{ fromBlock: "0x0", toBlock: "0x30000" }];
    for (const method of ["eth_getFilterLogs", "eth_newFilter", "eth_getlogs", "getLogs"]) {
      seen.length = 0;
      const body = { jsonrpc: "2.0", id: 1, method, params: oversized };
      const r = await rpc(body);
      expect(r.result, method).toBe("ok");
      expect(seen, method).toEqual([body]);
    }
  });

  it("keeps every surviving sibling in a batch, in order, with its id", async () => {
    const r = await rpc([
      { jsonrpc: "2.0", id: "a", method: "eth_getLogs", params: [{ fromBlock: "0x0", toBlock: "0x30000" }] },
      { jsonrpc: "2.0", id: 0, method: "net_version", params: [] },
      { jsonrpc: "2.0", id: null, method: "eth_getLogs", params: [{ fromBlock: "0x0", toBlock: "0x10" }] },
      { jsonrpc: "2.0", id: 7, method: "eth_getLogs", params: [{ fromBlock: "0x0" }] },
      { jsonrpc: "2.0", id: 8, method: "eth_chainId", params: [] },
    ]);
    expect(r).toEqual([
      { jsonrpc: "2.0", id: "a", error: { code: -32005, message: "block range exceeded: cap 5000" } },
      { jsonrpc: "2.0", id: 0, result: "ok" },
      { jsonrpc: "2.0", id: null, result: "ok" },
      { jsonrpc: "2.0", id: 7, error: { code: -32005, message: "block range exceeded: cap 5000" } },
      { jsonrpc: "2.0", id: 8, result: "ok" },
    ]);
    // The head resolution plus one forwarded batch of the three survivors — nothing more.
    expect(blockNumberCalls()).toBe(1);
    expect(upstreamEntries().map(m => m.method))
      .toEqual(["eth_blockNumber", "net_version", "eth_getLogs", "eth_chainId"]);
  });

  it("answers a batch whose every entry is capped without touching the chain", async () => {
    const r = await rpc([
      { jsonrpc: "2.0", id: 1, method: "eth_getLogs", params: [{ fromBlock: "0x0", toBlock: "0x2710" }] },
      { jsonrpc: "2.0", id: 2, method: "eth_getLogs", params: [{ fromBlock: "0x0", toBlock: "0x2711" }] },
    ]);
    expect(r.map((x: any) => x.error.code)).toEqual([-32005, -32005]);
    expect(seen).toEqual([]);
  });

  it("forwards an unparseable body for the chain to answer", async () => {
    const text = await rawRpc("{not json at all");
    expect(JSON.parse(text).error.code).toBe(-32700);
    expect(seen).toEqual([{ unparseable: "{not json at all" }]);
  });
});

// `:8545` exists to be chain-shaped: code written against it has to work unchanged on a real
// network, and no real network has `anvil_*`, `evm_*` or `hardhat_*`. They stay available on the
// direct port, which is where the boot deploy's `anvil_setCode` runs.
describe("test-only namespaces on the chain-shaped port", () => {
  it("refuses anvil_, evm_ and hardhat_ with -32601 and never forwards them", async () => {
    for (const method of ["anvil_setCode", "anvil_mine", "evm_mine", "evm_setNextBlockTimestamp",
      "hardhat_setBalance", "hardhat_impersonateAccount"]) {
      seen.length = 0;
      const r = await rpc({ jsonrpc: "2.0", id: 1, method, params: [] });
      expect(r, method).toEqual({
        jsonrpc: "2.0",
        id: 1,
        error: {
          code: -32601,
          message: `method not found: ${method} is a test-only namespace and is not exposed on this RPC`,
        },
      });
      expect(seen, method).toEqual([]);
    }
  });

  it("refuses per entry inside a batch, leaving its siblings answered", async () => {
    const r = await rpc([
      { jsonrpc: "2.0", id: "a", method: "anvil_setCode", params: [] },
      { jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] },
      { jsonrpc: "2.0", id: null, method: "evm_mine", params: [] },
      { jsonrpc: "2.0", id: 2, method: "eth_getLogs", params: [{ fromBlock: "0x0", toBlock: "0x30000" }] },
      { jsonrpc: "2.0", id: 3, method: "eth_getLogs", params: [{ fromBlock: "0x0", toBlock: "0x10" }] },
    ]);
    expect(r.map((x: any) => x.error?.code)).toEqual([-32601, undefined, -32601, -32005, undefined]);
    expect(r.map((x: any) => x.id)).toEqual(["a", 1, null, 2, 3]);
    expect(upstreamEntries().map(m => m.method)).toEqual(["eth_chainId", "eth_getLogs"]);
  });

  it("answers a batch of nothing but test-only calls without touching the chain", async () => {
    const r = await rpc([
      { jsonrpc: "2.0", id: 1, method: "anvil_mine", params: [] },
      { jsonrpc: "2.0", id: 2, method: "hardhat_reset", params: [] },
    ]);
    expect(r.map((x: any) => x.error.code)).toEqual([-32601, -32601]);
    expect(seen).toEqual([]);
  });

  it("matches the namespace prefix exactly, and forwards anything else", async () => {
    for (const method of ["anvilx_setCode", "eth_anvil_setCode", "web3_clientVersion", "evmish_mine"]) {
      seen.length = 0;
      const body = { jsonrpc: "2.0", id: 1, method, params: [] };
      const r = await rpc(body);
      expect(r.result, method).toBe("ok");
      expect(seen, method).toEqual([body]);
    }
  });
});

// The two paths where the proxy stops being a pass-through and decides something itself: a head
// it could not resolve, and an upstream it could not reach. Both need an upstream that misbehaves
// on purpose, so each test stands up its own pair and tears it down again.
describe("range-cap proxy against a broken upstream", () => {
  const post = (url: string, body: unknown) =>
    fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });

  it("FAILS OPEN when the chain head cannot be resolved: an open-ended query is forwarded, not capped", async () => {
    // `chainHead()` swallows every upstream failure into `undefined`, and `exceedsCap` then has no
    // `to` to compare against, so it answers false and the entry is forwarded uncapped. That is
    // the choice, not an accident: an open-ended range whose span is unknown might well be inside
    // the cap, and inventing a -32005 for it would refuse a query the chain would have answered.
    // This test pins the direction so a later change to `chainHead` cannot flip it unnoticed.
    let headMode: "not-json" | "not-a-quantity" = "not-json";
    const forwarded: any[] = [];
    const upstream = http.createServer((req, res) => {
      let raw = ""; req.on("data", c => (raw += c));
      req.on("end", () => {
        const body = JSON.parse(raw);
        const entries = Array.isArray(body) ? body : [body];
        if (entries.some((e: any) => e?.method === "eth_blockNumber")) {
          // the two ways a head lookup comes back useless: an answer that is not JSON at all
          // (`chainHead`'s catch) and one whose result is not a quantity (its `blockNumber`
          // call). Both end up as `undefined`, which is the whole point.
          res.setHeader("content-type", "application/json");
          res.end(headMode === "not-json"
            ? "<html>502 Bad Gateway</html>"
            : JSON.stringify({ jsonrpc: "2.0", id: 0, result: "not-a-quantity" }));
          return;
        }
        forwarded.push(body);
        res.setHeader("content-type", "application/json");
        res.end(JSON.stringify({ jsonrpc: "2.0", id: body.id, result: "ok" }));
      });
    }).listen(0);
    const proxy = await startProxy({
      anvilUrl: `http://localhost:${(upstream.address() as any).port}`, port: 0, rangeCap: 5000,
    });
    try {
      for (const mode of ["not-json", "not-a-quantity"] as const) {
        headMode = mode; forwarded.length = 0;
        // no toBlock, so the span is 0..head — unbounded as far as this proxy can tell
        const body = { jsonrpc: "2.0", id: 1, method: "eth_getLogs", params: [{ fromBlock: "0x0" }] };
        expect(await (await post(`http://localhost:${proxy.port}`, body)).json(), mode)
          .toEqual({ jsonrpc: "2.0", id: 1, result: "ok" });
        expect(forwarded, mode).toEqual([body]);
      }
    } finally {
      await proxy.close();
      upstream.close();
    }
  });

  it("FAILS OPEN on a tag the chain will not resolve: the entry is forwarded, not capped", async () => {
    // A node with no finalized block answers `eth_getBlockByNumber("finalized")` with `null`.
    // There is then no lower bound to measure, so the span is unknown — and an unknown span
    // must never become an invented -32005, exactly as for an unresolvable head.
    const forwarded: any[] = [];
    const upstream = http.createServer((req, res) => {
      let raw = ""; req.on("data", c => (raw += c));
      req.on("end", () => {
        const body = JSON.parse(raw);
        const entries = Array.isArray(body) ? body : [body];
        res.setHeader("content-type", "application/json");
        if (entries.some((e: any) => e?.method === "eth_getBlockByNumber")) {
          res.end(JSON.stringify(entries.map((e: any) => ({ jsonrpc: "2.0", id: e.id, result: null }))[0]));
          return;
        }
        forwarded.push(body);
        res.end(JSON.stringify({ jsonrpc: "2.0", id: body.id, result: "ok" }));
      });
    }).listen(0);
    const proxy = await startProxy({
      anvilUrl: `http://localhost:${(upstream.address() as any).port}`, port: 0, rangeCap: 5000,
    });
    try {
      const body = { jsonrpc: "2.0", id: 1, method: "eth_getLogs",
        params: [{ fromBlock: "finalized", toBlock: "0x30000" }] };
      expect(await (await post(`http://localhost:${proxy.port}`, body)).json())
        .toEqual({ jsonrpc: "2.0", id: 1, result: "ok" });
      expect(forwarded).toEqual([body]);
    } finally {
      await proxy.close();
      upstream.close();
    }
  });

  it("answers -32603 at HTTP 502 when the upstream cannot be reached", async () => {
    // The only error this proxy invents besides the cap one, and the one that says
    // "infrastructure, not your query". Point it at a port nothing is listening on.
    const closed = http.createServer().listen(0);
    const deadPort = (closed.address() as any).port;
    await new Promise<void>(done => closed.close(() => done()));
    const proxy = await startProxy({ anvilUrl: `http://localhost:${deadPort}`, port: 0, rangeCap: 5000 });
    try {
      const answer = await post(`http://localhost:${proxy.port}`,
        { jsonrpc: "2.0", id: 9, method: "eth_chainId", params: [] });
      expect(answer.status).toBe(502);
      expect(await answer.json()).toEqual({
        jsonrpc: "2.0", id: null, error: { code: -32603, message: "upstream request failed" },
      });
    } finally {
      await proxy.close();
    }
  });

  it("says nothing at all when the upstream dies after the answer has started", async () => {
    // The other half of the same handler: `headersSent || writableEnded || destroyed` is what
    // stops it appending a 502 body to a 200 response already in flight. A client sees a broken
    // read, which is the truth, rather than a JSON-RPC error object glued onto partial results.
    const upstream = http.createServer((req, res) => {
      req.on("data", () => {});
      req.on("end", () => {
        res.writeHead(200, { "content-type": "application/json" });
        res.write('{"jsonrpc":"2.0","id":1,"result":[');
        // the delay is load-bearing: it lets the proxy receive these headers and commit its own
        // before the body breaks, which is the only state in which the guard has anything to do
        setTimeout(() => res.socket?.destroy(), 60);
      });
    }).listen(0);
    const proxy = await startProxy({
      anvilUrl: `http://localhost:${(upstream.address() as any).port}`, port: 0, rangeCap: 5000,
    });
    try {
      const answer = await post(`http://localhost:${proxy.port}`,
        { jsonrpc: "2.0", id: 1, method: "eth_getLogs", params: [{ fromBlock: "0x0", toBlock: "0x10" }] });
      expect(answer.status).toBe(200); // already committed before the upstream broke
      await expect(answer.text()).rejects.toThrow(); // and never rewritten into an error body
    } finally {
      await proxy.close();
      upstream.close();
    }
  });
});
