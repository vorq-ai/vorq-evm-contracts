CONTRACTS := ..
# The published file, the one every consumer is told to read.
ADDRESSES := state/addresses.json
# What `SmokeFlow.s.sol` reads, because forge's fs-permission is scoped to the project root.
# The bootstrap makes them identical by copying one to the other, so they can only diverge
# when something else deployed — and the gate asserts that before it trusts either.
SCRIPT_ADDRESSES := $(CONTRACTS)/out-addresses/addresses.json
# The canonical fork RPC is the range-capped proxy on 8545. 8546 is the same chain direct
# and uncapped, for debugging — never for anything that has to work on a real network.
RPC_URL ?= http://localhost:8545

# Anvil's public dev keys #0-#4, the same literals fork/docker-compose.yml gives the bootstrap.
# SmokeFlow reads three of them: the client signs the order and the payment authorization, the
# provider operator signs claim and settle, and the deployer — the relayer — sends every
# transaction. Passed on the command line because SmokeFlow requires them with no defaults.
DEPLOYER_PK := 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
PROVIDER_PK := 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
CLIENT_PK   := 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a

.PHONY: up down smoke

# `up` is a start, not a reset: the bootstrap refuses to deploy twice onto the same chain, so
# coming up on a live stack is a no-op that prints "nothing to do". To start over, `make down`
# first — this is a throwaway fork and anvil keeps no state across a teardown.
#
# The first `up` of the day has to fetch the fork block's state from the public Base Sepolia
# RPC before anvil answers anything, which is minutes, not seconds.
#
# `deploy` is a one-shot service, and common Compose versions read an exited container as a
# failed one, so `up --wait` is not usable here. Gate on its exit status instead — the one
# signal that means the chain is ready — and bail out early when it is non-zero.
up:
	docker compose up -d --build
	@printf 'fork: waiting for the bootstrap '
	@i=0; while [ $$i -lt 600 ]; do \
		code=$$(docker inspect -f '{{if eq .State.Status "exited"}}{{.State.ExitCode}}{{end}}' \
			$$(docker compose ps -aq deploy) 2>/dev/null); \
		if [ "$$code" = "0" ]; then \
			printf '\n'; \
			docker compose logs --no-log-prefix deploy | tail -n 1; \
			test -f $(ADDRESSES) || { \
				printf 'fork: the bootstrap exited 0 but %s is missing\n' '$(ADDRESSES)'; exit 1; }; \
			printf 'fork: ready — RPC %s\n' '$(RPC_URL)'; exit 0; \
		fi; \
		if [ -n "$$code" ]; then \
			printf '\nfork: bootstrap failed (exit %s)\n' "$$code"; \
			docker compose logs --no-log-prefix deploy; \
			exit 1; \
		fi; \
		printf '.'; sleep 1; i=$$((i + 1)); \
	done; \
	printf '\nfork: timed out waiting for the bootstrap\n'; \
	docker compose logs --no-log-prefix deploy; \
	exit 1

# No `-v`: this stack has no named volumes — anvil's scratch is a tmpfs and `state/` is a bind
# mount — so `-v` would only ever reach across to somebody else's.
down:
	docker compose down --remove-orphans

# The acceptance gate: one real post -> claim -> submitAndSettle, signed the way the protocol
# signs and broadcast through the capped RPC, so what passes here works unchanged against a
# real range-capped endpoint. forge fails the run when a broadcast transaction reverts, so its
# exit status is the gate.
#
# --no-storage-caching is required, not cosmetic: 84532 is Base Sepolia, a chain foundry keeps
# an on-disk fork cache for, so without it this run can be served a slot another fork recorded
# at the same block height.
smoke:
	@test -f $(ADDRESSES) || { printf 'smoke: no %s — run make up first\n' '$(ADDRESSES)'; exit 1; }
	@test -f $(SCRIPT_ADDRESSES) || { \
		printf 'smoke: no %s — SmokeFlow reads that file, not %s. Run make up first.\n' \
			'$(SCRIPT_ADDRESSES)' '$(ADDRESSES)'; exit 1; }
	@cmp -s $(SCRIPT_ADDRESSES) $(ADDRESSES) || { \
		printf 'smoke: %s and %s disagree.\n' '$(SCRIPT_ADDRESSES)' '$(ADDRESSES)'; \
		printf '  SmokeFlow reads the first, every consumer reads the second, and the gate is\n'; \
		printf '  worthless while they differ. Something deployed outside the bootstrap —\n'; \
		printf '  most likely a host `forge script script/Deploy.s.sol`. Run make down && make up.\n'; \
		diff -u $(ADDRESSES) $(SCRIPT_ADDRESSES) || true; exit 1; }
	cd $(CONTRACTS) && DEPLOYER_PK=$(DEPLOYER_PK) PROVIDER_PK=$(PROVIDER_PK) CLIENT_PK=$(CLIENT_PK) \
		forge script script/SmokeFlow.s.sol --rpc-url $(RPC_URL) --broadcast --no-storage-caching
