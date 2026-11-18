# Privacy policy

t3-jobs runs entirely on your machine. It has no server and collects no telemetry. Nothing is sent to the author or to any third party.

## What it reads

The webhook token of a T3 Code scheduled task, from T3's own database (`~/.t3/userdata/statev2.sqlite`), when a thread asks for it. T3's local port, from `~/.t3/userdata/server-runtime.json`. The output of the watch scripts it runs. The state of T3 threads through the `t3` CLI, for `sweep`.

## What it writes

Under `~/.local/state/t3-jobs/`: each thread's webhook URL (mode 600) and task id, and each job's command, last exit and any posts that could not be delivered. It starts and stops systemd user units named `t3-job-<name>`.

## Where it sends data

Only to the T3 Code server on the same machine, at `127.0.0.1`: the lines the watch scripts print.

## Contact

Questions go to [GitHub issues](https://github.com/nnemirovsky/cc-t3-jobs/issues).