#!/bin/bash
# snapfabric — everything concerning ONE host: prompting for it, and
# rendering its engine config.
#
# Shared by `plan` (which loops over it to build a whole fabric) and `add-node`
# (which calls it once against a fabric that already exists). It lived inside
# plan's loop first; add-node needed the identical 107 lines, and a copy would
# have drifted the moment either side was touched.
#
# Requires the caller to have already sourced lib-validate.sh and lib-mounts.sh
# and to provide the prompt helpers (ask, ask_valid, ask_yn), the message
# helpers (say, note, warn) and the colour variables. Both callers do.
#
#   prompt_host <tag> <tmpdir>
#
# Interface is the three files it writes, not the variables it sets, so a caller
# can read back exactly what was decided without depending on scope leakage:
#
#   <tmpdir>/h.<tag>     P_TAG P_USER P_ADDR P_MODE P_SCHED P_FRESH P_SENTINEL
#   <tmpdir>/src.<tag>   newline-separated source paths
#   <tmpdir>/exc.<tag>   newline-separated exclude patterns

interval_hours(){
  case "$1" in
    hourly)  echo 1 ;;
    6h)      echo 6 ;;
    daily)   echo 24 ;;
    weekly)  echo 168 ;;
    monthly) echo 720 ;;
    *)       echo "" ;;
  esac
}
freshness_for(){ # interval + 25% slack, floor 6h, so one late run is not an alarm
  local h="$1" slack=$(( $1 / 4 ))
  [ "$slack" -lt 6 ] && slack=6
  echo $(( h + slack ))
}

DEFAULT_EXCLUDES='.cache/
*.tmp
lost+found/'

prompt_host(){ # prompt_host <tag> <tmpdir>
  # All locals: callers must read the emitted files, never leaked variables.
  local TMP="$2" TAG H_USER H_ADDR H_MODE H_SCHED H_FRESH H_SENTINEL
  local H_SOURCES H_EXCLUDES H_MOUNTSRC H_PORT _e _sent _ih
  local MIDX="$2/mounts.idx.$1" _s _scan_ssh
  TAG="$1"
  printf "\n  ${B}%s${N}\n" "$TAG"
  ask_valid safe_token H_USER "    ssh user on $TAG" "$(id -un)"
  ask_valid safe_token H_ADDR "    address of $TAG" "$TAG"
  # Constraint 24 is "hardcoding port 22 fails at the wrong layer" -- an ssh
  # failure surfaces as a bare rsync exit 255 and reads as a transfer problem.
  # The engine was fixed for it; this generator still wrote SSH_PORT=22 into
  # every config and never asked, so a non-22 host failed in exactly that way
  # until the operator found the field by hand.
  ask_valid safe_int  H_PORT "    ssh port on $TAG" "22"

  if ask_yn "    does $TAG PUSH to the hub instead of the hub pulling it?" n; then
    H_MODE=push
    note "    push hosts have no hub-side job; the watchdog reports them stale"
    note "    rather than trying to start something that should not exist."
  else
    H_MODE=pull
  fi

  # sources — offer the host's own mount points first.
  #
  # This is the one place plan talks to a remote machine. It runs `df -Pk` and
  # nothing else: read-only, no mutation, and entirely optional. If there is no
  # login yet the scan is skipped and paths are typed by hand, because a plan
  # you cannot write without provisioning first would invert the whole point of
  # the phase ordering.
  : > "$MIDX"
  if ask_yn "    scan $H_ADDR for its mount points? ${D}(read-only \`df\`; needs a login)${N}" n; then
    _scan_ssh="ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
    if scan_mounts_remote "$_scan_ssh -o BatchMode=yes" "$H_USER@$H_ADDR" > "$TMP/rm.$TAG" 2>/dev/null \
       || scan_mounts_remote "$_scan_ssh" "$H_USER@$H_ADDR" > "$TMP/rm.$TAG" 2>/dev/null; then
      if render_mount_menu "$MIDX" < "$TMP/rm.$TAG" > "$TMP/menu.$TAG"; then
        note "    Pick numbers below, or type any path."
        cat "$TMP/menu.$TAG"
      else
        warn "no usable filesystems reported by $H_ADDR"
      fi
    else
      warn "could not reach $H_ADDR to scan it — type paths instead"
    fi
  fi

  say "    Absolute paths to back up, one per line, blank line to finish."
  H_SOURCES=""; H_MOUNTSRC=0
  while :; do
    ask _s "      path" ""
    [ -z "$_s" ] && break
    _s=$(resolve_mount_choice "$MIDX" "$_s")
    [ -n "$_s" ] || { warn "no such entry in the list"; continue; }
    case "$_s" in /*) ;; *) warn "must be an absolute path"; continue ;; esac
    # Remember whether this source is itself a mount point: that is exactly the
    # case where an unmounted source looks like an empty directory and --delete
    # would propagate the emptiness over a good backup.
    if grep -qxF "$_s" "$MIDX" 2>/dev/null; then H_MOUNTSRC=1; fi
    safe_path "$_s" || { warn "path may not contain \" \$ \` \\ or a newline"; continue; }
    if [ -z "$H_SOURCES" ]; then H_SOURCES="$_s"; else H_SOURCES="$H_SOURCES
$_s"; fi
  done
  # Was `continue` when this lived inside plan's `while` loop. In a function it
  # would either escape the CALLER's loop or error out, depending on where it was
  # called from -- add-node does not call this from a loop at all.
  [ -n "$H_SOURCES" ] || { warn "no sources given — skipping $TAG"; return 1; }

  # excludes
  say "    Exclude patterns, one per line, blank line to finish."
  note "      Suggested: $(printf '%s' "$DEFAULT_EXCLUDES" | tr '\n' ' ')"
  note "      Exclude large sparse files by name (Docker.raw, *.qcow2) — openrsync"
  note "      has no --sparse and a 9.7 GB image once copied as 926 GB."
  H_EXCLUDES=""
  while :; do
    ask _e "      pattern ${D}(or 'default')${N}" ""
    [ -z "$_e" ] && break
    if [ "$_e" = "default" ]; then H_EXCLUDES="$DEFAULT_EXCLUDES"; continue; fi
    safe_path "$_e" || { warn "pattern may not contain \" \$ \` \\ or a newline"; continue; }
    if [ -z "$H_EXCLUDES" ]; then H_EXCLUDES="$_e"; else H_EXCLUDES="$H_EXCLUDES
$_e"; fi
  done

  # A mount point as a source is precisely the case the sentinel exists for, so
  # offer one here instead of leaving the operator to discover the field later.
  H_SENTINEL=""
  if [ "$H_MOUNTSRC" -eq 1 ]; then
    note "    One of those sources is a mount point. If it is ever unmounted it"
    note "    looks like an empty directory, and rsync --delete would copy that"
    note "    emptiness over a good backup. Naming a file inside it prevents that:"
    note "    the backup refuses to run when the file is not visible."
    ask _sent "    sentinel path inside the mount ${D}(blank to skip)${N}" ""
    if [ -n "$_sent" ]; then
      if safe_path "$_sent"; then H_SENTINEL="$_sent"
      else warn "ignored: path may not contain \" \$ \` \\ or a newline"; fi
    else
      warn "no sentinel — an unmounted source will not be detected for $TAG"
    fi
  fi

  # schedule -> freshness
  while :; do
    ask H_SCHED "    how often? ${D}(hourly|6h|daily|weekly|monthly)${N}" "daily"
    _ih=$(interval_hours "$H_SCHED")
    [ -n "$_ih" ] && break
    warn "pick one of: hourly 6h daily weekly monthly"
  done
  H_FRESH=$(freshness_for "$_ih")
  printf "    ${G}✓${N} %s → the watchdog will call %s stale after %sh\n" "$H_SCHED" "$TAG" "$H_FRESH"

  # Stash the host; written out only after the operator approves the summary.
  # P_ prefix deliberately: these get sourced into the writer's own shell, and
  # a bare USER= would clobber the environment variable of that name.
  {
    printf 'P_TAG=%s\nP_USER=%s\nP_ADDR=%s\nP_MODE=%s\nP_SCHED=%s\nP_FRESH=%s\nP_PORT=%s\n' \
           "$TAG" "$H_USER" "$H_ADDR" "$H_MODE" "$H_SCHED" "$H_FRESH" "$H_PORT"
    printf 'P_SENTINEL=%s\n' "\"$H_SENTINEL\""
  } > "$TMP/h.$TAG"
  printf '%s' "$H_SOURCES"  > "$TMP/src.$TAG"
  printf '%s' "$H_EXCLUDES" > "$TMP/exc.$TAG"

}

# write_host_conf <tag> <tmpdir> <target-tmpfile>
#
# Renders one host's engine config. Shared with `plan` for the same reason
# prompt_host is: `add-node` must produce a file byte-identical to the one plan
# would have written for the same answers, or a fabric grown one node at a time
# quietly diverges from a fabric planned in one go.
#
# Reads from the caller's scope: BACKUP_ROOT, PULL_LABEL_PREFIX, BWLIMIT,
# KEEP_HOURLY, KEEP_DAILY, KEEP_WEEKLY, KEEP_MONTHLY.
write_host_conf(){
  local TAG="$1" TMP="$2" ht="$3"
  # P_FRESH is read by the caller out of the h.<tag> file, not here.
  # shellcheck disable=SC2034
  local P_TAG P_USER P_ADDR P_MODE P_SCHED P_FRESH P_SENTINEL P_PORT
  # shellcheck disable=SC1090
  . "$TMP/h.$TAG"
  : > "$ht"; chmod 600 "$ht"
  {
  printf '# snapfabric host config for %s.\n' "$P_TAG"
  printf '# Read by snapshot-engine.sh. Sourced as shell; keep mode 0600.\n'
  if [ "$P_MODE" = push ]; then
    printf '# MODE=push: this runs ON %s, pushing to the hub. There is no hub-side job.\n' "$P_TAG"
  else
    printf '# MODE=pull: this runs on the hub, scheduled as %s.%s\n' "$PULL_LABEL_PREFIX" "$P_TAG"
  fi
  printf '\n'
  printf 'HOST_TAG="%s"\n'  "$P_TAG"
  printf 'SSH_USER="%s"\n'  "$P_USER"
  printf 'SSH_HOST="%s"\n'  "$P_ADDR"
  printf '# provision and the engine both read this.\n'
  printf 'SSH_PORT=%s\n' "${P_PORT:-22}"
  printf 'SSH_KEY="$HOME/.ssh/snapfabric_%s"\n' "$P_TAG"
  printf 'DEST_ROOT="%s"\n' "$BACKUP_ROOT"
  printf '# provision turns this into a launchd StartCalendarInterval or a systemd\n'
  printf '# OnCalendar=. FRESHNESS in the hub config is derived from it.\n'
  printf 'SCHEDULE="%s"\n\n' "$P_SCHED"
  printf '# Newline-separated. Never space-separated: a path containing a space\n'
  printf '# would be torn into two bogus sources (constraint 18).\n'
  printf 'SOURCES="%s"\n\n' "$(cat "$TMP/src.$TAG")"
  printf 'EXCLUDES="%s"\n\n' "$(cat "$TMP/exc.$TAG")"
  printf '# A path that must be visible on the source before a backup will run.\n'
  printf '# Set this to a file INSIDE any source that is a mount point: an\n'
  printf '# unmounted source looks like an empty directory, and --delete would\n'
  printf '# propagate that emptiness over a good backup. Empty disables the check.\n'
  printf 'SENTINEL="%s"\n\n' "${P_SENTINEL:-}"
  printf 'BWLIMIT=%s\n' "$BWLIMIT"
  printf 'KEEP_HOURLY=%s\n'  "$KEEP_HOURLY"
  printf 'KEEP_DAILY=%s\n'   "$KEEP_DAILY"
  printf 'KEEP_WEEKLY=%s\n'  "$KEEP_WEEKLY"
  printf 'KEEP_MONTHLY=%s\n' "$KEEP_MONTHLY"
  } >> "$ht"
}
