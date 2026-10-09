# Network operations. Every target is dry-run by default: nothing is sent without BROADCAST=1,
# and BROADCAST=1 only works where the address book says `dev: true`. On every other network the
# scripts print `to` and `data` for the curation Safe and broadcast nothing.
#
# Target names are the contract's own function names, verbatim, so `grep setCapacityCeiling src`
# finds the code the command runs.

# The three variables every target reads. They are documented on comment lines rather than beside
# their assignments because make keeps the whitespace before a trailing `#` IN THE VALUE, which
# would put two spaces on the end of RPC. `help` scrapes these with the same `## ` convention it
# scrapes targets with, and strips the leading `# `.
# RPC:         ## RPC=https://…  REQUIRED, no default. Every op binds to a NETWORK'S address book
# BROADCAST:   ## BROADCAST=1, yes or true sends. Every other spelling, including unset, is a dry run
# CURATION_PK: ## REQUIRED to broadcast, no default. A Safe network broadcasts nothing, so it needs no key

# There is no default RPC, and that is the shape of the thing rather than caution. Every ops script
# resolves its addresses through `OpsBase._bookPath()`, which maps a CHAIN ID to a book under
# `deployments/` — and the local fork has none, because a fork's addresses are minted per stack and
# never written down. A default pointed at :8545 advertised a path that cannot work: the book read
# fails and the operator reads a missing-file error instead of "say which network".
RPC ?=

# --no-storage-caching on every script: a fork restarts at the same block numbers, and a slot
# cached from an earlier stack is a silent wrong answer.
#
# Recursive (`=`), not `:=`, so `need` runs when a RECIPE expands this rather than when make parses
# the file — which is what lets `help` and `ops-coverage`, neither of which touches a chain, run
# with no RPC at all while every forge target fails with the usage line.
FORGE = $(call need,RPC)forge script --rpc-url "$(RPC)" --no-storage-caching
OPS   = $(FORGE) script/ops/Curation.s.sol
READ  = $(FORGE) script/ops/Reads.s.sol

BROADCAST ?=
# An ALLOWLIST, so this fails closed. `$(if $(BROADCAST),…)` would test emptiness, not truth, so
# BROADCAST=0 would SEND; a `filter-out` of the lowercase spellings of "off" would let NO, False
# and FALSE send. Only the three spellings below broadcast, and every typo is a dry run.
_B := $(if $(filter 1 yes true,$(BROADCAST)),--broadcast,)

# Fails with a usage line instead of passing an empty argument to forge, which would otherwise be
# encoded as a zero address or a zero id.
need = $(if $($(1)),,$(error $(1) is required: make $@ $(1)=<value>))

# `allowlist` takes the raw digest, and forge wants exactly one 0x. A pasted 0x… would become
# `0x0x…` and a cryptic forge parse error instead of a usage line.
no0x = $(if $(filter 0x%,$($(1))),$(error $(1) must be 64 lowercase hex with NO 0x prefix: make $@ $(1)=<digest>))

.PHONY: help doctor read-config read-provider read-job read-asks read-allowlist \
        register setOperator setListed setCapacityCeiling setReputation \
        registerModel setModelEnabled setAllowedModels \
        setAllowlistEntry revokeAllowlistEntry \
        setFees setSlaAllowed setTreasury setJobRegistry ops-coverage test fmt

# `$(MAKEFILE_LIST)` is a list AND make gives it a leading space, so quoting it whole asks grep for
# a file literally named " Makefile". `firstword` is this file, which is the only one with targets;
# the quotes stay because this checkout lives under a path with spaces.
# The optional `# ` in the pattern is what picks up the variable documentation at the top of this
# file; `LC_ALL=C sort` then floats those three to the head of the list because they are uppercase.
# The locale is pinned rather than inherited: under a case-insensitive collation such as
# en_US.UTF-8, `RPC` sorts in among the targets instead, burying the one variable an operator most
# needs to see before running anything against a real network.
# Check the OUTPUT of this recipe, never its status: the exit code belongs to `sort`, the last stage
# of the pipeline, so a grep that finds nothing still reports success.
help:
	@grep -hE '^(# )?[a-zA-Z][a-zA-Z0-9_-]*:.*## ' "$(firstword $(MAKEFILE_LIST))" \
	  | sed 's/^# //; s/:.*## /\t/' | expand -t28 | LC_ALL=C sort

doctor: ## Check a deployment: wiring, separators, treasury, fees
	@$(READ) --sig 'doctor()' -vv

read-config: ## Print every live protocol parameter
	@$(READ) --sig 'config()' -vv

read-provider: ## make read-provider ID=1
	@$(call need,ID)
	@$(READ) --sig 'provider(uint32)' "$(ID)" -vv

read-job: ## make read-job JOB=0x…
	@$(call need,JOB)
	@$(READ) --sig 'job(bytes32)' "$(JOB)" -vv

read-asks: ## make read-asks ID=1 MODEL=1 SLA=3600
	@$(call need,ID)
	@$(call need,MODEL)
	@$(call need,SLA)
	@$(READ) --sig 'asks(uint32,uint32,uint32)' "$(ID)" "$(MODEL)" "$(SLA)" -vv

read-allowlist: ## make read-allowlist MEASUREMENT=<64 lowercase hex, no 0x>
	@$(call need,MEASUREMENT)
	@$(call no0x,MEASUREMENT)
	@$(READ) --sig 'allowlist(bytes32)' "0x$(MEASUREMENT)" -vv

register: ## make register OPERATOR=0x… CEILING=16 LISTED=true REPUTATION=1000
	@$(call need,OPERATOR)
	@$(call need,CEILING)
	@$(call need,LISTED)
	@$(call need,REPUTATION)
	@$(OPS) --sig 'register(address,uint32,bool,uint16)' "$(OPERATOR)" "$(CEILING)" "$(LISTED)" "$(REPUTATION)" $(_B) -vv

setOperator: ## make setOperator ID=1 OPERATOR=0x…
	@$(call need,ID)
	@$(call need,OPERATOR)
	@$(OPS) --sig 'setOperator(uint32,address)' "$(ID)" "$(OPERATOR)" $(_B) -vv

setListed: ## make setListed ID=1 LISTED=false
	@$(call need,ID)
	@$(call need,LISTED)
	@$(OPS) --sig 'setListed(uint32,bool)' "$(ID)" "$(LISTED)" $(_B) -vv

setCapacityCeiling: ## make setCapacityCeiling ID=1 CEILING=64
	@$(call need,ID)
	@$(call need,CEILING)
	@$(OPS) --sig 'setCapacityCeiling(uint32,uint32)' "$(ID)" "$(CEILING)" $(_B) -vv

setReputation: ## make setReputation ID=1 MILLI=750
	@$(call need,ID)
	@$(call need,MILLI)
	@$(OPS) --sig 'setReputation(uint32,uint16)' "$(ID)" "$(MILLI)" $(_B) -vv

registerModel: ## make registerModel NAME='org/model:fp8'
	@$(call need,NAME)
	@$(OPS) --sig 'registerModel(string)' '$(NAME)' $(_B) -vv

setModelEnabled: ## make setModelEnabled MODEL=1 ENABLED=false
	@$(call need,MODEL)
	@$(call need,ENABLED)
	@$(OPS) --sig 'setModelEnabled(uint32,bool)' "$(MODEL)" "$(ENABLED)" $(_B) -vv

# MODELS is deliberately NOT in a `need` guard: `MODELS=` with ALLOWALL=false is the legitimate
# way to revoke every model, and a guard would make the revoke unreachable from this interface.
setAllowedModels: ## make setAllowedModels ID=1 MODELS=1,2 ALLOWALL=false
	@$(call need,ID)
	@$(call need,ALLOWALL)
	@$(OPS) --sig 'setAllowedModels(uint32,uint32[],bool)' "$(ID)" '[$(MODELS)]' "$(ALLOWALL)" $(_B) -vv

# Two targets rather than one STATUS variable: listing and revoking are the only two writes, and a
# STATUS= variable invites the 0 the op refuses. The status is a literal here, so it cannot be
# mistyped from the command line at all.
setAllowlistEntry: ## make setAllowlistEntry MEASUREMENT=<64 lowercase hex, no 0x>  (lists it)
	@$(call need,MEASUREMENT)
	@$(call no0x,MEASUREMENT)
	@$(OPS) --sig 'setAllowlistEntry(bytes32,uint8)' "0x$(MEASUREMENT)" 1 $(_B) -vv

revokeAllowlistEntry: ## make revokeAllowlistEntry MEASUREMENT=<64 lowercase hex, no 0x>
	@$(call need,MEASUREMENT)
	@$(call no0x,MEASUREMENT)
	@$(OPS) --sig 'setAllowlistEntry(bytes32,uint8)' "0x$(MEASUREMENT)" 2 $(_B) -vv

setFees: ## make setFees FEEBPS=250 GASFEE=0
	@$(call need,FEEBPS)
	@$(call need,GASFEE)
	@$(OPS) --sig 'setFees(uint16,uint128)' "$(FEEBPS)" "$(GASFEE)" $(_B) -vv

setSlaAllowed: ## make setSlaAllowed SLA=3600 OK=true
	@$(call need,SLA)
	@$(call need,OK)
	@$(OPS) --sig 'setSlaAllowed(uint32,bool)' "$(SLA)" "$(OK)" $(_B) -vv

setTreasury: ## make setTreasury TREASURY=0x…
	@$(call need,TREASURY)
	@$(OPS) --sig 'setTreasury(address)' "$(TREASURY)" $(_B) -vv

# The one target where the dry run is not merely the default but the point: revoking makes
# submitAndSettle and reclaim revert for every CLAIMED job. The dry run prints the live count and
# then refuses, so VORQ_OPS_ACK_STRANDING=1 is only ever typed by someone who has read it.
setJobRegistry: ## make setJobRegistry REGISTRY=0x… AUTHORIZED=true  (revoking needs VORQ_OPS_ACK_STRANDING=1)
	@$(call need,REGISTRY)
	@$(call need,AUTHORIZED)
	@$(OPS) --sig 'setJobRegistry(address,bool)' "$(REGISTRY)" "$(AUTHORIZED)" $(_B) -vv

ops-coverage: ## Fail if an onlyCuration function has no ops entry point
	@./scripts/ops-coverage.sh

test: ops-coverage ## forge test, with the curation-surface gate first
	forge test

fmt: ## forge fmt
	forge fmt
