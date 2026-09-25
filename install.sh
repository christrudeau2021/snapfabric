#!/bin/bash
# snapfabric installer.
#
#   ./install.sh [--prefix DIR] [--link] [--uninstall]
#
# Installs to ~/.local by default and never asks for root. /usr/local/bin needs
# sudo on macOS, and an installer that opens with a password prompt is one more
# reason not to try the thing.
#
# --link symlinks the checkout instead of copying it, so `git pull` updates the
# install. Copy is the default: an install that changes under a running
# scheduler because someone was editing the repo is a bad surprise.

set -uo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
LINK=0; UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)    PREFIX="${2:-}"; shift 2 ;;
    --link)      LINK=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help)   sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "usage: $0 [--prefix DIR] [--link] [--uninstall]" >&2; exit 2 ;;
  esac
done

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$PREFIX/share/snapfabric"
LINKPATH="$PREFIX/bin/snapfabric"

B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
[ -t 1 ] || { B=""; D=""; G=""; Y=""; R=""; N=""; }
ok(){   printf "  ${G}✓${N} %s\n" "$*"; }
warn(){ printf "  ${Y}!${N} %s\n" "$*"; }
die(){  printf "${R}✗ %s${N}\n" "$*" >&2; exit 1; }

if [ "$UNINSTALL" -eq 1 ]; then
  printf "${B}Removing snapfabric${N}\n"
  [ -L "$LINKPATH" ] || [ -f "$LINKPATH" ] && { rm -f "$LINKPATH" && ok "removed $LINKPATH"; }
  [ -d "$DEST" ] && { rm -rf "$DEST" && ok "removed $DEST"; }
  printf "\n${D}Your config, keys and backups were not touched:\n"
  printf "  ~/.config/snapfabric   ~/.ssh/snapfabric_*   and the backup drive itself\n"
  printf "Schedulers installed by \`provision\` are also still in place.${N}\n"
  exit 0
fi

printf "${B}Installing snapfabric${N} → %s\n\n" "$PREFIX"

# --- preflight ------------------------------------------------------------------
# Check what the agents actually need, and say what is missing rather than
# failing later inside a scheduled job at 03:00.
printf "${B}Checking this machine${N}\n"

case "${BASH_VERSION:-}" in
  ''|1.*|2.*) die "bash 3.2 or newer is required (found ${BASH_VERSION:-none})" ;;
  *) ok "bash ${BASH_VERSION%%(*}" ;;
esac

command -v ssh >/dev/null 2>&1 || die "ssh not found — snapfabric is built on it"
ok "ssh $(ssh -V 2>&1 | cut -d, -f1)"

if command -v rsync >/dev/null 2>&1; then
  rv=$(rsync --version 2>/dev/null | head -1)
  case "$rv" in
    *openrsync*)
      warn "openrsync — Apple's rsync. It works, with two real limits:"
      printf "      ${D}no --sparse (a sparse VM disk copies at its full logical size)\n"
      printf "      and it mmap()s files, which deadlocks on iCloud placeholder files.\n"
      printf "      If this machine has either, install GNU rsync: brew install rsync${N}\n" ;;
    *) ok "${rv%% protocol*}" ;;
  esac
else
  die "rsync not found — install it first (macOS: brew install rsync)"
fi

command -v awk  >/dev/null 2>&1 || die "awk not found"
command -v sed  >/dev/null 2>&1 || die "sed not found"
ok "awk, sed"
printf "  ${D}python3 is NOT required — the agents are pure shell${N}\n"
echo

# --- install ----------------------------------------------------------------------
printf "${B}Installing${N}\n"
mkdir -p "$PREFIX/bin" || die "cannot create $PREFIX/bin"

if [ "$LINK" -eq 1 ]; then
  [ "$SRC" = "$DEST" ] || {
    mkdir -p "$(dirname "$DEST")"
    rm -rf "${DEST:?}"
    ln -sfn "$SRC" "$DEST" || die "cannot link $DEST"
  }
  ok "linked $DEST → $SRC ${D}(git pull updates the install)${N}"
else
  mkdir -p "$DEST" || die "cannot create $DEST"
  # Copy only what runs. Tests, .git and scratch files have no business in an
  # install, and shipping them makes the surface look bigger than it is.
  for d in bin agents docs; do
    [ -d "$SRC/$d" ] || continue
    # ${DEST:?} not $DEST: if DEST were ever empty this is `rm -rf /bin`.
    rm -rf "${DEST:?}/$d"
    cp -R "$SRC/$d" "$DEST/$d" || die "cannot copy $d"
  done
  [ -f "$SRC/examples/snapfabric.conf.example" ] && {
    mkdir -p "$DEST/examples"
    cp "$SRC/examples/snapfabric.conf.example" "$DEST/examples/"
  }
  ok "copied to $DEST"
fi

chmod 755 "$DEST/bin/snapfabric" 2>/dev/null || true
ln -sfn "$DEST/bin/snapfabric" "$LINKPATH" || die "cannot link $LINKPATH"
ok "linked $LINKPATH"

# Prove the dispatcher resolves its agents through the symlink before claiming
# success. This is the step that silently works in a checkout and fails once
# installed, so it is verified rather than assumed.
if "$LINKPATH" version >/dev/null 2>&1; then
  ok "$("$LINKPATH" version) responds"
else
  die "installed, but '$LINKPATH version' failed — the dispatcher cannot find agents/"
fi
echo

# --- PATH ---------------------------------------------------------------------------
case ":${PATH}:" in
  *":$PREFIX/bin:"*) ok "$PREFIX/bin is already on your PATH" ;;
  *)
    warn "$PREFIX/bin is not on your PATH. Add this to your shell profile:"
    printf "\n      ${B}export PATH=\"%s/bin:\$PATH\"${N}\n\n" "$PREFIX"
    printf "      ${D}zsh: ~/.zshrc    bash: ~/.bash_profile${N}\n" ;;
esac

cat <<DONE

${B}Next${N}
  ${B}snapfabric discover${N}    see what is on this network      ${D}(changes nothing)${N}
  ${B}snapfabric plan${N}        design the fabric                ${D}(writes config only)${N}
  ${B}snapfabric provision${N}   install keys, agents, schedules

  Adding a machine to a fabric that already exists:
  ${B}snapfabric add-node${N}

  ${D}Walkthrough, including SSH key exchange: $DEST/docs/QUICKSTART.md${N}
DONE
