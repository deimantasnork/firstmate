#!/usr/bin/env python3
# fm-board-sync.py - mirror the fleet's work items onto the herdr-board "Fleet" board.
#
# Owner: the main firstmate home. A pass reads firstmate state only - the main
# home's and every registered local second mate home's data/backlog.md and
# state/*.meta, plus bin/fm-crew-state.sh for each task in flight or with a
# task record - and writes only to herdr-board through its `board` CLI:
# create, move, edit, archive, and restore cards on manual columns, never the
# daemon-owned card status badge. docs/fleet-board-mirror.md owns the board
# contract: columns, stage tags, card identity, archive and restore, and why
# the columns stay manual.
#
# Subcommands:
#   run        One mirror pass; this is what the schedule runs. Quiet on
#              success, one log line when cards changed or on trouble. Exits 0
#              without doing anything when another pass holds the lock.
#   arm [--replace <script>]
#              Install this home's once-a-minute schedule in the user crontab
#              and run one pass immediately. The entry pins FM_HOME and the
#              invoking PATH, so the scheduled pass reads the same current
#              state an interactive fm-crew-state.sh call would. --replace takes
#              over the schedule from a host mirror script outside the repo:
#              every crontab entry running <script> is swapped for this entry
#              in the same crontab write, recorded for disarm, and any pass of
#              <script> still running is awaited before the first pass, so two
#              mirrors never write at once. If that first pass fails, the
#              takeover is rolled back and <script> is scheduled again, so the
#              mirror keeps running either way. Without --replace, arm refuses
#              while another fm-board-sync.py entry is active, and a failed
#              first pass leaves the entry armed to retry every minute.
#              Re-arming replaces this home's entry in place.
#   disarm     Remove this home's schedule entry and restore every entry arm
#              replaced whose script still exists, in one crontab write.
#   status     Print the schedule entry, any other mirror entries, the
#              recorded replaced entries, and the last pass result.
#
# arm schedules the home's own copy of this script, so it refuses when run
# from a different code root than FM_HOME; a fleet update to the home then
# updates the mirror too.
#
# Environment:
#   FM_HOME            the main home; unset means this script's code root.
#                      The board is the one named "Fleet" in herdr-board
#                      project <FM_HOME>.
#   FM_BOARD_BIN       the board CLI; unset means `board` on PATH, else
#                      ~/.local/bin/board.
#   FM_CREW_STATE_BIN  the current-state reader; unset means
#                      bin/fm-crew-state.sh next to this script.
#
# Files, all under $FM_HOME/state:
#   .board-sync.lock      serializes passes, arm, and disarm
#   .board-sync.log       trouble and change log, emptied past 128 KiB
#   .board-sync.last-run  "<epoch> ok <changes>" or "<epoch> failed <reason>"
#   .board-sync.replaced  "<script>\t<entry>" per crontab entry arm replaced
#
# docs/fleet-board-mirror.md is the operator guide.
from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SCRIPT = Path(os.path.abspath(__file__))
CODE_ROOT = SCRIPT.parent.parent
BOARD_NAME = "Fleet"
COLUMNS = ["Todo", "In Progress", "In Review", "Done"]
MARKER_RE = re.compile(r"^fm-task: (\S+)$", re.M)
ITEM_RE = re.compile(r"^- \[( |x)\] (\S+) - (.*)$")
CRON_SCHEDULE = "* * * * *"
CRON_TAG = "# fm-board-sync home="
LOCK_WAIT_SECS = 600
TAKEOVER_WAIT_SECS = 600
# After the swap, a pass cron forked just before it may not have exec'd its
# interpreter yet, and cron may not have reloaded the table; settle first.
TAKEOVER_SETTLE_SECS = 2


def fm_home() -> Path:
    raw = os.environ.get("FM_HOME") or str(CODE_ROOT)
    return Path(os.path.abspath(raw))


def state_dir() -> Path:
    return fm_home() / "state"


def log_path() -> Path:
    return state_dir() / ".board-sync.log"


def lock_path() -> Path:
    return state_dir() / ".board-sync.lock"


def last_run_path() -> Path:
    return state_dir() / ".board-sync.last-run"


def replaced_path() -> Path:
    return state_dir() / ".board-sync.replaced"


def board_bin() -> str:
    explicit = os.environ.get("FM_BOARD_BIN")
    if explicit:
        return explicit
    return shutil.which("board") or str(Path.home() / ".local/bin/board")


def crew_state_bin() -> str:
    return os.environ.get("FM_CREW_STATE_BIN") or str(SCRIPT.parent / "fm-crew-state.sh")


def log(msg: str) -> None:
    log_file = log_path()
    try:
        log_file.parent.mkdir(parents=True, exist_ok=True)
        if log_file.exists() and log_file.stat().st_size > 131072:
            log_file.write_text("")
        with log_file.open("a") as fh:
            fh.write(time.strftime("%Y-%m-%dT%H:%M:%SZ ", time.gmtime()) + msg + "\n")
    except OSError:
        pass


def record_last_run(result: str) -> None:
    try:
        last_run_path().write_text(f"{int(time.time())} {result}\n")
    except OSError:
        pass


def run(cmd, timeout=30, env=None):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)


def board_json(args, timeout=30):
    p = run([board_bin(), *args, "--json"], timeout=timeout)
    out = (p.stdout or "").strip()
    if p.returncode != 0 or not out:
        raise RuntimeError(f"board {' '.join(args)} rc={p.returncode}: {(p.stderr or '').strip()[:300]}")
    return json.loads(out)


# --- the mirror -------------------------------------------------------------


def homes():
    main = fm_home()
    found = [("main", main)]
    sm = main / "data" / "secondmates.md"
    if sm.exists():
        for line in sm.read_text(errors="replace").splitlines():
            m = re.match(r"^- (\S+) - .*\(home: ([^;)]+)", line)
            if m:
                key, path = m.group(1), Path(m.group(2).strip())
                if path.is_dir():
                    found.append((key, path))
    return found


def parse_backlog(path: Path):
    """Return (items, ok).  ok is False when the file cannot be trusted."""
    if not path.exists():
        return {}, False
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return {}, False
    items, section, cur = {}, None, None
    for raw in text.splitlines():
        if raw.startswith("## "):
            section, cur = raw[3:].strip(), None
            continue
        m = ITEM_RE.match(raw)
        if m:
            tid = m.group(2)
            cur = {"id": tid, "section": section or "", "done": m.group(1) == "x",
                   "raw": m.group(3), "body": []}
            items[tid] = cur
            continue
        if cur is not None and raw.startswith(("  ", "\t")):
            cur["body"].append(raw.strip())
        elif raw.strip():
            cur = None
    for it in items.values():
        raw = it["raw"]
        it["done"] = it["done"] or it["section"].lower().startswith("done")
        it["repo"] = (re.search(r"\(repo: ([^)]*)\)", raw) or [None, ""])[1]
        it["kind"] = (re.search(r"\(kind: ([^)]*)\)", raw) or [None, ""])[1]
        it["hold_kind"] = (re.search(r"\(hold-kind: ([^)]*)\)", raw) or [None, ""])[1]
        it["blocked_by"] = re.findall(r"blocked-by:\s*(\S+)", raw)
        title = re.split(r" \(repo:", raw)[0]
        while True:
            stripped = re.sub(
                r"(?:\s*\((?:kind|since|priority|hold|hold-kind|hold-until|blocked-by):?[^)]*\)"
                r"|\s*blocked-by:\s*\S+)\s*$", "", title)
            if stripped == title:
                break
            title = stripped
        it["title"] = title.strip()
        ticket = ""
        for line in it["body"]:
            if line.lower().startswith("ticket:"):
                u = re.search(r"https?://\S+", line)
                if u:
                    ticket = u.group(0)
                    break
        if not ticket:
            for line in it["body"]:
                u = re.search(r"https?://\S+", line)
                if u:
                    ticket = u.group(0)
                    break
        it["ticket"] = ticket
    return items, (len(items) > 0 or "## " in text)


def parse_meta(path: Path):
    meta = {}
    try:
        for line in path.read_text(errors="replace").splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                meta[k.strip()] = v.strip()
    except OSError:
        pass
    return meta


def crew_state(home: Path, tid: str):
    env = dict(os.environ, FM_HOME=str(home))
    try:
        p = run([crew_state_bin(), tid], timeout=20, env=env)
    except (subprocess.TimeoutExpired, OSError):
        return ""
    lines = [ln for ln in (p.stdout or "").splitlines() if ln.strip()]
    return lines[0].strip() if lines else ""


def phase_of(state_line: str, in_flight: bool):
    """Return (column, note)."""
    low = (state_line or "").lower()
    if low.startswith("state: done"):
        return "Done", "validated, awaiting release"
    if "validating" in low:
        when = "running"
        m = re.search(r"validating \(([^)]*)\)", low)
        if m:
            when = m.group(1)
        return "In Review", f"in validation ({when})"
    if low.startswith("state: working"):
        return "In Progress", "in development"
    for word in ("blocked", "needs-decision", "failed", "paused"):
        if word in low:
            return "In Progress", f"in development - {word}"
    if in_flight:
        return "In Progress", "in development"
    return None, ""


def stage_tag(col, note, held=False):
    """Compact, visible state tag prefixed to the mirror card title."""
    if col == "Todo":
        return "held" if held else "planned"
    if col == "In Review":
        return "validating"
    if col == "Done":
        return "ready"
    low = (note or "").lower()
    for word in ("blocked", "needs-decision", "failed", "paused"):
        if word in low:
            return "blocked"
    return "working"


def desired_cards():
    wanted, homes_ok = {}, {}
    for key, home in homes():
        items, ok = parse_backlog(home / "data" / "backlog.md")
        homes_ok[key] = ok
        metas = {}
        for mf in sorted((home / "state").glob("*.meta")):
            meta = parse_meta(mf)
            if meta.get("kind") == "secondmate":
                continue
            metas[mf.stem] = meta
        for tid, it in items.items():
            if it["done"]:
                continue
            in_flight = it["section"].lower().startswith("in flight")
            meta = metas.pop(tid, {})
            line = crew_state(home, tid) if (in_flight or meta) else ""
            col, note = phase_of(line, in_flight)
            if not col:
                if it["hold_kind"]:
                    col, note = "Todo", "held for the captain"
                else:
                    col, note = "Todo", "planned"
            desc = [f"fm-task: {key}/{tid}"]
            if it["repo"] and it["repo"] != "-":
                desc.append(f"Project: {it['repo']}")
            desc.append(f"Stage: {note}")
            if meta.get("worktree"):
                desc.append(f"Worktree: {meta['worktree']}")
            if meta.get("pr"):
                desc.append(f"PR: {meta['pr']}")
            if it["ticket"]:
                desc.append(f"Ticket: {it['ticket']}")
            if it["blocked_by"]:
                desc.append("Blocked by: " + ", ".join(it["blocked_by"]))
            tag = stage_tag(col, note, bool(it["hold_kind"]))
            wanted[f"{key}/{tid}"] = {"title": f"[{tag}] {it['title'] or tid}", "column": col,
                                      "desc": "\n".join(desc)}
        for tid, meta in metas.items():
            line = crew_state(home, tid)
            col, note = phase_of(line, True)
            if not col:
                col, note = "In Progress", "in development"
            desc = [f"fm-task: {key}/{tid}", f"Stage: {note}"]
            if meta.get("project"):
                desc.append(f"Project: {meta['project']}")
            if meta.get("worktree"):
                desc.append(f"Worktree: {meta['worktree']}")
            if meta.get("pr"):
                desc.append(f"PR: {meta['pr']}")
            tag = stage_tag(col, note)
            wanted[f"{key}/{tid}"] = {"title": f"[{tag}] {tid}", "column": col, "desc": "\n".join(desc)}
    return wanted, homes_ok


def ensure_daemon():
    try:
        st = board_json(["daemon", "status"], timeout=15)
        if st.get("herdr_connected"):
            return True
    except Exception:
        pass
    try:
        subprocess.Popen([board_bin(), "daemon", "start"], stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        return False
    for _ in range(6):
        time.sleep(1)
        try:
            st = board_json(["daemon", "status"], timeout=10)
            if st.get("herdr_connected"):
                return True
        except Exception:
            pass
    return False


def ensure_board():
    project = str(fm_home())
    data = board_json(["board", "list", "--project", project])
    boards = data if isinstance(data, list) else data.get("boards", [])
    board = next((b for b in boards if b.get("name") == BOARD_NAME), None)
    if not board:
        created = board_json(["board", "create", BOARD_NAME, "--project", project])
        board = created.get("board", created) if isinstance(created, dict) else created
    bid = str(board["id"])
    cols = board_json(["column", "list", "--board", bid])
    byname = {c["name"]: c for c in (cols if isinstance(cols, list) else cols.get("columns", []))}
    for pos, name in enumerate(COLUMNS):
        if name not in byname:
            created = board_json(["column", "create", "--name", name, "--trigger", "manual",
                                  "--position", str(pos), "--board", bid])
            byname[name] = created.get("column", created) if isinstance(created, dict) else created
    return bid, byname


def sync():
    bid, _cols = ensure_board()
    cards = board_json(["card", "list", "--visibility", "all", "--board", bid])
    cards = cards if isinstance(cards, list) else cards.get("cards", [])
    existing = {}
    for c in cards:
        m = MARKER_RE.search(c.get("description") or "")
        if m:
            existing[m.group(1)] = c
    wanted, homes_ok = desired_cards()
    changed = 0
    for key, want in wanted.items():
        card = existing.get(key)
        try:
            if not card:
                board_json(["card", "create", "--title", want["title"], "-d", want["desc"],
                            "--column", want["column"], "--board", bid])
                changed += 1
                continue
            if card.get("archived_at"):
                board_json(["card", "restore", str(card["id"]), "--board", bid])
                card = dict(card, archived_at=None)
                changed += 1
            if _cols[want["column"]]["id"] != card.get("column_id"):
                board_json(["card", "move", str(card["id"]), want["column"], "--board", bid])
                changed += 1
            if (card.get("title") != want["title"]) or ((card.get("description") or "") != want["desc"]):
                board_json(["card", "edit", str(card["id"]), "--title", want["title"],
                            "-d", want["desc"], "--board", bid])
                changed += 1
        except Exception as exc:  # keep the rest of the sync going
            log(f"card {key}: {exc}")
    for key, card in existing.items():
        if key in wanted or card.get("archived_at"):
            continue
        home_key = key.split("/", 1)[0]
        if not homes_ok.get(home_key, False):
            log(f"archive skipped for {key}: {home_key} backlog unreadable")
            continue
        try:
            board_json(["card", "archive", str(card["id"]), "--board", bid])
            changed += 1
        except Exception as exc:
            log(f"archive {key}: {exc}")
    return changed


def mirror_pass():
    """One pass with the lock already held.  Returns 0 or 1."""
    try:
        if not ensure_daemon():
            log("board daemon unavailable")
            record_last_run("failed board daemon unavailable")
            return 1
        changed = sync()
        if changed:
            log(f"synced {changed} card change(s)")
        record_last_run(f"ok {changed}")
        return 0
    except Exception as exc:
        log(f"sync failed: {exc}")
        record_last_run(f"failed sync failed: {exc}")
        return 1


# --- locking ----------------------------------------------------------------


def open_lock():
    path = lock_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    return open(path, "w")


def acquire_lock_waiting(what: str):
    """Block (bounded) until no pass holds the lock, for arm and disarm."""
    fh = open_lock()
    deadline = time.time() + LOCK_WAIT_SECS
    announced = False
    while True:
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fh
        except OSError:
            if time.time() >= deadline:
                fh.close()
                raise SystemExit(f"fm-board-sync: {what}: a mirror pass still holds "
                                 f"{lock_path()} after {LOCK_WAIT_SECS}s; nothing changed")
            if not announced:
                print(f"fm-board-sync: {what}: waiting for the mirror pass in progress")
                announced = True
            time.sleep(1)


def cmd_run(_args):
    try:
        lock_fh = open_lock()
        fcntl.flock(lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0
    return mirror_pass()


# --- schedule ---------------------------------------------------------------


def home_tag() -> str:
    return CRON_TAG + str(fm_home())


def is_active(line: str) -> bool:
    s = line.strip()
    return bool(s) and not s.startswith("#")


def is_own_entry(line: str) -> bool:
    return is_active(line) and line.rstrip().endswith(home_tag())


def is_any_component_entry(line: str) -> bool:
    return is_active(line) and CRON_TAG in line


def tokens(line: str):
    return [t.strip("'\"") for t in line.split()]


def references(line: str, script: str) -> bool:
    return is_active(line) and script in tokens(line)


def is_foreign_mirror(line: str) -> bool:
    return (is_active(line) and not is_any_component_entry(line)
            and any(os.path.basename(t) == "fm-board-sync.py" for t in tokens(line)))


def crontab(*args):
    try:
        return run(["crontab", *args])
    except FileNotFoundError:
        raise SystemExit("fm-board-sync: the crontab command is not installed; nothing changed")


def read_crontab():
    p = crontab("-l")
    if p.returncode != 0:
        if "no crontab" in (p.stderr or "").lower():
            return []
        raise SystemExit(f"fm-board-sync: crontab -l failed: {(p.stderr or '').strip()}; nothing changed")
    return p.stdout.splitlines()


def write_crontab(lines):
    body = "".join(line + "\n" for line in lines)
    with tempfile.NamedTemporaryFile("w", prefix="fm-board-sync-cron.", delete=False) as fh:
        fh.write(body)
        tmp = fh.name
    try:
        p = crontab(tmp)
    finally:
        os.unlink(tmp)
    if p.returncode != 0:
        raise SystemExit(f"fm-board-sync: installing the crontab failed: {(p.stderr or '').strip()}")


def schedule_line() -> str:
    home = str(fm_home())
    path = ":".join(dict.fromkeys(d for d in os.environ.get("PATH", "").split(":") if d))
    line = (f"{CRON_SCHEDULE} FM_HOME={shlex.quote(home)} PATH={shlex.quote(path)} "
            f"{shlex.quote(str(SCRIPT))} run >/dev/null 2>&1 {home_tag()}")
    if "%" in line or "\n" in line:
        raise SystemExit("fm-board-sync: arm: FM_HOME, PATH, or the script path contains '%' or a "
                         "newline, which a crontab entry cannot carry; nothing changed")
    return line


def read_replaced():
    """[(script, entry)] recorded by arm, oldest first."""
    try:
        rows = replaced_path().read_text().splitlines()
    except OSError:
        return []
    return [tuple(row.split("\t", 1)) for row in rows if "\t" in row]


def write_replaced(record):
    if record:
        replaced_path().write_text("".join(f"{script}\t{ln}\n" for script, ln in record))
    else:
        try:
            replaced_path().unlink()
        except FileNotFoundError:
            pass


def process_runs(script: str):
    """Pids of processes currently executing <script> (directly or via python)."""
    p = run(["ps", "-A", "-ww", "-o", "pid=,args="])
    pids = []
    for row in (p.stdout or "").splitlines():
        parts = row.split()
        if len(parts) < 2 or not parts[0].isdigit() or int(parts[0]) == os.getpid():
            continue
        argv = parts[1:]
        if argv[0] == script or (os.path.basename(argv[0]).lower().startswith("python")
                                 and len(argv) > 1 and argv[1] == script):
            pids.append(int(parts[0]))
    return pids


def await_replaced_runs(script: str):
    deadline = time.time() + TAKEOVER_WAIT_SECS
    announced = False
    while process_runs(script):
        if time.time() >= deadline:
            print(f"fm-board-sync: arm: {script} is still running after {TAKEOVER_WAIT_SECS}s; "
                  "continuing without waiting for it")
            return
        if not announced:
            print(f"fm-board-sync: arm: waiting for the running pass of {script} to finish")
            announced = True
        time.sleep(1)


def cmd_arm(args):
    home = fm_home()
    if not (home / "state").is_dir():
        raise SystemExit(f"fm-board-sync: arm: {home} has no state/ directory, so it is not a "
                         "firstmate home; set FM_HOME; nothing changed")
    if os.path.realpath(CODE_ROOT) != os.path.realpath(home):
        raise SystemExit(f"fm-board-sync: arm: this script belongs to {CODE_ROOT}, not FM_HOME {home}; "
                         f"run {home}/bin/fm-board-sync.py arm so the schedule uses the home's own copy; "
                         "nothing changed")
    replace = os.path.abspath(args.replace) if args.replace else None
    line = schedule_line()
    lock_fh = acquire_lock_waiting("arm")
    current = read_crontab()
    foreign = [ln for ln in current if is_foreign_mirror(ln) and not (replace and references(ln, replace))]
    if foreign:
        print("fm-board-sync: arm: another fleet mirror is scheduled in the crontab:", file=sys.stderr)
        for ln in foreign:
            print(f"  {ln}", file=sys.stderr)
        print("Rerun with --replace <that script's path> to take over its schedule; nothing changed.",
              file=sys.stderr)
        return 1
    replaced = [ln for ln in current if replace and references(ln, replace)]
    new, placed = [], False
    for ln in current:
        if is_own_entry(ln) or ln in replaced:
            if not placed:
                new.append(line)
                placed = True
            continue
        new.append(ln)
    if not placed:
        new.append(line)
    prior_record = read_replaced()
    if replaced:
        write_replaced(prior_record + [(replace, ln) for ln in replaced if (replace, ln) not in prior_record])
    write_crontab(new)
    print(f"fm-board-sync: armed: {line}")
    for ln in replaced:
        print(f"fm-board-sync: replaced (disarm restores it): {ln}")
    if replace and not replaced:
        print(f"fm-board-sync: no crontab entry ran {replace}; nothing was replaced")
    if replaced:
        time.sleep(TAKEOVER_SETTLE_SECS)
    if replace:
        await_replaced_runs(replace)
    rc = mirror_pass()
    if rc == 0:
        print("fm-board-sync: first pass ok")
    elif replaced:
        # The takeover only sticks once this component has proven a pass;
        # otherwise the replaced script goes back to running the mirror.
        after = read_crontab()
        if after == new:
            back = current
        else:
            back = [ln for ln in after if not is_own_entry(ln)]
            back += [ln for ln in replaced if ln not in back]
        write_crontab(back)
        write_replaced(prior_record)
        print(f"fm-board-sync: first pass failed: {last_run_detail()}; the takeover is rolled back and "
              f"{replace} is scheduled again (log: {log_path()})")
    else:
        print(f"fm-board-sync: first pass failed: {last_run_detail()}; the schedule stays armed "
              f"and retries every minute (disarm reverts it; log: {log_path()})")
    lock_fh.close()
    return rc


def cmd_disarm(_args):
    lock_fh = acquire_lock_waiting("disarm")
    current = read_crontab()
    new = [ln for ln in current if not is_own_entry(ln)]
    removed = len(current) - len(new)
    restored, dropped = [], []
    for script, ln in read_replaced():
        if ln in new or ln in restored:
            continue
        (restored if os.path.exists(script) else dropped).append(ln)
    new.extend(restored)
    if removed or restored:
        write_crontab(new)
    write_replaced([])
    lock_fh.close()
    print(f"fm-board-sync: disarmed: removed {removed} schedule entr{'y' if removed == 1 else 'ies'} "
          f"for {fm_home()}")
    for ln in restored:
        print(f"fm-board-sync: restored: {ln}")
    for ln in dropped:
        print(f"fm-board-sync: not restored, its script no longer exists: {ln}")
    return 0


def last_run_detail() -> str:
    try:
        raw = last_run_path().read_text().strip()
    except OSError:
        return "no pass recorded"
    stamp, _, result = raw.partition(" ")
    if not stamp.isdigit():
        return raw
    when = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(stamp)))
    return f"{when} {result}"


def cmd_status(_args):
    current = read_crontab()
    own = [ln for ln in current if is_own_entry(ln)]
    others = [ln for ln in current if is_foreign_mirror(ln)]
    print(f"home: {fm_home()}")
    print(f"schedule: {'armed' if own else 'not armed'}")
    for ln in own:
        print(f"  {ln}")
    if others:
        print("other fleet mirror entries:")
        for ln in others:
            print(f"  {ln}")
    replaced = read_replaced()
    if replaced:
        print("replaced entries disarm restores:")
        for script, ln in replaced:
            gone = "" if os.path.exists(script) else " (script gone; disarm skips it)"
            print(f"  {ln}{gone}")
    print(f"last pass: {last_run_detail()}")
    print(f"log: {log_path()}")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="fm-board-sync.py",
        description="Mirror the fleet's work items onto the herdr-board Fleet board.")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("run", help="one mirror pass (what the schedule runs)").set_defaults(func=cmd_run)
    arm = sub.add_parser("arm", help="install the once-a-minute schedule and run one pass")
    arm.add_argument("--replace", metavar="SCRIPT",
                     help="take over the schedule of a mirror script outside the repo")
    arm.set_defaults(func=cmd_arm)
    sub.add_parser("disarm", help="remove the schedule and restore what arm replaced").set_defaults(func=cmd_disarm)
    sub.add_parser("status", help="print the schedule and the last pass").set_defaults(func=cmd_status)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
