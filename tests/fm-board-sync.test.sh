#!/usr/bin/env bash
# Behavior tests for bin/fm-board-sync.py, the herdr-board fleet mirror.
#
# Every case drives the executable's public subcommands against a fake `board`
# CLI that keeps its boards, columns, and cards in a JSON file next to itself,
# a fake `crontab` that keeps the user crontab in a fixture file, and a fake
# current-state reader that prints a per-home fixture line for each task. The
# fakes are found through PATH (and the fixture code root for the state
# reader), so the scheduled entry arm installs can itself be executed under a
# cron-like empty environment. The real crontab is never read or written.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-board-sync)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
BASE_PATH=$PATH
DB="$FAKEBIN/board.json"
CALLS="$FAKEBIN/board.calls"
CRONTAB_FILE="$FAKEBIN/crontab.txt"
CRONTAB_WRITES="$FAKEBIN/crontab.writes"
MAIN="$TMP_ROOT/main"
MATE="$TMP_ROOT/mate"
LEGACY_DIR="$TMP_ROOT/legacy"
LEGACY="$LEGACY_DIR/fm-board-sync.py"
SYNC="$ROOT/bin/fm-board-sync.py"
HOME_SYNC="$MAIN/bin/fm-board-sync.py"

cat > "$FAKEBIN/board" <<'PY'
#!/usr/bin/env python3
# Fake herdr-board CLI: the subset of commands the mirror is allowed to use.
import json
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
db_path = os.path.join(here, "board.json")
args = sys.argv[1:]
with open(os.path.join(here, "board.calls"), "a") as fh:
    fh.write(json.dumps(args) + "\n")
try:
    with open(db_path) as fh:
        db = json.load(fh)
except FileNotFoundError:
    db = {"boards": [], "columns": [], "cards": [], "next": 1, "daemon": True, "start_ok": True}


def opt(name):
    return args[args.index(name) + 1]


def save():
    with open(db_path, "w") as fh:
        json.dump(db, fh)


def out(obj):
    print(json.dumps(obj))


def new_id():
    n = db["next"]
    db["next"] += 1
    return n


def card(cid):
    return next(c for c in db["cards"] if c["id"] == int(cid) and c["board_id"] == int(opt("--board")))


def column(bid, name):
    return next(c for c in db["columns"] if c["board_id"] == bid and c["name"] == name)


json_out = "--json" in args
verb = args[:2]
if verb == ["daemon", "status"] and json_out:
    out({"herdr_connected": db["daemon"]})
elif verb == ["daemon", "start"]:
    if db["start_ok"]:
        db["daemon"] = True
        save()
elif not db["daemon"]:
    print("daemon not running", file=sys.stderr)
    sys.exit(1)
elif db.get("broken"):
    print("board is broken", file=sys.stderr)
    sys.exit(1)
elif verb == ["board", "list"] and json_out:
    out([b for b in db["boards"] if b["project"] == opt("--project")])
elif verb == ["board", "create"] and json_out:
    b = {"id": new_id(), "name": args[2], "project": opt("--project")}
    db["boards"].append(b)
    save()
    out({"board": b})
elif verb == ["column", "list"] and json_out:
    out([c for c in db["columns"] if c["board_id"] == int(opt("--board"))])
elif verb == ["column", "create"] and json_out:
    c = {"id": new_id(), "name": opt("--name"), "trigger": opt("--trigger"),
         "position": int(opt("--position")), "board_id": int(opt("--board"))}
    db["columns"].append(c)
    save()
    out({"column": c})
elif verb == ["card", "list"] and json_out and opt("--visibility") == "all":
    out([c for c in db["cards"] if c["board_id"] == int(opt("--board"))])
elif verb == ["card", "create"] and json_out:
    bid = int(opt("--board"))
    c = {"id": new_id(), "title": opt("--title"), "description": opt("-d"),
         "column_id": column(bid, opt("--column"))["id"], "board_id": bid,
         "archived_at": None, "badge": "idle"}
    db["cards"].append(c)
    save()
    out({"card": c})
elif verb == ["card", "move"] and json_out:
    c = card(args[2])
    c["column_id"] = column(c["board_id"], args[3])["id"]
    save()
    out({"card": c})
elif verb == ["card", "edit"] and json_out:
    c = card(args[2])
    c["title"], c["description"] = opt("--title"), opt("-d")
    save()
    out({"card": c})
elif verb == ["card", "archive"] and json_out:
    c = card(args[2])
    c["archived_at"] = "2026-09-24T00:00:00Z"
    save()
    out({"card": c})
elif verb == ["card", "restore"] and json_out:
    c = card(args[2])
    c["archived_at"] = None
    save()
    out({"card": c})
else:
    print("fake board: unsupported command: " + " ".join(args), file=sys.stderr)
    sys.exit(2)
PY
chmod +x "$FAKEBIN/board"

cat > "$FAKEBIN/crontab" <<'SH'
#!/usr/bin/env bash
# Fake crontab: `crontab -l` and `crontab <file>` against a fixture file.
here=$(cd "$(dirname "$0")" && pwd)
case "${1:-}" in
  -l)
    if [ -f "$here/crontab.txt" ]; then
      cat "$here/crontab.txt"
    else
      echo "no crontab for fixture" >&2
      exit 1
    fi
    ;;
  -*) echo "fake crontab: unsupported $*" >&2; exit 2 ;;
  *)
    cp "$1" "$here/crontab.txt"
    echo write >> "$here/crontab.writes"
    ;;
esac
SH
chmod +x "$FAKEBIN/crontab"

write_crew_state_reader() {  # <dest>
  cat > "$1" <<'SH'
#!/usr/bin/env bash
# Fake current-state reader: prints this home's fixture line for the task.
f="$FM_HOME/fake-crew-state/$1"
if [ -f "$f" ]; then cat "$f"; else echo "state: unknown · source: none · no fixture"; fi
SH
  chmod +x "$1"
}

crew() {  # <home> <task> <state line>
  mkdir -p "$1/fake-crew-state"
  printf '%s\n' "$3" > "$1/fake-crew-state/$2"
}

make_homes() {
  rm -rf "$MAIN" "$MATE" "$DB" "$CALLS" "$CRONTAB_FILE" "$CRONTAB_WRITES"
  mkdir -p "$MAIN/data" "$MAIN/state" "$MAIN/bin" "$MATE/data" "$MATE/state"
  cp "$SYNC" "$HOME_SYNC"
  write_crew_state_reader "$MAIN/bin/fm-crew-state.sh"
  cat > "$MAIN/data/secondmates.md" <<EOF
- mate - Owns the app domain. (home: $MATE; scope: the app; projects: app; added 2026-09-17)
- gone - Owns nothing. (home: $TMP_ROOT/no-such-home; scope: none; projects: none; added 2026-09-17)
EOF
  cat > "$MAIN/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] fix-login - Fix the login redirect (repo: webapp) (kind: ship) (since 2026-09-20)
  Ticket: https://example.test/issues/7
- [ ] val-task - Validate the parser (repo: parser) (kind: ship) (since 2026-09-20)
- [ ] stuck-task - Stuck thing (repo: -) (kind: ship) (since 2026-09-20)
- [ ] ready-task - Ready thing (repo: webapp) (kind: ship) (since 2026-09-20)
## Queued
- [ ] later-task - Later work (repo: webapp) (kind: ship) (priority: 1) (since 2026-09-21) blocked-by: fix-login
  See https://example.test/notes/1 for context.
- [ ] held-task - Captain call (kind: captain) (hold-kind: captain) (since 2026-09-21)
## Done
- [x] old-task - Finished long ago (repo: webapp) (kind: ship) (since 2026-09-01)
EOF
  cat > "$MATE/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] mate-task - Mate work (repo: app) (kind: ship) (since 2026-09-22)
EOF
  printf 'kind=ship\nworktree=/wt/fix-login\npr=https://example.test/pull/9\n' > "$MAIN/state/fix-login.meta"
  printf 'kind=ship\nworktree=/wt/val\n' > "$MAIN/state/val-task.meta"
  printf 'kind=scout\nproject=/p/webapp\nworktree=/wt/orphan\n' > "$MAIN/state/orphan-scout.meta"
  printf 'kind=secondmate\n' > "$MAIN/state/mate.meta"
  crew "$MAIN" fix-login "state: working · source: pane · harness busy"
  crew "$MAIN" val-task "state: working · source: run-step · validating (review)"
  crew "$MAIN" stuck-task "state: blocked · source: status-log · waiting on a credential"
  crew "$MAIN" ready-task "state: done · source: run-step · PR green"
  crew "$MAIN" orphan-scout "state: paused · source: status-log · rate limit"
}

# mirror <args...>: run the repo's copy for FM_HOME=$MAIN with the fakes.
mirror() {
  PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$MAIN" FM_CREW_STATE_BIN="$MAIN/bin/fm-crew-state.sh" \
    "$SYNC" "$@"
}

# home_sync <args...>: run the home's own copy, as the schedule does.
home_sync() {
  (cd "$TMP_ROOT" && PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$MAIN" "$HOME_SYNC" "$@")
}

# board_dump: one "key|column|title|state" row per card, sorted by key.
board_dump() {
  python3 - "$DB" <<'PY'
import json, re, sys
db = json.load(open(sys.argv[1]))
cols = {c["id"]: c["name"] for c in db["columns"]}
rows = []
for c in db["cards"]:
    key = re.search(r"^fm-task: (\S+)$", c["description"], re.M).group(1)
    rows.append(f"{key}|{cols[c['column_id']]}|{c['title']}|{'archived' if c['archived_at'] else 'live'}")
print("\n".join(sorted(rows)))
PY
}

board_columns() {
  python3 - "$DB" <<'PY'
import json, sys
db = json.load(open(sys.argv[1]))
for c in sorted(db["columns"], key=lambda c: c["position"]):
    print("%s:%s:%s" % (c["name"], c["position"], c["trigger"]))
PY
}

board_boards() {
  python3 - "$DB" <<'PY'
import json, sys
for b in json.load(open(sys.argv[1]))["boards"]:
    print("%s|%s" % (b["name"], b["project"]))
PY
}

card_desc() {  # <key>
  python3 - "$DB" "$1" <<'PY'
import json, sys
db = json.load(open(sys.argv[1]))
for c in db["cards"]:
    if c["description"].startswith(f"fm-task: {sys.argv[2]}\n") or c["description"] == f"fm-task: {sys.argv[2]}":
        print(c["description"])
PY
}

# mutating_calls: board calls that change a card, board, or column.
mutating_calls() {
  [ -f "$CALLS" ] || return 0
  python3 - "$CALLS" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    a = json.loads(line)
    if a[:2] not in (["daemon", "status"], ["board", "list"], ["column", "list"], ["card", "list"]):
        print(" ".join(a[:2]))
PY
}

set_daemon() {  # <connected true|false> <start_ok true|false>
  python3 - "$DB" "$1" "$2" <<'PY'
import json, sys
db = json.load(open(sys.argv[1]))
db["daemon"], db["start_ok"] = sys.argv[2] == "true", sys.argv[3] == "true"
json.dump(db, open(sys.argv[1], "w"))
PY
}

break_board() {
  python3 - "$DB" <<'PY'
import json, os, sys
p = sys.argv[1]
db = json.load(open(p)) if os.path.exists(p) else {"boards": [], "columns": [], "cards": [], "next": 1, "daemon": True, "start_ok": True}
db["broken"] = True
json.dump(db, open(p, "w"))
PY
}

EXPECTED_FIRST="main/fix-login|In Progress|[working] Fix the login redirect|live
main/held-task|Todo|[held] Captain call|live
main/later-task|Todo|[planned] Later work|live
main/orphan-scout|In Progress|[blocked] orphan-scout|live
main/ready-task|Done|[ready] Ready thing|live
main/stuck-task|In Progress|[blocked] Stuck thing|live
main/val-task|In Review|[validating] Validate the parser|live
mate/mate-task|Todo|[planned] Mate work|live"

test_first_pass_builds_the_board() {
  local rc
  make_homes
  mirror run; rc=$?
  expect_code 0 "$rc" "first pass"
  assert_equals "$EXPECTED_FIRST" "$(board_dump)" "cards carry the stage tag, column, and title for every live item"
  assert_equals "Todo:0:manual
In Progress:1:manual
In Review:2:manual
Done:3:manual" "$(board_columns)" "the Fleet board gets the four manual columns in order"
  assert_equals "Fleet|$MAIN" "$(board_boards)" "one Fleet board in the main home's project"
  assert_equals "fm-task: main/fix-login
Project: webapp
Stage: in development
Worktree: /wt/fix-login
PR: https://example.test/pull/9
Ticket: https://example.test/issues/7" "$(card_desc main/fix-login)" "a backlog card lists project, stage, worktree, PR, and ticket"
  assert_equals "fm-task: main/later-task
Project: webapp
Stage: planned
Ticket: https://example.test/notes/1
Blocked by: fix-login" "$(card_desc main/later-task)" "a queued card falls back to any link and lists its blocker"
  assert_equals "fm-task: main/orphan-scout
Stage: in development - paused
Project: /p/webapp
Worktree: /wt/orphan" "$(card_desc main/orphan-scout)" "a live worktree without a backlog item gets its own card"
  assert_equals "fm-task: main/val-task
Project: parser
Stage: in validation (review)
Worktree: /wt/val" "$(card_desc main/val-task)" "a validating task names its validation step"
  assert_equals "fm-task: main/stuck-task
Stage: in development - blocked" "$(card_desc main/stuck-task)" "a '-' repo is left out"
  assert_contains "$(cat "$MAIN/state/.board-sync.log")" "synced 8 card change(s)" "a pass that changed cards logs the count"
  assert_contains "$(cat "$MAIN/state/.board-sync.last-run")" " ok 8" "the pass records its result"
  pass "fm-board-sync: first pass builds the Fleet board from every home's backlog and live worktrees"
}

test_unchanged_pass_changes_nothing() {
  local log_before
  make_homes
  mirror run || fail "setup pass"
  log_before=$(cat "$MAIN/state/.board-sync.log")
  : > "$CALLS"
  mirror run || fail "second pass"
  assert_equals "" "$(mutating_calls)" "an unchanged fleet makes no board changes"
  assert_equals "$log_before" "$(cat "$MAIN/state/.board-sync.log")" "an unchanged pass stays quiet"
  assert_contains "$(cat "$MAIN/state/.board-sync.last-run")" " ok 0" "the quiet pass is still recorded"
  pass "fm-board-sync: an unchanged fleet leaves the board untouched and the log quiet"
}

test_stage_changes_release_and_return() {
  make_homes
  mirror run || fail "setup pass"
  crew "$MAIN" val-task "state: done · source: run-step · checks green"
  crew "$MAIN" stuck-task "state: working · source: pane · harness busy"
  python3 - "$MAIN/data/backlog.md" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines(True)
open(p, "w").write("".join(l for l in lines if "later-task" not in l and "example.test/notes" not in l))
PY
  mirror run || fail "transition pass"
  assert_contains "$(board_dump)" "main/val-task|Done|[ready] Validate the parser|live" "finished validation moves to Done as ready"
  assert_contains "$(board_dump)" "main/stuck-task|In Progress|[working] Stuck thing|live" "an unblocked task drops its blocked tag"
  assert_contains "$(board_dump)" "main/later-task|Todo|[planned] Later work|archived" "released work is archived, not deleted"
  python3 - "$MAIN/data/backlog.md" <<'PY'
import sys
p = sys.argv[1]
item = "- [ ] later-task - Later work (repo: webapp) (kind: ship) (since 2026-09-21)\n"
text = open(p).read().replace("## Queued\n", "## Queued\n" + item)
open(p, "w").write(text)
PY
  : > "$CALLS"
  mirror run || fail "return pass"
  assert_contains "$(board_dump)" "main/later-task|Todo|[planned] Later work|live" "a task that comes back is restored"
  assert_contains "$(mutating_calls)" "card restore" "the returning card is restored rather than recreated"
  assert_not_contains "$(mutating_calls)" "card create" "no duplicate card is created"
  pass "fm-board-sync: stage changes move and retag cards, released work archives, returning work restores"
}

test_unreadable_backlog_never_archives() {
  make_homes
  mirror run || fail "setup pass"
  rm "$MATE/data/backlog.md"
  : > "$CALLS"
  mirror run || fail "pass without the mate backlog"
  assert_contains "$(board_dump)" "mate/mate-task|Todo|[planned] Mate work|live" "a home whose backlog is unreadable keeps its cards"
  assert_equals "" "$(mutating_calls)" "nothing is archived for an unreadable home"
  assert_contains "$(cat "$MAIN/state/.board-sync.log")" "archive skipped for mate/mate-task: mate backlog unreadable" "the skipped archive is logged"
  pass "fm-board-sync: a home whose backlog cannot be read never has its cards archived"
}

test_daemon_start_and_unavailable() {
  local rc
  make_homes
  mirror run || fail "setup pass"
  set_daemon false true
  : > "$CALLS"
  mirror run; rc=$?
  expect_code 0 "$rc" "a pass that starts the board daemon"
  assert_grep '["daemon", "start"]' "$CALLS" "a disconnected daemon is started"
  set_daemon false false
  mirror run; rc=$?
  expect_code 1 "$rc" "a pass with the board daemon unavailable"
  assert_contains "$(tail -1 "$MAIN/state/.board-sync.log")" "board daemon unavailable" "an unavailable daemon is logged"
  assert_contains "$(cat "$MAIN/state/.board-sync.last-run")" "failed board daemon unavailable" "the failed pass is recorded"
  pass "fm-board-sync: the board daemon is started when needed and an unavailable one fails the pass"
}

test_busy_lock_skips_quietly() {
  local rc holder
  make_homes
  python3 -c 'import fcntl, sys, time
f = open(sys.argv[1], "w"); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2], "w").close(); time.sleep(30)' \
    "$MAIN/state/.board-sync.lock" "$TMP_ROOT/holder.ready" &
  holder=$!
  while [ ! -e "$TMP_ROOT/holder.ready" ]; do sleep 0.1; done
  mirror run; rc=$?
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  rm -f "$TMP_ROOT/holder.ready"
  expect_code 0 "$rc" "a pass while another holds the lock"
  assert_absent "$CALLS" "a pass that finds the lock held never calls the board"
  pass "fm-board-sync: a pass that finds another pass running exits quietly"
}

test_only_card_lifecycle_commands_are_used() {
  make_homes
  mirror run || fail "setup pass"
  crew "$MAIN" val-task "state: done · source: run-step · checks green"
  rm "$MAIN/state/orphan-scout.meta"
  mirror run || fail "second pass"
  local verbs
  verbs=$(python3 -c 'import json, sys
print("\n".join(sorted({" ".join(json.loads(l)[:2]) for l in open(sys.argv[1])})))' "$CALLS")
  assert_equals "board create
board list
card archive
card create
card edit
card list
card move
column create
column list
daemon status" "$verbs" "the mirror only lists, creates, moves, edits, and archives through the board CLI"
  assert_equals "idle" "$(python3 -c 'import json, sys; print(",".join(sorted({c["badge"] for c in json.load(open(sys.argv[1]))["cards"]})))' "$DB")" \
    "the daemon-owned badge is never touched"
  pass "fm-board-sync: the mirror uses only card lifecycle commands and leaves the badge alone"
}

LEGACY_LINE="* * * * * /usr/bin/python3 $LEGACY >/dev/null 2>&1"
OTHER_LINE="*/10 * * * * /usr/local/bin/other-job.sh >/dev/null 2>&1"

seed_legacy_crontab() {
  mkdir -p "$LEGACY_DIR"
  printf 'pass\n' > "$LEGACY"
  printf '%s\n%s\n' "$OTHER_LINE" "$LEGACY_LINE" > "$CRONTAB_FILE"
  rm -f "$CRONTAB_WRITES"
}

test_arm_refuses_to_run_beside_another_mirror() {
  local rc err before
  make_homes
  seed_legacy_crontab
  before=$(cat "$CRONTAB_FILE")
  err=$(home_sync arm 2>&1 >/dev/null); rc=$?
  expect_code 1 "$rc" "arm beside a host mirror without --replace"
  assert_contains "$err" "another fleet mirror is scheduled" "the refusal names the conflict"
  assert_contains "$err" "$LEGACY" "the refusal shows the other entry"
  assert_contains "$err" "--replace" "the refusal names the takeover flag"
  assert_equals "$before" "$(cat "$CRONTAB_FILE")" "the crontab is unchanged"
  assert_absent "$CALLS" "no pass runs"
  pass "fm-board-sync: arm refuses to schedule a second mirror beside the host one"
}

test_arm_takes_over_disarm_restores() {
  local out rc line cmd before_run status
  make_homes
  seed_legacy_crontab
  out=$(home_sync arm --replace "$LEGACY" 2>&1); rc=$?
  expect_code 0 "$rc" "arm --replace"
  assert_equals "1" "$(wc -l < "$CRONTAB_WRITES" | tr -d ' ')" "the takeover is one crontab write"
  assert_equals "$OTHER_LINE" "$(sed -n 1p "$CRONTAB_FILE")" "unrelated entries are kept in place"
  assert_equals "2" "$(wc -l < "$CRONTAB_FILE" | tr -d ' ')" "the host entry is replaced, not added to"
  line=$(sed -n 2p "$CRONTAB_FILE")
  assert_contains "$line" "* * * * * FM_HOME=$MAIN PATH=" "the entry runs every minute and pins the home"
  assert_contains "$line" "$FAKEBIN" "the entry pins the invoking PATH"
  assert_contains "$line" "$HOME_SYNC run >/dev/null 2>&1 # fm-board-sync home=$MAIN" "the entry runs the home's own copy"
  assert_not_contains "$line" "$LEGACY" "the host script is no longer scheduled"
  assert_contains "$out" "replaced (disarm restores it): $LEGACY_LINE" "arm reports what it replaced"
  assert_contains "$out" "first pass ok" "arm runs a first pass"
  assert_equals "$EXPECTED_FIRST" "$(board_dump)" "the first pass mirrors the fleet"

  # The installed entry works as cron would run it: an empty environment.
  crew "$MAIN" fix-login "state: done · source: run-step · checks green"
  cmd=$(printf '%s\n' "$line" | cut -d' ' -f6-)
  before_run=$(cat "$MAIN/state/.board-sync.last-run")
  sleep 1
  env -i HOME="$TMP_ROOT" /bin/sh -c "$cmd"
  assert_not_equals "$before_run" "$(cat "$MAIN/state/.board-sync.last-run")" "the scheduled command runs a pass"
  assert_contains "$(board_dump)" "main/fix-login|Done|[ready] Fix the login redirect|live" \
    "the scheduled pass reads current state through the pinned PATH and home"

  out=$(home_sync arm 2>&1); rc=$?
  expect_code 0 "$rc" "re-arm"
  assert_equals "1" "$(grep -c 'fm-board-sync home=' "$CRONTAB_FILE")" "re-arming keeps one entry"

  status=$(home_sync status 2>&1)
  assert_contains "$status" "schedule: armed" "status reports the schedule"
  assert_contains "$status" "replaced entries disarm restores:" "status lists the replaced entry"
  assert_contains "$status" "$LEGACY_LINE" "status shows the host entry"
  assert_contains "$status" "last pass: " "status reports the last pass"
  assert_contains "$status" " ok " "the last pass succeeded"

  out=$(home_sync disarm 2>&1); rc=$?
  expect_code 0 "$rc" "disarm"
  assert_equals "$OTHER_LINE
$LEGACY_LINE" "$(cat "$CRONTAB_FILE")" "disarm restores the host schedule exactly"
  assert_contains "$out" "restored: $LEGACY_LINE" "disarm reports the restore"
  assert_absent "$MAIN/state/.board-sync.replaced" "the replaced record is consumed"
  out=$(home_sync disarm 2>&1); rc=$?
  expect_code 0 "$rc" "second disarm"
  assert_contains "$out" "removed 0 schedule entries" "a second disarm is a no-op"
  assert_equals "$OTHER_LINE
$LEGACY_LINE" "$(cat "$CRONTAB_FILE")" "the crontab stays restored"
  assert_contains "$(home_sync status 2>&1)" "schedule: not armed" "status reports the disarmed schedule"
  pass "fm-board-sync: arm --replace takes over the host schedule in one write and disarm restores it"
}

test_arm_waits_for_the_running_host_pass() {
  local out rc runner
  make_homes
  seed_legacy_crontab
  cat > "$LEGACY" <<EOF
import time
time.sleep(6)
open("$TMP_ROOT/legacy.finished", "w").close()
EOF
  rm -f "$TMP_ROOT/legacy.finished"
  python3 "$LEGACY" &
  runner=$!
  sleep 0.5
  out=$(home_sync arm --replace "$LEGACY" 2>&1); rc=$?
  expect_code 0 "$rc" "arm while the host pass runs"
  assert_contains "$out" "waiting for the running pass of $LEGACY" "arm says it is waiting"
  assert_present "$TMP_ROOT/legacy.finished" "the first pass starts only after the host pass finished"
  wait "$runner"
  pass "fm-board-sync: arm waits for a running host pass before its own first pass"
}

test_failed_first_pass_rolls_the_takeover_back() {
  local out rc
  make_homes
  seed_legacy_crontab
  break_board
  out=$(home_sync arm --replace "$LEGACY" 2>&1); rc=$?
  expect_code 1 "$rc" "a takeover whose first pass fails"
  assert_contains "$out" "first pass failed" "arm reports the failed pass"
  assert_contains "$out" "the takeover is rolled back and $LEGACY is scheduled again" "arm reports the rollback"
  assert_equals "$OTHER_LINE
$LEGACY_LINE" "$(cat "$CRONTAB_FILE")" "the host schedule is back exactly as it was"
  assert_absent "$MAIN/state/.board-sync.replaced" "nothing is left for disarm to restore"
  out=$(home_sync arm 2>&1); rc=$?
  expect_code 1 "$rc" "a plain arm beside the restored host entry"
  assert_contains "$out" "another fleet mirror is scheduled" "the restored host entry blocks a plain arm again"
  rm -f "$CRONTAB_FILE" "$CRONTAB_WRITES"
  out=$(home_sync arm 2>&1); rc=$?
  expect_code 1 "$rc" "a plain arm whose first pass fails"
  assert_contains "$out" "the schedule stays armed and retries every minute" "a plain arm keeps its entry to retry"
  assert_contains "$(cat "$CRONTAB_FILE")" "# fm-board-sync home=$MAIN" "the entry stays installed"
  pass "fm-board-sync: a takeover whose first pass fails puts the host schedule back"
}

test_disarm_skips_a_deleted_host_script() {
  local out status
  make_homes
  seed_legacy_crontab
  home_sync arm --replace "$LEGACY" >/dev/null 2>&1 || fail "arm --replace"
  rm "$LEGACY"
  status=$(home_sync status 2>&1)
  assert_contains "$status" "$LEGACY_LINE (script gone; disarm skips it)" "status flags a replaced entry whose script is gone"
  out=$(home_sync disarm 2>&1) || fail "disarm"
  assert_equals "$OTHER_LINE" "$(cat "$CRONTAB_FILE")" "disarm never reinstates an entry whose script is gone"
  assert_contains "$out" "not restored, its script no longer exists: $LEGACY_LINE" "disarm says what it left out"
  pass "fm-board-sync: disarm leaves out a replaced entry whose host script was deleted"
}

test_arm_on_an_empty_crontab() {
  local rc
  make_homes
  rm -f "$CRONTAB_FILE"
  home_sync arm >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "arm with no crontab yet"
  assert_equals "1" "$(wc -l < "$CRONTAB_FILE" | tr -d ' ')" "a new crontab holds just the entry"
  assert_contains "$(cat "$CRONTAB_FILE")" "# fm-board-sync home=$MAIN" "the entry is tagged with the home"
  home_sync disarm >/dev/null 2>&1 || fail "disarm"
  assert_equals "" "$(cat "$CRONTAB_FILE")" "disarm leaves the crontab empty"
  pass "fm-board-sync: arm and disarm work on a user with no crontab yet"
}

test_arm_refusals() {
  local rc err
  make_homes
  seed_legacy_crontab
  err=$(mirror arm --replace "$LEGACY" 2>&1 >/dev/null); rc=$?
  expect_code 1 "$rc" "arm from another code root"
  assert_contains "$err" "run $MAIN/bin/fm-board-sync.py arm" "the refusal names the home's own copy"
  err=$(cd "$TMP_ROOT" && PATH="$FAKEBIN:$TMP_ROOT/odd%dir:$BASE_PATH" FM_HOME="$MAIN" "$HOME_SYNC" arm --replace "$LEGACY" 2>&1 >/dev/null); rc=$?
  expect_code 1 "$rc" "arm with a percent sign in PATH"
  assert_contains "$err" "cannot carry" "the refusal explains the crontab limit"
  mkdir -p "$TMP_ROOT/not-a-home/bin"
  cp "$SYNC" "$TMP_ROOT/not-a-home/bin/"
  err=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$TMP_ROOT/not-a-home" "$TMP_ROOT/not-a-home/bin/fm-board-sync.py" arm 2>&1 >/dev/null); rc=$?
  expect_code 1 "$rc" "arm outside a firstmate home"
  assert_contains "$err" "not a firstmate home" "the refusal names the missing home"
  assert_equals "$OTHER_LINE
$LEGACY_LINE" "$(cat "$CRONTAB_FILE")" "no refusal touches the crontab"
  assert_absent "$CRONTAB_WRITES" "no refusal writes the crontab"
  pass "fm-board-sync: arm refuses a foreign code root, an unschedulable PATH, and a non-home"
}

test_first_pass_builds_the_board
test_unchanged_pass_changes_nothing
test_stage_changes_release_and_return
test_unreadable_backlog_never_archives
test_daemon_start_and_unavailable
test_busy_lock_skips_quietly
test_only_card_lifecycle_commands_are_used
test_arm_refuses_to_run_beside_another_mirror
test_arm_takes_over_disarm_restores
test_arm_waits_for_the_running_host_pass
test_failed_first_pass_rolls_the_takeover_back
test_disarm_skips_a_deleted_host_script
test_arm_on_an_empty_crontab
test_arm_refusals
