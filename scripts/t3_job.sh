#!/usr/bin/env bash
# t3_job.sh webhook <scheduled task id>     save this thread's webhook URL
# t3_job.sh start <name> [--batch <secs>] -- <command> [args...]
# t3_job.sh stop <name>
# t3_job.sh status [<name>]
# t3_job.sh sweep [--dry-run]               clean up after finished threads
#
# Runs a long-lived watch script for a T3 Code thread as a systemd user unit
# and posts what the script prints back to that thread through the thread's
# webhook task, so every batch of output wakes the thread as a new turn. It
# replaces a Claude Code Monitor in T3: a Monitor dies with the thread's Claude
# session, stops after 30 minutes, and every restart leaves a finished task
# behind in the thread. A unit has none of these problems.
#
# webhook   The thread creates one webhook task bound to itself with
#           mcp__t3-code__schedule_task (the tool does not return the URL), then
#           runs this with the task id. It reads the task's token from T3's
#           database and writes the local URL to
#           <jobs dir>/threads/<thread>/url, mode 600. The token is the only
#           lock on that URL: never print the file. One webhook per thread
#           serves all of its jobs.
# start     Starts unit t3-job-<name> running <command> as the user, in the
#           current directory. Lines the command prints within --batch seconds
#           (default 3) of each other are posted as one message. A failed post
#           is retried 5 times (2, 4, 8, 16, 32 s) and then kept in the job's
#           undelivered.log, which goes out first with the next post. The
#           command's exit ends the unit: 0, 2 (usage) or 3 ("already running")
#           is done, anything else restarts it after 30 s. Starting a running
#           job prints "<name> ALREADY_RUNNING" and changes nothing. The command
#           sees T3_JOB=<name>.
# stop      Stops the unit.
# status    One line per job: running, restarting, or not running with its last
#           exit. Without a name: this thread's jobs, or all jobs outside T3.
# sweep     For every thread with a saved webhook whose T3 thread is settled,
#           archived or gone: stops its jobs, forgets the URL, and prints
#           "DELETE_WEBHOOK_TASK <task id> <thread id> (<why>)" for the caller
#           to delete with mcp__t3-code__delete_scheduled_task. Also forgets
#           finished jobs older than 7 days. --dry-run only prints.
#
# Needs: bash 4+, jq, curl, sqlite3, systemd user units (Linux), the T3 Code
# server on this machine, and the `t3` CLI for sweep.
#
# Env: T3_JOBS_DIR (default ~/.local/state/t3-jobs), T3CODE_THREAD_ID (set by
# T3 in every thread), T3CODE_HOME (default ~/.t3). For tests: T3_JOB_T3
# replaces the t3 CLI.
set -uo pipefail

SELF=$(readlink -f "$0")
ROOT="${T3_JOBS_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/t3-jobs}"
T3_HOME="${T3CODE_HOME:-$HOME/.t3}"
T3="${T3_JOB_T3:-t3}"

die() { echo "t3_job: $*" >&2; exit 2; }
key() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
thread_dir() { echo "$ROOT/threads/$(key "$1")"; }
unit() { echo "t3-job-$1"; }
valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,80}$ ]] || die "bad job name '$1' (lowercase letters, digits, dashes)"; }
active() { systemctl --user is-active --quiet "$(unit "$1")"; }
need_thread() { [ -n "${T3CODE_THREAD_ID:-}" ] || die "not in a T3 thread (T3CODE_THREAD_ID is empty)"; }

cmd_webhook() {
  local id="${1:-}" dir db token port enc
  [ -n "$id" ] || die "usage: t3_job.sh webhook <scheduled task id>"
  need_thread
  command -v sqlite3 >/dev/null || die "sqlite3 is required"
  db="$T3_HOME/userdata/statev2.sqlite"
  [ -f "$db" ] || die "no T3 database at $db"
  token=$(sqlite3 -readonly "$db" "select webhook_token from scheduled_tasks where task_id = '${id//\'/}';") \
    || die "could not read $db"
  [ -n "$token" ] || die "no webhook token for $id (is it a webhook task on this machine?)"
  port=$(jq -r '.port // empty' "$T3_HOME/userdata/server-runtime.json" 2>/dev/null)
  enc=$(jq -rn --arg s "$id" '$s|@uri')
  dir=$(thread_dir "$T3CODE_THREAD_ID"); mkdir -p "$dir"
  ( umask 077; printf 'http://127.0.0.1:%s/api/hooks/%s/%s\n' "${port:-3773}" "$enc" "$token" > "$dir/url.tmp" ) \
    && mv "$dir/url.tmp" "$dir/url" || die "could not write $dir/url"
  jq -n --arg t "$T3CODE_THREAD_ID" --arg k "$id" '{thread: $t, task: $k}' > "$dir/meta.json"
  echo "webhook saved for thread $T3CODE_THREAD_ID (task $id)"
}

cmd_start() {
  local name="${1:-}" batch=3 dir url
  [ -n "$name" ] || die "usage: t3_job.sh start <name> [--batch <secs>] -- <command> [args...]"
  valid_name "$name"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --batch) batch="$2"; shift 2;;
      --) shift; break;;
      *) die "unknown argument: $1";;
    esac
  done
  [ $# -gt 0 ] || die "no command after --"
  [[ "$batch" =~ ^[0-9]+$ ]] || die "--batch takes whole seconds"
  need_thread
  url="$(thread_dir "$T3CODE_THREAD_ID")/url"
  [ -s "$url" ] || die "no webhook for this thread: create one with schedule_task, then run t3_job.sh webhook <task id>"
  if active "$name"; then echo "$name ALREADY_RUNNING"; exit 0; fi
  dir="$ROOT/jobs/$name"; mkdir -p "$dir"
  # NUL-separated: jq would read a "-c" in the command as one of its own options.
  printf '%s\0' "$@" | jq -Rs --arg t "$T3CODE_THREAD_ID" --arg u "$url" --arg cwd "$PWD" --argjson b "$batch" \
    --arg at "$(date -u +%FT%TZ)" '{thread: $t, url: $u, cwd: $cwd, batch: $b, started: $at,
      command: (split("\u0000") | .[:-1])}' > "$dir/meta.json"
  rm -f "$dir/last"
  systemctl --user reset-failed "$(unit "$name")" 2>/dev/null
  systemd-run --user --quiet --collect --unit="$(unit "$name")" \
    -p Restart=on-failure -p RestartSec=30 -p SuccessExitStatus="2 3" -p StartLimitIntervalSec=0 \
    --working-directory="$PWD" --setenv=PATH="$PATH" --setenv=HOME="$HOME" --setenv=T3_JOB="$name" \
    ${T3_JOBS_DIR:+--setenv=T3_JOBS_DIR="$T3_JOBS_DIR"} \
    "$SELF" run "$name" || die "systemd-run failed for $name"
  echo "$name started (unit $(unit "$name"))"
}

post_once() {  # post_once <url file> <text>
  local url body code
  url=$(head -n 1 "$1")
  body=$(jq -cn --arg t "$2" '{text: $t}') || return 1
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
    -H 'content-type: application/json' -X POST --data-binary "$body" "$url" 2>/dev/null) || return 1
  [ "$code" = 202 ] || [ "$code" = 200 ]
}

post() {  # post <url file> <text> <undelivered log>, with retries
  local delay=2 n pending
  if [ -s "$3" ]; then
    pending=$(cat "$3")
    for n in 1 2 3; do post_once "$1" "Delivered late (the thread's webhook was unreachable earlier):
$pending" && { : > "$3"; break; }; sleep 2; done
  fi
  for n in 1 2 3 4 5; do
    post_once "$1" "$2" && return 0
    [ "$n" = 5 ] || sleep "$delay"
    delay=$(( delay * 2 ))
  done
  printf '%s\n' "$2" >> "$3"
  return 1
}

# What the unit runs: the job's command, its output batched and posted.
cmd_run() {
  local name="${1:-}" dir meta url batch line more status
  dir="$ROOT/jobs/$name"; meta="$dir/meta.json"
  [ -f "$meta" ] || die "no job $name"
  url=$(jq -r .url "$meta"); batch=$(jq -r .batch "$meta")
  local -a cmd
  mapfile -t cmd < <(jq -r '.command[]' "$meta")
  "${cmd[@]}" | {
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      more=""
      while IFS= read -r -t "$batch" more; do
        [ -n "$more" ] && line+=$'\n'"$more"
        more=""
      done
      [ -n "$more" ] && line+=$'\n'"$more"
      post "$url" "$line" "$dir/undelivered.log" || echo "t3_job: post failed, kept in $dir/undelivered.log" >&2
    done
  }
  status=${PIPESTATUS[0]}
  echo "exit=$status at=$(date -u +%FT%TZ)" > "$dir/last"
  exit "$status"
}

cmd_stop() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: t3_job.sh stop <name>"
  valid_name "$name"
  systemctl --user stop "$(unit "$name")" 2>/dev/null
  systemctl --user reset-failed "$(unit "$name")" 2>/dev/null
  echo "$name stopped"
}

job_line() {  # job_line <name>
  local name=$1 state restarts last
  state=$(systemctl --user show "$(unit "$name")" -p ActiveState --value 2>/dev/null)
  restarts=$(systemctl --user show "$(unit "$name")" -p NRestarts --value 2>/dev/null)
  case "$state" in
    active) echo "$name: running${restarts:+, restarts $restarts}";;
    activating) echo "$name: restarting${restarts:+ (restarts $restarts)}";;
    *) last=$(cat "$ROOT/jobs/$name/last" 2>/dev/null); echo "$name: not running${last:+ ($last)}";;
  esac
}

cmd_status() {
  local name="${1:-}" d
  if [ -n "$name" ]; then valid_name "$name"; job_line "$name"; return; fi
  for d in "$ROOT"/jobs/*/; do
    [ -f "$d/meta.json" ] || continue
    if [ -n "${T3CODE_THREAD_ID:-}" ] && [ "$(jq -r .thread "$d/meta.json")" != "$T3CODE_THREAD_ID" ]; then continue; fi
    job_line "$(basename "$d")"
  done
}

cmd_sweep() {
  local dry=0 d tid task info finished j now age
  [ "${1:-}" = --dry-run ] && dry=1
  for d in "$ROOT"/threads/*/; do
    [ -f "$d/meta.json" ] || continue
    tid=$(jq -r .thread "$d/meta.json"); task=$(jq -r .task "$d/meta.json")
    info=$("$T3" thread show "$tid" --json 2>/dev/null | jq -c '.thread // empty' 2>/dev/null)
    if [ -z "$info" ]; then finished=gone
    else finished=$(jq -r 'if .archived then "archived" elif .settled then "settled" else "" end' <<<"$info"); fi
    [ -n "$finished" ] || continue
    for j in "$ROOT"/jobs/*/; do
      [ -f "$j/meta.json" ] && [ "$(jq -r .thread "$j/meta.json")" = "$tid" ] || continue
      [ "$dry" = 1 ] || { cmd_stop "$(basename "$j")" >/dev/null; rm -rf "$j"; }
    done
    [ "$dry" = 1 ] || rm -rf "$d"
    echo "DELETE_WEBHOOK_TASK $task $tid ($finished)"
  done
  now=$(date +%s)
  for j in "$ROOT"/jobs/*/; do
    [ -f "$j/last" ] || continue
    active "$(basename "$j")" && continue
    age=$(( now - $(stat -c %Y "$j/last") ))
    if [ "$age" -gt 604800 ]; then
      if [ "$dry" = 1 ]; then echo "FORGET_JOB $(basename "$j")"; else rm -rf "$j"; fi
    fi
  done
  return 0
}

case "${1:-}" in
  webhook) shift; cmd_webhook "$@";;
  start) shift; cmd_start "$@";;
  run) shift; cmd_run "$@";;
  stop) shift; cmd_stop "$@";;
  status) shift; cmd_status "$@";;
  sweep) shift; cmd_sweep "$@";;
  -h|--help|"") awk 'NR > 1 && /^set -uo/ {exit} NR > 1' "$0";;
  *) die "unknown command: $1";;
esac