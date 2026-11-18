#!/usr/bin/env bash
# tests/test.sh: runs t3_job.sh against real systemd user units and a fake
# webhook (a small Python HTTP server that records each posted body). Needs a
# Linux machine with a systemd user session, python3, jq and curl. Takes about
# 45 s, most of it the 30 s restart delay.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
J="$HERE/../scripts/t3_job.sh"
T=$(mktemp -d)
PORT=$(( 20000 + RANDOM % 20000 ))
fail=0
export T3_JOBS_DIR="$T/jobs" T3CODE_THREAD_ID="test:thread-$$"

systemctl --user is-system-running >/dev/null 2>&1 || [ "$(systemctl --user is-system-running 2>/dev/null)" = degraded ] \
  || { echo "skip: no systemd user session"; exit 0; }

cat > "$T/server.py" <<'EOF'
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('content-length', 0)))
        with open(sys.argv[2], 'a') as f:
            f.write(json.loads(body)['text'] + '\n=====\n')
        self.send_response(202); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
EOF
python3 -I "$T/server.py" "$PORT" "$T/posts.txt" & server=$!
cleanup() {
  kill "$server" 2>/dev/null
  for n in burst three crash long; do "$J" stop "t-$$-$n" >/dev/null 2>&1; done
  rm -rf "$T"
}
trap cleanup EXIT
sleep 1

key=$(printf '%s' "$T3CODE_THREAD_ID" | tr -c 'A-Za-z0-9._-' '_')
mkdir -p "$T3_JOBS_DIR/threads/$key"
echo "http://127.0.0.1:$PORT/api/hooks/x/y" > "$T3_JOBS_DIR/threads/$key/url"
jq -n --arg t "$T3CODE_THREAD_ID" '{thread: $t, task: "scheduled-task:fake"}' > "$T3_JOBS_DIR/threads/$key/meta.json"

ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fail=1; }
check() { if eval "$2"; then ok "$1"; else no "$1"; fi; }
wait_for() { local i; for i in $(seq 1 "$2"); do eval "$1" && return 0; sleep 1; done; return 1; }

cd "$T"
"$J" start "t-$$-burst" --batch 2 -- bash -c 'echo "a"; echo "b"; sleep 4; echo "c"; exit 0' >/dev/null
check "a running job is not started twice" '[ "$("$J" start "t-$$-burst" -- true)" = "t-$$-burst ALREADY_RUNNING" ]'
"$J" start "t-$$-three" -- bash -c 'echo "already"; exit 3' >/dev/null
"$J" start "t-$$-crash" -- bash -c 'if [ ! -f '"$T"'/marker ]; then touch '"$T"'/marker; echo "first"; exit 1; fi; echo "second"' >/dev/null
"$J" start "t-$$-long" -- bash -c 'echo "up"; sleep 600' >/dev/null

wait_for '"$J" status "t-$$-burst" | grep -q "not running"' 20
check "lines within the batch window go out as one post" 'grep -qzP "a\nb\n=====" "$T/posts.txt"'
check "a later line goes out on its own" 'grep -qzP "=====\nc\n=====" "$T/posts.txt"'
check "exit 0 ends the job" '"$J" status "t-$$-burst" | grep -q "exit=0"'
check "exit 3 ends the job without a restart" '"$J" status "t-$$-three" | grep -q "exit=3"'
check "a long job is running" '"$J" status "t-$$-long" | grep -q ": running"'
"$J" stop "t-$$-long" >/dev/null
check "stop stops it" '"$J" status "t-$$-long" | grep -q "not running"'
check "a crashed job waits to restart" '"$J" status "t-$$-crash" | grep -q "restarting"'
wait_for '"$J" status "t-$$-crash" | grep -q "exit=0"' 45
check "a crashed job restarts and finishes" 'grep -q "^second$" "$T/posts.txt"'

"$J" start "t-$$-long" -- bash -c 'sleep 600' >/dev/null
printf '#!/bin/sh\necho "{\\"thread\\":{\\"settled\\":true,\\"archived\\":false}}"\n' > "$T/fake-t3"; chmod +x "$T/fake-t3"
check "sweep --dry-run lists the webhook task" '[ "$(T3_JOB_T3="$T/fake-t3" "$J" sweep --dry-run)" = "DELETE_WEBHOOK_TASK scheduled-task:fake $T3CODE_THREAD_ID (settled)" ]'
check "sweep --dry-run stops nothing" '"$J" status "t-$$-long" | grep -q ": running"'
T3_JOB_T3="$T/fake-t3" "$J" sweep >/dev/null
check "sweep stops the jobs of a settled thread" '! systemctl --user is-active --quiet "t3-job-t-$$-long"'
check "sweep forgets the thread" '[ ! -d "$T3_JOBS_DIR/threads/$key" ]'
check "start without a webhook fails" '! "$J" start "t-$$-x" -- true 2>/dev/null'
check "a bad job name fails" '! "$J" start "Bad_Name" -- true 2>/dev/null'

[ "$fail" = 0 ] && echo "all passed" || { echo "some tests FAILED"; exit 1; }