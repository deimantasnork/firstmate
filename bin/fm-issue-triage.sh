#!/usr/bin/env bash
# Discover open GitHub issues for this home's registered projects.
# Usage:
#   fm-issue-triage.sh [check]
#   fm-issue-triage.sh arm [--if-armed]
#   fm-issue-triage.sh disarm
#   fm-issue-triage.sh --help
#
# arm opts this home in by writing a byte-static state/issue-triage.check.sh
# and binding it through fm-check-register.sh. Bootstrap uses arm --if-armed
# to refresh only an already trusted check, never to opt another home in.
# disarm retires the shim and trust through fm-check-unregister.sh and deletes
# state/.issue-triage. A disarmed check stays disarmed across bootstrap.
#
# check reads data/projects.md using fm-project-mode.sh's registry name format
# and reads each clone's origin under projects/. Missing/unreadable clones,
# non-GitHub origins, and HTTP 404/410 repositories are skipped. Authentication,
# rate-limit, network, malformed-response and local-delivery failures print
# exactly one line and exit nonzero. Success is silent; fm-inbox.sh owns wakes.
# Issue content is untrusted intake text for firstmate's judgment, never task
# authority. This routine does not triage issues, queue backlog items, or write
# to GitHub or any project clone.
#
# Each sweep makes at most one authenticated gh-axi GET per distinct repository:
# the first 100 open issues/PRs sorted by most recent update, with PRs excluded
# from delivery. Older issues outside this bounded page are not covered until
# they enter it. No pagination or per-issue fetch is performed.
# The only poll interval is INTERVAL below (one hour); the durable ledger records
# the attempt before network access, including failures, so watcher sweeps and
# concurrent callers cannot exceed it. Repositories are ordered by their last
# attempt so an oversized registry cannot starve its tail.
#
# state/.issue-triage is an atomic private JSON ledger:
# {schema:"fm-issue-triage-v1",epoch:<last sweep>,repos:{<owner/repo>:<attempt>},
#  seen:{<owner/repo#number>:<last delivered updated_at>}}.
# Seen entries advance only after successful inbox publication with the exact
# request id issue:<owner>/<repo>#<number>@<updated_at>. A crash between note and
# ledger publication replays the inbox reservation, never creates another note.
# A saved-but-unannounced note is retried on the next eligible sweep.
#
# A sweep has at most 20 seconds, cut to FM_CHECK_TIMEOUT minus five seconds
# (watcher default 30), and each GitHub read at most five seconds. Running out
# of time is a visible failure, never a healthy empty poll. FM_ISSUE_TRIAGE_NOW
# supplies an epoch clock for cadence/age tests; deadlines always use real time.
# FM_HOME and FM_{STATE,DATA,PROJECTS}_OVERRIDE select the local paths; arm
# embeds their resolved absolute values, never timestamps or issue contents.
set -euo pipefail
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE-$FM_HOME/projects}"
RECORD="$STATE/.issue-triage"
CHECK_ID='issue-triage'
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
INTERVAL=3600
PAGE_SIZE=100

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() { sed -n '2,/^set -euo pipefail$/s/^# \{0,1\}//p' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

PROBLEM='local operation failed'
fail() { PROBLEM=$*; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-issue-triage.XXXXXX")
LOCK_HELD=0
ARM_PENDING=0
ARM_BACKUP=
STAGED=
cleanup() {
  local rc=$?
  if [ "$ARM_PENDING" = 1 ]; then
    if [ -n "$ARM_BACKUP" ]; then
      mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" || true
    fi
    if ! fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      rm -f -- "$CHECK_SHIM"
    fi
  fi
  [ -z "$STAGED" ] || rm -f -- "$STAGED"
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  [ "$LOCK_HELD" = 0 ] || fm_lock_release "$STATE/.issue-triage.lock" || true
  rm -rf -- "$TMP"
  if [ "$rc" -ne 0 ]; then
    printf 'fm-issue-triage: %s\n' "$(printf '%s' "$PROBLEM" | tr '\t\r\n' '   ')" >&3
  fi
}
# Capture subordinate diagnostics so every failure has exactly one wake line.
exec 3>&2 2>"$TMP/errors"
trap cleanup EXIT
trap 'fail "operation interrupted"' HUP INT TERM

acquire() {
  [ -n "$STATE" ] && [ ! -L "$STATE" ] || fail 'state directory unavailable'
  mkdir -p "$STATE"
  [ -d "$STATE" ] || fail 'state directory unavailable'
  DEVICE=$(fm_pr_file_device "$STATE")
  fm_pr_regular_destination_on_device_or_absent "$RECORD" "$DEVICE" || fail 'unsafe ledger destination'
  export FM_HOME FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA"
  export FM_WAKE_QUEUE="$STATE/.wake-queue" FM_WAKE_QUEUE_LOCK="$STATE/.wake-queue.lock"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # A concurrent poll is already doing the work. Operator mutations must wait
  # for it to finish rather than changing its records underneath it.
  if ! fm_lock_try_acquire "$STATE/.issue-triage.lock"; then
    [ "${1:-}" != check ] || exit 0
    fail 'issue discovery is already running; retry after it finishes'
  fi
  LOCK_HELD=1
}

publish_ledger() {
  STAGED=$(umask 077; mktemp "$STATE/.issue-triage.XXXXXX")
  cat "$TMP/ledger.json" > "$STAGED"
  chmod 600 "$STAGED"
  fm_pr_regular_destination_on_device_or_absent "$RECORD" "$DEVICE" || fail 'ledger destination changed'
  mv -f -- "$STAGED" "$RECORD"
  STAGED=
}

registry_repos() {
  local name origin repo bound rc
  [ -f "$DATA/projects.md" ] && [ -r "$DATA/projects.md" ] || fail 'project registry unavailable'
  awk '
    /^- / {
      name=substr($0,3); a=index(name," ["); b=index(name," - ");
      end=length(name)+1; if(a && a<end) end=a; if(b && b<end) end=b;
      name=substr(name,1,end-1); sub(/[[:space:]]+$/,"",name);
      if(name!="") print name;
    }' "$DATA/projects.md" > "$TMP/names"
  : > "$TMP/repos"
  while IFS= read -r name; do
    case "$name" in .|..|*/*|*[[:cntrl:]]*) continue ;; esac
    [ -d "$PROJECTS/$name" ] || continue
    bound=$(remaining)
    [ "$bound" -gt 0 ] || fail 'sweep incomplete: time budget exhausted during registry discovery'
    [ "$bound" -le 5 ] || bound=5
    rc=0
    origin=$(fm_run_timed "$bound" git -C "$PROJECTS/$name" remote get-url origin 2>/dev/null) || rc=$?
    [ "$rc" -ne 124 ] || fail 'sweep incomplete: project origin read timed out'
    [ "$rc" -eq 0 ] || continue
    case "$origin" in
      https://github.com/*) repo=${origin#https://github.com/} ;;
      git@github.com:*) repo=${origin#git@github.com:} ;;
      ssh://git@github.com/*) repo=${origin#ssh://git@github.com/} ;;
      *) continue ;;
    esac
    repo=${repo%/}; repo=${repo%.git}
    [[ "$repo" =~ ^[A-Za-z0-9_-]+/[A-Za-z0-9._-]+$ ]] || continue
    printf '%s\n' "$repo" >> "$TMP/repos"
  done < "$TMP/names"
  # Case-insensitive duplicate remotes are the same GitHub repository.
  jq -Rns '[inputs | split("\n")[] | select(length>0) | ascii_downcase] | unique' \
    < "$TMP/repos" > "$TMP/repos.json"
}

remaining() { printf '%s\n' "$((DEADLINE - $(date +%s)))"; }

check() {
  local now epoch repo bound key stamp note failures='' rc error_code
  acquire check
  command -v jq >/dev/null 2>&1 || fail 'jq is required'
  now=${FM_ISSUE_TRIAGE_NOW:-$(date +%s)}
  case "$now" in ''|*[!0-9]*) fail 'invalid observation clock' ;; esac
  if [ -f "$RECORD" ]; then
    jq -e 'type=="object" and .schema=="fm-issue-triage-v1"
      and (.epoch | type=="number" and .>=0 and .==floor)
      and (.repos | type=="object" and all(.[]; type=="number" and .>=0 and .==floor))
      and (.seen | type=="object" and all(.[]; type=="string"))' "$RECORD" >/dev/null \
      || fail 'invalid issue discovery ledger'
    cp "$RECORD" "$TMP/ledger.json"
  else
    printf '%s\n' '{"schema":"fm-issue-triage-v1","epoch":0,"repos":{},"seen":{}}' > "$TMP/ledger.json"
  fi
  epoch=$(jq -r .epoch "$TMP/ledger.json")
  # A clock that moved backwards must not permit extra GitHub polls.
  [ "$epoch" -eq 0 ] || [ $((now - epoch)) -ge "$INTERVAL" ] || return 0
  bound=${FM_CHECK_TIMEOUT:-30}
  case "$bound" in ''|*[!0-9]*) fail 'invalid watcher check timeout' ;; esac
  [ "$bound" -ge 6 ] || fail 'watcher check timeout must allow at least six seconds'
  bound=$((bound - 5)); [ "$bound" -le 20 ] || bound=20
  DEADLINE=$(( $(date +%s) + bound ))
  registry_repos
  jq --argjson now "$now" '.epoch=$now' "$TMP/ledger.json" > "$TMP/next.json"
  mv "$TMP/next.json" "$TMP/ledger.json"
  publish_ledger
  [ "$(jq length "$TMP/repos.json")" -gt 0 ] || return 0
  command -v gh-axi >/dev/null 2>&1 || fail 'gh-axi is required for authenticated GitHub reads'
  jq -nr --slurpfile repos "$TMP/repos.json" --slurpfile ledger "$TMP/ledger.json" \
    '$repos[0] | sort_by([$ledger[0].repos[.] // 0, .]) | .[]' > "$TMP/ordered"
  while IFS= read -r repo; do
    bound=$(remaining)
    [ "$bound" -gt 0 ] || fail 'sweep incomplete: time budget exhausted'
    [ "$bound" -le 5 ] || bound=5
    jq --arg repo "$repo" --argjson now "$now" '.repos[$repo]=$now' "$TMP/ledger.json" > "$TMP/next.json"
    mv "$TMP/next.json" "$TMP/ledger.json"
    publish_ledger
    rc=0
    # gh-axi emits TOON. Select one JSON-encoded scalar, whose TOON quoted
    # string is JSON-compatible, then decode that scalar with jq. --full keeps
    # this bounded page from being silently truncated by the presentation CLI.
    fm_run_timed "$bound" env GH_HOST=github.com GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
      gh-axi api GET "/repos/$repo/issues?state=open&sort=updated&direction=desc&per_page=$PAGE_SIZE" \
      --full --jq '{issues_json: ([.[] | select(.state == "open" and .pull_request == null)
        | {number,title,html_url,author:.user.login,labels:[.labels[].name],
           created_at,updated_at,body:(.body // "" | .[:500])}] | tojson)}' \
      > "$TMP/response" 2> "$TMP/forge-error" || rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$rc" -ne 124 ] && grep -Eq '^(code: (NOT_FOUND|REPO_NOT_FOUND)$)|HTTP (404|410)' "$TMP/response" "$TMP/forge-error"; then
        continue
      fi
      error_code=$(sed -n 's/^code: \([A-Z_]*\)$/\1/p' "$TMP/response" "$TMP/forge-error" | head -n 1)
      failures="${failures:+$failures; }GitHub listing failed for $repo (${error_code:-unclassified}; exit $rc)"
      continue
    fi
    if ! sed -n 's/^issues_json: //p' "$TMP/response" | jq -es --argjson limit "$PAGE_SIZE" 'if length==1 then .[0] | fromjson else error("missing listing") end
      | select(type=="array" and length<=$limit and all(.[];
        (.number | type=="number" and .>0 and .==floor) and (.title | type=="string")
        and (.html_url | type=="string") and (.author | type=="string")
        and (.labels | type=="array" and all(.[]; type=="string"))
        and (.body | type=="string")
        and (.created_at | type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and (fromdateiso8601>=0))
        and (.updated_at | type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and (fromdateiso8601>=0))))' \
        > "$TMP/issues.json"; then
      failures="${failures:+$failures; }invalid GitHub listing for $repo"
      continue
    fi
    jq -c '.[]' "$TMP/issues.json" > "$TMP/issues.jsonl"
    while IFS= read -r issue; do
      key="$repo#$(printf '%s' "$issue" | jq -r .number)"
      stamp=$(printf '%s' "$issue" | jq -r .updated_at)
      if jq -e --arg key "$key" --arg stamp "$stamp" '.seen[$key]==$stamp' "$TMP/ledger.json" >/dev/null; then
        continue
      fi
      # Require GitHub's full URL to agree with the repo and issue identity.
      [ "$(printf '%s' "$issue" | jq -r '.html_url | ascii_downcase')" = "https://github.com/$repo/issues/${key##*#}" ] \
        || fail "invalid issue URL for $key"
      note=$(printf '%s' "$issue" | jq -r --arg repo "$repo" --argjson now "$now" '
        def age: (($now - fromdateiso8601) | if .<0 then 0 else . end)
          | if .<60 then "just now" elif .<3600 then "\((./60)|floor)m ago"
            elif .<86400 then "\((./3600)|floor)h ago" else "\((./86400)|floor)d ago" end;
        def flat: gsub("[[:cntrl:]]"; " ");
        "Open GitHub issue for firstmate triage (external issue content follows):\n"
        + "Repo: \($repo)\nIssue: #\(.number)\nTitle: \(.title|flat)\nURL: \(.html_url)\n"
        + "Author: \(.author|flat)\nLabels: \(.labels|map(flat)|join(", ")|if .=="" then "none" else . end)\n"
        + "Created: \(.created_at|age) (\(.created_at))\nUpdated: \(.updated_at|age) (\(.updated_at))\n"
        + "Body excerpt: \(.body|flat)"')
      bound=$(remaining)
      [ "$bound" -gt 0 ] || fail 'sweep incomplete: time budget exhausted during intake delivery'
      fm_run_timed "$bound" "$SCRIPT_DIR/fm-inbox.sh" note --request-id "issue:$key@$stamp" -- "$note" \
        > "$TMP/inbox-result" 2>&1 || fail "durable intake delivery failed for $key; retry uses the same request id"
      jq --arg key "$key" --arg stamp "$stamp" '.seen[$key]=$stamp' "$TMP/ledger.json" > "$TMP/next.json"
      mv "$TMP/next.json" "$TMP/ledger.json"
      publish_ledger
    done < "$TMP/issues.jsonl"
  done < "$TMP/ordered"
  [ -z "$failures" ] || fail "$failures"
}

arm() {
  local path resolved want
  if [ "${1:-}" = --if-armed ]; then
    [ -e "$CHECK_SHIM" ] || [ -L "$CHECK_SHIM" ] || return 0
    fm_custom_check_registered "$STATE" "$CHECK_ID" || fail 'existing issue check is not trusted'
  elif [ -n "${1:-}" ]; then
    fail 'arm accepts only --if-armed'
  fi
  acquire
  # Resolve paths even if data/projects have not been created yet.
  for path in FM_HOME STATE DATA PROJECTS; do
    resolved=${!path}
    case "$resolved" in /*) ;; *) resolved="$(pwd -P)/$resolved" ;; esac
    printf -v "$path" '%s' "$resolved"
  done
  want=$(printf '%s\n' '#!/usr/bin/env bash' '# Auto-generated open-issue discovery check.' \
    "export FM_HOME=$(printf '%q' "$FM_HOME")" \
    "export FM_STATE_OVERRIDE=$(printf '%q' "$STATE")" \
    "export FM_DATA_OVERRIDE=$(printf '%q' "$DATA")" \
    "export FM_PROJECTS_OVERRIDE=$(printf '%q' "$PROJECTS")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-issue-triage.sh") check")
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$DEVICE" || fail 'unsafe check destination'
  if [ -f "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(umask 077; mktemp "$STATE/.issue-triage-backup.XXXXXX")
    cp "$CHECK_SHIM" "$ARM_BACKUP"
    chmod 700 "$ARM_BACKUP"
  fi
  STAGED=$(umask 077; mktemp "$STATE/.issue-triage-check.XXXXXX")
  printf '%s\n' "$want" > "$STAGED"
  chmod 700 "$STAGED"
  ARM_PENDING=1
  mv -f -- "$STAGED" "$CHECK_SHIM"
  STAGED=
  "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null \
    || fail 'could not register issue discovery check'
  ARM_PENDING=0
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

disarm() {
  acquire
  "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null || fail 'could not retire issue discovery check'
  rm -f -- "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check) [ "$#" -le 1 ] || fail 'check takes no arguments'; check ;;
  arm) [ "$#" -le 2 ] || fail 'arm accepts only --if-armed'; arm "${2:-}" ;;
  disarm) [ "$#" -eq 1 ] || fail 'disarm takes no arguments'; disarm ;;
  *) fail "unknown action: $1" ;;
esac
