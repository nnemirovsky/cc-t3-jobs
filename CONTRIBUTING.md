# Contributing

Thanks for looking at `cc-t3-jobs`. This covers the dev loop, the tests and how changes land.

## Dev loop

Load the plugin from a working tree instead of through the marketplace:

```
claude --plugin-dir /path/to/cc-t3-jobs
```

Every Claude Code restart re-reads the plugin from disk, with no `/plugin install` and no marketplace cache to flush. Hooks load at session start, so a change to `hooks/hooks.json` or to a handler needs a restart before it takes effect.

## Tests

```
claude plugin validate .
bash tests/test.sh
```

`tests/test.sh` runs `t3_job.sh` against real systemd user units and a fake webhook, a small local HTTP server that records each post. It covers batching, the exit codes that end a job, the restart after a crash, `ALREADY_RUNNING`, `stop` and `sweep` against a fake `t3` CLI. It needs Linux with a systemd user session, `python3`, `jq` and `curl`, and takes about 45 seconds. It uses a throwaway `T3_JOBS_DIR` and leaves your real jobs alone.

Lint the scripts before opening a PR:

```
bash -n scripts/t3_job.sh tests/test.sh
shellcheck --severity=error scripts/t3_job.sh tests/test.sh
```

CI runs the validation and the lint on every PR. GitHub's runners have no systemd user session, so run `tests/test.sh` locally for any change to `t3_job.sh`.

## Pull requests

- Open a PR against `main`. Direct pushes are blocked.
- CI must be green and every review thread resolved before a PR can merge.
- PRs are squash-merged, and the PR title becomes the commit subject, so write it as a commit message.
- Bump `version` in `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` in the PR that should ship as a release.

## Commits

Scoped conventional commits with a lowercase description:

```
feat(scope): add the thing
fix(scope): stop doing the wrong thing
```
