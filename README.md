# T3 Jobs

Claude Code watches long-running things with `Monitor`: a pull request, a build, a log. In a [T3 Code](https://github.com/pingdotgg/t3code) thread that works badly. The Monitor dies with the thread's Claude session, for example when T3 restarts or the model is switched. It stops after 30 minutes and has to be re-armed. Every restart leaves another finished task in the thread, so the thread soon says "Waiting on 3 commands and 1 monitor" while one watch is running.

This plugin runs the watch somewhere else. `t3_job.sh` starts the watch script as a systemd user unit. Whatever the script prints is posted back to the thread through the thread's own webhook task, and each batch of output wakes the thread as a new turn, just as a Monitor event would. The unit outlives the Claude session, needs no re-arm, and restarts itself if the script crashes.

## How it works

1. The thread creates a webhook task bound to itself with T3's `schedule_task` tool, and saves its URL with `t3_job.sh webhook <task id>`. One webhook serves all of the thread's jobs.
2. `t3_job.sh start <name> -- <watch script> <args>` starts unit `t3-job-<name>` with `systemd-run --user`.
3. Lines the script prints within 3 seconds of each other are posted as one message. T3 answers the post by starting a turn in the thread with the lines in it.
4. The script's exit ends the job. Exit 0, 2 or 3 means done. Anything else restarts it after 30 seconds.
5. When the work is done, the thread deletes its webhook task. `t3_job.sh sweep` cleans up after threads that were abandoned.

The plugin's `t3-jobs` skill tells Claude when and how to do all of this, so in practice you ask a T3 thread to watch something and it uses a job instead of a Monitor.

## Commands

```
t3_job.sh webhook <scheduled task id>     save this thread's webhook URL
t3_job.sh start <name> [--batch <secs>] -- <command> [args...]
t3_job.sh stop <name>
t3_job.sh status [<name>]
t3_job.sh sweep [--dry-run]               clean up after finished threads
```

`sweep` stops the jobs of every thread that is settled, archived or gone, and prints `DELETE_WEBHOOK_TASK <task id> <thread id>` for each webhook task left behind. The caller deletes those tasks with T3's `delete_scheduled_task` tool, because a script cannot.

## Writing a watch script for it

A job may be restarted at any time, so the script should keep a snapshot of what it has already seen and print only what changed since its last run. It sees `T3_JOB=<name>` in its environment. [shipshape](https://github.com/nnemirovsky/cc-shipshape)'s `watch_pr.sh` is an example: it polls a pull request and prints one line per new review, comment, CI result or state change.

## Things to know

* Linux only: it needs systemd user units. It also needs the T3 Code server on the same machine, plus `bash` 4 or newer, `jq`, `curl`, `sqlite3`, and the `t3` CLI for `sweep`.
* The webhook URL holds the task's secret token. It is stored with mode 600 under `~/.local/state/t3-jobs/` and is never printed.
* T3 treats posted text as untrusted data. It wraps it in tags and inserts an invisible character after `@`, currency signs and words that look like slash commands. Claude should take ids from the lines and look details up, not copy strings out of them.
* A post that fails is retried for about a minute and then kept. It goes out first with the next successful post, so a T3 restart loses nothing.
* A unit runs the script from the plugin version that started it. A crash restart after that version was removed from the plugin cache fails. Start the job again.

## Install

```
/plugin marketplace add nnemirovsky/cc-t3-jobs
/plugin install t3-jobs@t3-jobs
```

## Tests

`tests/test.sh` runs the commands against real systemd user units and a fake webhook. It needs a systemd user session and takes about 45 seconds.

## License

MIT