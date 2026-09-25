#!/bin/bash
# snapfabric — argument and config-value validation.
#
# Sourced by tools that accept operator input. NOT sourced by
# agents/macos/snapfabric-remote.sh: that runs as an SSH forced command and is
# deliberately self-contained, so it carries its own copy of safe_token().
# tests/test-constraints.sh asserts the two copies are identical — a writer and
# an allowlist that disagree is exactly the divergence that let a fix land in
# one agent and never reach the other.

# Plain tokens: host tags, usernames, hostnames, scheduler labels.
# Rejecting shell metacharacters outright means even a mistake in a downstream
# quote cannot become command execution.
safe_token(){
  case "$1" in
    *[\;\&\|\`\$\(\)\<\>\'\"*?[]*|*' '*|"") return 1 ;;
    *) return 0 ;;
  esac
}

# Verb-API arguments. Same rejected charset as safe_token, but spaces ARE
# allowed: macOS volume names routinely contain them -- Apple's own default name
# for a Time Machine drive is "Backups of <your computer>". A space-free
# allowlist made such a volume impossible to manage and hard-failed `plan`.
safe_arg(){
  case "$1" in
    *[\;\&\|\`\$\(\)\<\>\'\"*?[]*|"") return 1 ;;
    *) return 0 ;;
  esac
}

# Paths and rsync patterns. Spaces are legal here — constraint 18 exists
# because "/srv/My Documents" is a real thing — so this is deliberately looser
# than safe_token. It still rejects everything that survives inside the double
# quotes we emit into a sourced config: " $ ` \ and newline.
safe_path(){
  case "$1" in
    "") return 1 ;;
    *[\"\$\`\\]*) return 1 ;;
    *'
'*) return 1 ;;
    *) return 0 ;;
  esac
}

# Positive integers, for retention counts and freshness hours.
safe_int(){
  case "$1" in
    ""|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Snapshot name -> unix epoch, portable across a BSD (macOS) and GNU (Linux) date.
#
# Lived in three places and was then written a FOURTH time, in the watchdog,
# with only the GNU branch. On a macOS watchdog every timestamp parsed to 0, so
# every host was skipped from the staleness check and the run reported "all
# clear" having examined nothing -- constraints 28 and 36 reintroduced inside
# the script whose whole job is to enforce them. The docs specifically say to
# run the watchdog from a second machine, so a Mac watchdog is the expected
# case, not an edge one. One definition, shared, so a fifth cannot drift.
epoch_of(){
  local n="$1"
  date -j -f "%Y-%m-%d_%H%M%S" "$n" +%s 2>/dev/null && return 0
  date -d "$(echo "$n" | sed 's/_/ /; s/\(..\)\(..\)\(..\)$/\1:\2:\3/')" +%s 2>/dev/null && return 0
  echo 0
}
