#!/bin/sh
# Self-check without a herdr server: HJOB_DRY_RUN prints herdr calls instead of making them; HOME is a temp dir.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
export HOME=$(mktemp -d) HJOB_DRY_RUN=1 HERDR_PANE_ID=test-pane
trap 'pkill -f "$HOME/" 2>/dev/null || true; rm -rf "$HOME"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
st="$HOME/.local/state/hjob" fake="$HOME/fake"; mkdir -p "$fake"
# fake wake: logs its argv one per line (calls separated by ---), exits with the code in $fake/rc.<id>, else $fake/rc
cat > "$fake/wake" <<FAKE
#!/bin/sh
printf '%s\n' "\$@" --- >> "$fake/calls"
echo '{"status":"enqueued"}'; exit "\$(cat "$fake/rc.\$5" 2>/dev/null || cat "$fake/rc")"
FAKE
chmod +x "$fake/wake"; echo 0 > "$fake/rc"; export HERDR_WAKE_BIN="$fake/wake"
pid_of() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["pid"])' "$1.detached"; }
calls() { grep -c -- '^---$' "$fake/calls" 2>/dev/null || true; }
done_job() { for _ in $(seq 50); do ls "$st"/*"$1".enqueue* >/dev/null 2>&1 && break; sleep 0.2; done; }  # the worker's first enqueue settled
ln -s "$(command -v sleep)" "$fake/sleep"  # jobs sleep via $HOME, so the trap's pkill reaches every worker and command

# fast job: output and exit code come back at once
out=$("$here/hjob" --wait 10 -- sh -c 'echo hello; echo boom error; exit 3') && fail "exit code not passed through"
echo "$out" | grep -q hello || fail "fast output missing"
echo "$out" | grep -q '\[hjob\] exit 3' || fail "fast exit line missing"

# slow job: detaches, then the worker records the result
out=$("$here/hjob" --name slow --wait 1 -- sh -c "$fake/sleep 2; echo late") || fail "detach returned non-zero"
echo "$out" | grep -q "still running" || fail "did not detach"
log=$(ls "$HOME"/.local/state/hjob/*slow.log)
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "${log%.log}.json" ] && break; sleep 1; done
"$here/hjob" --summary "$log" | grep -q '\[hjob\] exit 0' || fail "summary of finished job"
"$here/hjob" --summary /etc/passwd 2>/dev/null && fail "summary accepted a path outside the state dir"

# wake enqueue: one argv-only call per detached job, safe fields only, a marker once it is stored
: > "$fake/calls"
"$here/hjob" --name enq --wait 1 -- sh -c "$fake/sleep 2; echo SECRETOUTPUT; exit 3" >/dev/null; done_job enq
base=$(ls "$st"/*enq.log); base=${base%.log}; id=${base##*/}
[ "$(sed -n 1,12p "$fake/calls" | tr '\n' '|')" = "enqueue|--source|hjob|--id|$id|--cwd|$here|--kind|job_failed|--text|job 'enq' finished with exit 3 in 2s|--hint|" ] ||
  fail "enqueue args: $(tr '\n' '|' < "$fake/calls")"
grep -qx "hjob status $id" "$fake/calls" && grep -qx test-pane "$fake/calls" || fail "hint or pane hint missing"
"$here/hjob" status "$id" | grep -q "wake: enqueued" || fail "status of an enqueued job"
grep -q SECRETOUTPUT "$fake/calls" && fail "command output passed to wake"
[ -f "$base.enqueued" ] || fail "no .enqueued marker"
"$here/hjob" -- true >/dev/null; [ "$(calls)" = 1 ] || fail "enqueued job sent again"
rm "$base.enqueued"  # finished while nothing enqueued it (worker died after writing the result): the next call does
"$here/hjob" status >/dev/null; [ "$(calls)" = 2 ] && [ -f "$base.enqueued" ] || fail "finished job not enqueued on the next call"

# exit 1 and a missing wake binary store nothing: the worker retries while it lives (a call meanwhile leaves the job alone),
# then the next hjob call does
for bad in rc1 missing; do
  : > "$fake/calls"; echo 1 > "$fake/rc"
  [ $bad = missing ] && export HERDR_WAKE_BIN="$fake/nowake"
  "$here/hjob" --name $bad --wait 1 -- "$fake/sleep" 2 >/dev/null; done_job $bad
  base=$(ls "$st"/*$bad.log); base=${base%.log}
  [ -f "$base.enqueued" ] && fail "$bad: marked enqueued"
  "$here/hjob" status | grep -q "${base##*/}  NOT ENQUEUED" || fail "$bad: failed enqueue not visible in hjob status"
  export HERDR_WAKE_BIN="$fake/wake"; echo 0 > "$fake/rc"; : > "$fake/calls"
  "$here/hjob" -- true >/dev/null; [ "$(calls)" = 0 ] || fail "$bad: retried while its worker still owns it"
  kill "$(pid_of "$base")"; sleep 0.3
  "$here/hjob" -- true >/dev/null
  grep -qx -- "job_done" "$fake/calls" && [ -f "$base.enqueued" ] || fail "$bad: not retried on the next call"
done

# exit 2 is a bug: logged in .enqueue-error, never retried
: > "$fake/calls"; echo 2 > "$fake/rc"
"$here/hjob" --name bad2 --wait 1 -- "$fake/sleep" 2 >/dev/null; done_job bad2
base=$(ls "$st"/*bad2.log); base=${base%.log}
[ -f "$base.enqueue-error" ] || fail "exit 2 not logged"
"$here/hjob" status | grep -q "${base##*/}  ENQUEUE ERROR" || fail "exit 2 not visible in hjob status"
echo 0 > "$fake/rc"; "$here/hjob" -- true >/dev/null
[ "$(calls)" = 1 ] || fail "exit 2 retried"

# the worker dies mid-job: the next hjob call enqueues job_failed
: > "$fake/calls"
"$here/hjob" --name dead --wait 1 -- "$fake/sleep" 30 >/dev/null
base=$(ls "$st"/*dead.log); base=${base%.log}
"$here/hjob" -- true >/dev/null; [ "$(calls)" = 0 ] || fail "running job enqueued"
kill "$(pid_of "$base")"; sleep 0.5
"$here/hjob" -- true >/dev/null
grep -qx job_failed "$fake/calls" && grep -q "lost its hjob worker" "$fake/calls" && [ -f "$base.enqueued" ] || fail "dead worker not enqueued"
"$here/hjob" status "${base##*/}" | grep -q "worker died" || fail "status of a dead worker's job says it is running"
pkill -f "$fake/sleep 30" || true

# dead workers: a pid reused by another process is not the worker; an exit-1 job does not block newer ones;
# malformed state files never crash hjob
: > "$fake/calls"; "$fake/sleep" 20 & other=$!
for n in a b; do
  echo "{\"name\": \"re$n\", \"log\": \"$st/x-re$n.log\", \"pane\": \"\", \"cwd\": \"$HOME\", \"pid\": $other}" > "$st/x-re$n.detached"
  : > "$st/x-re$n.log"
done
echo 1 > "$fake/rc.x-rea"
echo '{"pid": 1, "name": "bad", "cwd": "/", "pane": null}' > "$st/x-bad1.detached"; echo null > "$st/x-bad2.detached"
"$here/hjob" -- true >/dev/null || fail "malformed state broke hjob"
grep -qx x-reb "$fake/calls" && [ -f "$st/x-reb.enqueued" ] || fail "reused pid hid a dead worker, or an exit-1 job blocked a newer one"
[ -f "$st/x-rea.enqueue-retry" ] || fail "exit-1 job not marked for retry"
"$here/hjob" status x-reb | grep -q "worker died" || fail "status of a reused-pid job"
"$here/hjob" status | grep -q "x-bad" && fail "malformed job listed"
kill $other; rm "$fake/rc.x-rea"

# no wake binary: the detach message does not promise a wake-up
HERDR_WAKE_BIN="$fake/nowake" "$here/hjob" --name nowake --wait 0 -- "$fake/sleep" 1 | grep -q "not installed" || fail "promised a wake without wake"

# herdr's exit code and a timeout never stop the enqueue: notification is the only herdr call left
printf '#!/bin/sh\necho "$*" >> "%s"\nexit 1\n' "$fake/herdr.calls" > "$fake/herdr"; chmod +x "$fake/herdr"; : > "$fake/calls"
HJOB_DRY_RUN=0 HERDR_BIN_PATH="$fake/herdr" "$here/hjob" --name noherdr --wait 1 -- "$fake/sleep" 2 >/dev/null; done_job noherdr
grep -q "noherdr" "$fake/calls" || fail "failing herdr blocked the enqueue"
grep -q '^notification show' "$fake/herdr.calls" && ! grep -qv '^notification show' "$fake/herdr.calls" ||
  fail "herdr calls other than notification show: $(cat "$fake/herdr.calls")"
HJOB_DRY_RUN=0 HERDR_BIN_PATH="$fake/missing" "$here/hjob" -- true >/dev/null || fail "missing herdr broke hjob"

# install-cli: installs into an empty dir, refuses to replace a foreign hjob
HJOB_BIN_DIR="$HOME/bin" sh "$here/install-cli.sh" >/dev/null || fail "install-cli"
grep -q "herdr-hjob plugin" "$HOME/bin/hjob" || fail "shim not installed"
echo foreign > "$HOME/bin/hjob"
HJOB_BIN_DIR="$HOME/bin" sh "$here/install-cli.sh" 2>/dev/null && fail "overwrote a foreign hjob"
[ "$(cat "$HOME/bin/hjob")" = foreign ] || fail "foreign hjob changed"
echo "all tests passed"
