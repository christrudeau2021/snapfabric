# Changelog

## v1.0.0

First public release.

Hardlinked rsync snapshots across a hub and any number of nodes, with the
machinery that notices when it has stopped working:

- `plan` / `add-node` — design a fabric, or add one host to a running one,
  writing config and nothing else
- `provision` — install keys, agents and schedules; idempotent and resumable,
  and it verifies each key is restricted rather than assuming it
- `verify` — prove a restore by performing one and comparing SHA-256
- `status` / `doctor` — health reporting, and self-repair from a second machine
- A size gate that refuses to make a truncated run the `latest` snapshot
- A sentinel check that refuses to back up an unmounted mount point

Requires bash 3.2+, ssh and rsync. No runtime, no daemon, no database.

See [`docs/CONSTRAINTS.md`](docs/CONSTRAINTS.md) for the failures behind each of
those decisions.
