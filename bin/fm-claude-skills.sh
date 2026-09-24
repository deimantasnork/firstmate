#!/usr/bin/env bash
# Link the shared skills into the Claude config store a claude launch is about
# to use, so a worker can invoke them whichever account store its launch
# selected.
#
# Usage: fm-claude-skills.sh <store>
#   <store>  the absolute Claude config directory the launch selected
# Prints one line per skill it linked; prints nothing when nothing was missing.
#
# WHY THIS EXISTS. Claude Code reads user skills from <store>/skills, and each
# account store is its own directory, so a skill installed once under the
# shared $HOME/.agents/skills reaches only the stores someone linked it into.
# A worker launched on any other store cannot run it - a no-mistakes ship
# cannot even reach /no-mistakes.
#
# THE CONTRACT. For each directory $HOME/.agents/skills/<name>, hidden names
# skipped, this creates the symlink <store>/skills/<name> pointing at that
# absolute shared path when nothing exists at <store>/skills/<name>. Any
# existing entry - a directory, a file, or a symlink, dangling or not - is left
# untouched, so a store-local copy or an operator's own link always wins.
# Nothing is ever removed or replaced, and nothing outside <store>/skills is
# written. <store>/skills is created when a shared skill needs it, the same
# way claude creates its own store directory on first launch.
#
# bin/fm-spawn.sh calls this for every claude launch, right after workspace
# trust registration, with the one store that launch reads and no other: the
# store its launch assembly selects (a home's worker account pin, else the
# per-dispatch account store, a secondmate home's recorded store, or the
# forwarded CLAUDE_CONFIG_DIR), or $HOME/.claude when none is set. An absent
# shared directory is a no-op. Exit 0 when every shared skill is present in
# <store>/skills afterwards, 1 with one line per failure on stderr otherwise,
# and 2 on a usage error; the spawn treats a failure as a warning, since a
# missing skill limits the worker but does not wedge it.
set -u

usage() {
  echo "usage: fm-claude-skills.sh <store>" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage
STORE=$1
case "$STORE" in
/*) ;;
*)
  echo "error: Claude store '$STORE' is not an absolute path" >&2
  exit 2
  ;;
esac

SHARED=${HOME:+$HOME/.agents/skills}
[ -n "$SHARED" ] && [ -d "$SHARED" ] || exit 0

DEST=$STORE/skills
status=0
for src in "$SHARED"/*; do
  [ -d "$src" ] || continue
  name=${src##*/}
  link=$DEST/$name
  if [ -e "$link" ] || [ -L "$link" ]; then
    continue
  fi
  if ! mkdir -p "$DEST" 2>/dev/null || [ ! -d "$DEST" ]; then
    echo "error: cannot create the skills directory $DEST for shared skill $name" >&2
    status=1
    continue
  fi
  if ln -s "$src" "$link" 2>/dev/null; then
    echo "linked $link -> $src"
  elif [ -e "$link" ] || [ -L "$link" ]; then
    # Another launch created the entry between the check and the link.
    continue
  else
    echo "error: cannot link shared skill $name into $DEST" >&2
    status=1
  fi
done
exit "$status"
