# Contributing

Bug reports and patches are welcome. A few things are worth knowing before you
spend time on a change.

## The one rule

**A fix without a test that fails before it is not finished.**

Every rule in [`docs/CONSTRAINTS.md`](docs/CONSTRAINTS.md) came from something
that broke, and most of them broke *silently* — reporting success while doing
nothing. That is the failure mode this project is built around, so a change that
cannot be observed to work is not an improvement.

Concretely, when you fix something:

1. Write the test first and **watch it fail**.
2. Make it pass.
3. **Break the fix on purpose and confirm the test goes red.**

Step 3 is not ceremony. Several tests in this repo passed while exercising
nothing until they were mutated — one asserted a scheduler restart used no
`sudo` and was satisfied by its own explanatory comment; another grepped for
output the code never emits. Assume a new test is broken until you have seen it
fail.

## Running the tests

```bash
bash tests/test-constraints.sh    # offline, no network, no hub
bash tests/test-provision.sh      # against a throwaway sshd on a high port
```

Both run on macOS and Linux, and CI runs them on both. The integration suite
stands up its own `sshd` as your user in a temp directory: no sudo, no change to
your `~/.ssh/authorized_keys`, no change to your crontab, and no host on the
network contacted. If it cannot start one it reports **SKIPPED**, counted
separately from passed — a suite that reports all-green having tested nothing is
worse than one that fails. If you make it skip, you have broken it.

Also run `shellcheck`:

```bash
shellcheck -e SC1090,SC1091 -S warning bin/snapfabric install.sh \
  agents/common/*.sh agents/macos/*.sh tests/*.sh
```

## Constraints on the code

- **bash 3.2.** macOS still ships it. No associative arrays, no `mapfile`, no
  `local -n`, and no bare expansion of a possibly-empty array under `set -u`.
- **No runtime dependencies.** bash, ssh, rsync and coreutils. Not Python — on
  macOS `/usr/bin/python3` is a stub that triggers an Xcode prompt, so depending
  on it would make a backup agent fail on a fresh machine.
- **Portable `date`.** BSD and GNU disagree; use the shared `epoch_of`. Do not
  write a fourth copy — there is a test asserting the existing ones are
  identical, because the fourth copy is exactly how a watchdog ended up
  reporting "all clear" having checked nothing.
- **Paths contain spaces.** `/Volumes/Backup Drive` is ordinary. Quote
  everything, keep lists newline-separated rather than space-separated, and
  assume any path a user typed has a space in it.
- **Never trust an exit code alone.** `tmutil` exits 0 while printing failure;
  `ssh-copy-id` exits 0 having appended a line that does not work. Observe the
  outcome.

## Things that will be turned down

- Making Python, Go, or a daemon a requirement.
- Replacing hardlinked snapshots with an archive format. Being able to restore
  with `cp` when the tool is gone is the point.
- A check that reports success without measuring anything.

## Commit messages

Say what broke and how it was observed, not just what changed. The commit log is
a large part of this project's documentation, and `git log` is where the
reasoning behind a constraint usually lives.
