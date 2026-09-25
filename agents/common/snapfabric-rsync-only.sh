#!/bin/bash
# snapfabric-rsync-only — forced command for a backup key.
#
# Installed on each BACKED-UP host as the forced command for the key the hub
# pulls with:
#
#   command="~/bin/snapfabric-rsync-only",no-agent-forwarding,no-port-forwarding,
#   no-pty,no-user-rc ssh-ed25519 AAAA… snapfabric-<tag>
#
# WHY
# The hub holds a passphraseless key for every host it backs up, so the hub is a
# credential concentrator. If those keys granted a shell, compromising the hub
# would mean shell on the entire estate. This restricts each key to exactly one
# thing: serving files to rsync, read-only.
#
# WHAT IT DOES NOT DO
# It does not restrict WHICH paths may be read. The key can read anything its
# user can read on that host. Narrowing that is worthwhile and is not in v1 —
# see docs/SECURITY.md. Treat the key as equivalent to read access to the
# account, and give the backup account only what it needs to read.
#
# Deliberately self-contained: a forced command that sources another file gains
# a second write target that is equivalent to code execution.

set -uo pipefail

deny(){ echo "rejected: this key permits read-only rsync only" >&2; exit 1; }

CMD="${SSH_ORIGINAL_COMMAND:-}"
[ -n "$CMD" ] || deny

# --sender is rsync's "I am the source" mode. Without it the client is asking to
# WRITE to this host, which a backup key has no business doing. The prefix is
# matched exactly rather than searched for: "echo x; rsync --server --sender"
# contains the string but must not be accepted.
case "$CMD" in
  "rsync --server --sender "*) ;;
  *) deny ;;
esac

# Nothing that could chain, redirect, substitute or expand. Note that quotes are
# NOT banned: rsync quotes remote paths, and constraint 18 exists because paths
# with spaces are real. With substitution and chaining characters refused, the
# eval below cannot do anything but split the quoted words.
case "$CMD" in
  *[\;\&\|\`\$\(\)\<\>]*) deny ;;
esac

# Backslashes could smuggle a newline past the character check above.
case "$CMD" in
  *\\*) deny ;;
esac
case "$CMD" in
  *'
'*) deny ;;
esac

eval "exec $CMD"
