# Security policy

## Reporting a vulnerability

Report privately through GitHub, not in a public issue:

**[Open a private security advisory](https://github.com/nnemirovsky/cc-t3-jobs/security/advisories/new)**

The report is visible only to the maintainer ([@nnemirovsky](https://github.com/nnemirovsky)) until an advisory is published, so nothing sensitive is exposed while a fix is prepared. Expect an acknowledgement within a week.

If the form is unavailable, open a normal issue that says only "I would like a private channel for a security report", with no details, and a private advisory will be opened for you.

Never attach real credentials, tokens, personal data or private files to a report. Describe the shape of the problem instead.

## Supported versions

Only the latest release gets security fixes.

## Scope

t3-jobs keeps a secret, each thread's webhook token, and runs commands as systemd user units. A vulnerability here would be, for example:

- The webhook URL or its token leaking: printed, logged, passed on a command line other processes can read, or stored with a mode looser than 600.
- A post going anywhere other than the T3 Code server on `127.0.0.1`, or one thread's output going to another thread's webhook.
- `t3_job.sh` running a command other than the one passed to `start`, or a job name, task id or thread id that escapes `~/.local/state/t3-jobs/` or reaches the shell or a SQL query as code.
- `sweep` stopping the jobs of a thread that is still active, or touching units that are not `t3-job-*` units.
- Text a watch script prints being able to make `t3_job.sh` do anything other than post it.

Out of scope: what a watch script you started does on its own, how Claude acts on the posted lines inside the thread, and anything that needs an attacker who can already run commands as your user.
