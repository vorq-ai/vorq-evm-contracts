#!/bin/sh
# Fails when an `onlyCuration` function in src/ has no entry point in script/ops/Curation.s.sol.
#
# The compiler already proves most of the converse — every op the script exposes is built with
# abi.encodeCall against an imported function, so its NAME, ARGUMENT TYPES and RETURN TYPES cannot
# drift from the contract without a build failure. This is the direction the compiler cannot see:
# a NEW curation function that nothing exposes.
#
# What this gate proves is narrower than "the op works": grep finds the text `function <name>(` in
# the ops script, so a commented-out entry point, or a stub with no abi.encodeCall in its body,
# would satisfy it. That residue is covered by the test suite, not here. The gate's job is to make
# a NEW curation function impossible to ignore, not to prove the old ones still do their work.
#
# The count is asserted as a literal on purpose. Deriving both sides from the same grep would
# compare a number to itself and pass through any change at all.
set -eu

cd "$(dirname "$0")/.."

# CONTRACT ENTRY POINTS, not `make` targets — the two numbers differ and always will. `setFees`
# takes both fees in one call, and the allowlist has two targets (`setAllowlistEntry`,
# `revokeAllowlistEntry`) over one contract function, so `make help` lists more than this. Never
# "reconcile" them: this side counts Solidity.
EXPECTED_COUNT=13
OPS="script/ops/Curation.s.sol"

# Every onlyCuration declaration under src/. `tr` flattens the sources to one line first, because
# `forge fmt` wraps any declaration past the line limit onto several — `register` is one — and a
# line-at-a-time grep would drop exactly those from the list. `[^{;]*` still stops at the
# declaration's own opening brace, so a match can never run past one function into the next.
#
# `find src`, NOT `src/*.sol`: the glob is non-recursive, and `src/` already has a subdirectory. A
# curation function added below the top level would be invisible to BOTH halves of this gate —
# absent from the count, so never name-checked — and the script would report success while the
# thing it exists to catch had happened. Verified by adding one to `src/dev/` and watching this
# exit 0.
FNS=$(find src -name '*.sol' -exec cat {} + | tr '\n' ' ' \
      | grep -oE 'function [a-zA-Z0-9_]+\([^)]*\)[^{;]*onlyCuration' \
      | sed -E 's/^function ([a-zA-Z0-9_]+)\(.*/\1/' | sort -u)

# `|| true` because `grep -c` exits 1 on zero matches, and under `set -eu` that would abort the
# assignment — turning "the greps matched nothing at all", the loudest possible failure, into a
# silent exit 1 with no diagnostic. The count assertion below is what should report that case.
COUNT=$(printf '%s\n' "$FNS" | grep -c . || true)
if [ "$COUNT" -ne "$EXPECTED_COUNT" ]; then
    echo "ops-coverage: found $COUNT onlyCuration functions, expected $EXPECTED_COUNT." >&2
    echo "  The curation surface changed. Decide about each new function, expose it in $OPS," >&2
    echo "  then update EXPECTED_COUNT in this script." >&2
    printf '%s\n' "$FNS" | sed 's/^/    /' >&2
    exit 1
fi

MISSING=""
for fn in $FNS; do
    # `setAllowlistEntry` is exposed with a derived `entry` argument, so it is matched by name.
    grep -qE "function $fn\(" "$OPS" || MISSING="$MISSING $fn"
done

if [ -n "$MISSING" ]; then
    echo "ops-coverage: no entry point in $OPS for:$MISSING" >&2
    exit 1
fi

echo "ops-coverage: all $COUNT onlyCuration functions have an entry point"
