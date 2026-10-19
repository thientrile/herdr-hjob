#!/bin/sh
# Self-check without a herdr server: HJOB_DRY_RUN prints herdr calls instead of making them; HOME is a temp dir.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
export HOME=$(mktemp -d) HJOB_DRY_RUN=1 HERDR_PANE_ID=test-pane
trap 'rm -rf "$HOME"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# fast job: output and exit code come back at once
out=$("$here/hjob" --wait 10 -- sh -c 'echo hello; echo boom error; exit 3') && fail "exit code not passed through"
echo "$out" | grep -q hello || fail "fast output missing"
echo "$out" | grep -q '\[hjob\] exit 3' || fail "fast exit line missing"

# slow job: detaches, then the worker records the result
out=$("$here/hjob" --name slow --wait 1 -- sh -c 'sleep 2; echo late') || fail "detach returned non-zero"
echo "$out" | grep -q "still running" || fail "did not detach"
log=$(ls "$HOME"/.local/state/hjob/*slow.log)
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "${log%.log}.json" ] && break; sleep 1; done
"$here/hjob" --summary "$log" | grep -q '\[hjob\] exit 0' || fail "summary of finished job"
"$here/hjob" --summary /etc/passwd 2>/dev/null && fail "summary accepted a path outside the state dir"

# install-cli: installs into an empty dir, refuses to replace a foreign hjob
HJOB_BIN_DIR="$HOME/bin" sh "$here/install-cli.sh" >/dev/null || fail "install-cli"
grep -q "herdr-hjob plugin" "$HOME/bin/hjob" || fail "shim not installed"
echo foreign > "$HOME/bin/hjob"
HJOB_BIN_DIR="$HOME/bin" sh "$here/install-cli.sh" 2>/dev/null && fail "overwrote a foreign hjob"
[ "$(cat "$HOME/bin/hjob")" = foreign ] || fail "foreign hjob changed"
echo "all tests passed"
