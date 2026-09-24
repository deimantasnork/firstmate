#!/usr/bin/env bash
# fm-task-staging-lib.sh - the ONE owner of the rule that decides whether a
# task's staging directory under the shared /tmp is safe to use, and of the
# paths spawn and relaunch stage into.
#
# Every task has two, both at predictable paths:
#   - the per-task temp root /tmp/fm-<id>/, with Go's build temp nested at
#     gotmp/; teardown removes it through the task record's tasktmp=.
#   - the launch namespace /tmp/fm-<id>+<home-token>/, which holds the staged
#     launch command (bin/fm-spawn.sh's header owns launch delivery). The full
#     home-identity hash keeps equal task ids in different homes apart.
# Because the paths are predictable, each is used only as a real directory owned
# by this user and private to it (0700). A link, a non-directory, or a directory
# owned by anyone else is refused, so no other local user can plant or swap a
# file where a launch command is staged.
#
# A directory that is this user's own but whose mode lets others write into it
# (an older spawn created one under a looser umask) is repaired rather than
# refused. Its mode is tightened first, which closes the window, and only then
# is its content walked: it is reused only when every entry is this user's own
# and no regular file in it is hard-linked from elsewhere, since anything another
# user planted while it was writable would show there. The repair leaves that
# content in place.
#
# bin/fm-spawn.sh prepares each directory before staging into it, and
# bin/fm-control.sh's relaunch prepares both in its pre-stop checkpoint, so an
# unusable directory refuses a relaunch before the old agent stops instead of
# stranding the task with no agent.

# fm_task_temp_root <id> - print the task's per-task temp root.
fm_task_temp_root() {
  printf '/tmp/fm-%s' "$1"
}

# fm_task_launch_home_token <home> - print the full home-identity hash that
# namespaces <home>'s launch directories, or fail when none can be derived.
fm_task_launch_home_token() {
  local home=$1 root hash
  root=$(cd "$home" 2>/dev/null && pwd -P) || root=$home
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | shasum -a 256 | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | sha256sum | awk '{print $1}')
  else
    return 1
  fi
  case "$hash" in
    *[!0-9a-fA-F]*|'') return 1 ;;
  esac
  printf '%s' "$hash"
}

# fm_task_launch_dir <id> <home> - print the task's launch namespace for
# <home>, or fail when the home identity cannot be derived.
fm_task_launch_dir() {
  local token
  token=$(fm_task_launch_home_token "$2") || return 1
  printf '/tmp/fm-%s+%s' "$1" "$token"
}

# fm_task_staging_dir_prepare <label> <dir> - create <dir> private, or verify
# an existing one under the header's rule and repair it when that rule allows.
# Returns 0 once <dir> is a private directory this user owns, printing a note
# to stderr and setting FM_TASK_STAGING_REPAIRED=1 when it made a formerly
# writable directory private. Otherwise returns 1 with FM_TASK_STAGING_ERROR
# naming <label>, <dir>, and the reason, for the caller's refusal.
# shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
fm_task_staging_dir_prepare() {
  local label=$1 dir=$2 writable entry
  FM_TASK_STAGING_ERROR=
  FM_TASK_STAGING_REPAIRED=0
  if (umask 077 && mkdir "$dir") 2>/dev/null; then
    return 0
  fi
  if [ -L "$dir" ] || [ ! -d "$dir" ] || [ ! -O "$dir" ]; then
    FM_TASK_STAGING_ERROR="$label $dir already exists and is not a private directory owned by this user"
    return 1
  fi
  writable=$(find "$dir" -prune \( -perm -g=w -o -perm -o=w \) -print 2>/dev/null) || writable=unknown
  if ! chmod 700 "$dir" 2>/dev/null; then
    FM_TASK_STAGING_ERROR="$label $dir is owned by this user but could not be made private"
    return 1
  fi
  [ -n "$writable" ] || return 0
  if ! entry=$(find "$dir" \( ! -uid "$(id -u)" -o \( -type f -links +1 \) \) -print -quit 2>/dev/null); then
    FM_TASK_STAGING_ERROR="$label $dir was writable by other users and its content could not be fully inspected"
    return 1
  fi
  if [ -n "$entry" ]; then
    FM_TASK_STAGING_ERROR="$label $dir was writable by other users and holds $entry, which is not this user's own unshared content"
    return 1
  fi
  FM_TASK_STAGING_REPAIRED=1
  echo "note: $label $dir was writable by other users and held only this user's own content; made it private (0700) and reused it" >&2
  return 0
}
