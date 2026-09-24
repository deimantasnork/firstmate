# Fleet board mirror

The fleet board mirror keeps a [herdr-board](https://github.com/nelsonPires5/herdr-board) board named `Fleet` in step with the work a firstmate fleet is doing, so the captain can see every task and its live stage on one board.
herdr-board is only the viewer: firstmate owns the mirror as the tracked component `bin/fm-board-sync.py`, covered by `tests/fm-board-sync.test.sh`.
It is optional, and nothing runs until a home arms it.

## What the board shows

The mirror writes to one board named `Fleet` in the herdr-board project whose path is the main home, with four manual columns: Todo, In Progress, In Review, and Done.
It shows one card for each open backlog item in the main home and in every registered second mate home on this machine, plus one card for each worker that has a task record but no backlog item.
Each card's description begins with the line `fm-task: <home>/<id>`, where `<home>` is `main` or the second mate's registry key, and that line is the card's identity.
The rest of the description lists the project, the stage, the local copy, the PR, the first ticket link (a `Ticket:` line wins), and any blockers, when the task has them.

The card title is the backlog title, or the task id for a worker without a backlog item, behind a tag that carries the live stage:

| Column      | Title tag                  | Meaning |
| ----------- | -------------------------- | ------- |
| Todo        | `[planned]` or `[held]`    | Queued work, or work held for the captain |
| In Progress | `[working]` or `[blocked]` | Work in development; blocked also covers a pending decision, a failure, or a declared pause |
| In Review   | `[validating]`             | The no-mistakes validation is running |
| Done        | `[ready]`                  | Validation finished and the work is not yet released |

The stage comes from `bin/fm-crew-state.sh` for every task in flight or with a task record; other open items are planned, or held when the backlog marks them held.
When a task leaves the open backlog and has no task record, it is released and its card is archived; if the task comes back, its card is restored rather than recreated.
A home whose backlog cannot be read never has its cards archived.

## Why the columns are manual and the badge is untouched

herdr-board has no extension API, so the mirror works only through the `board` CLI, creating, moving, editing, archiving, and restoring cards.
The card status badge belongs to the herdr-board daemon, which sets it from its own agent runs, so the live stage lives in the title tag instead.
Every mirror column must stay manual: an automatic column would launch a new agent for each card that lands in it, duplicating work firstmate already runs.

## Requirements

- herdr-board's `board` CLI and daemon; the mirror uses `FM_BOARD_BIN` when set, otherwise `board` on `PATH`, otherwise `~/.local/bin/board`, and starts the daemon when it is not connected.
- `python3` and a user crontab.

## Arming the schedule

From the main home, in a shell whose `PATH` finds the same tools an interactive firstmate session uses, run:

```sh
bin/fm-board-sync.py arm
```

This installs one crontab entry for this home that runs a mirror pass every minute, then runs the first pass; if that pass fails, the entry stays and retries every minute.
The entry pins the home and that `PATH`, so a scheduled pass reads current state as accurately as an interactive one; run `arm` again to refresh the entry in place after the tools move.
The entry runs the home's own copy of the script, so updating firstmate updates the mirror.

## Taking over from a host mirror script

When a mirror script outside the repository already runs from cron, such as a host copy at `~/.local/bin/fm-board-sync.py`, take over its schedule with one command:

```sh
bin/fm-board-sync.py arm --replace ~/.local/bin/fm-board-sync.py
```

The host script's crontab entry is swapped for this home's entry in a single crontab write, so exactly one mirror is scheduled at every moment.
If a pass of the host script is still running, `arm` waits for it to finish before its own first pass, so two mirrors never write to the board at once.
If that first pass fails, `arm` rolls the takeover back so the host script keeps running the mirror, and reports why.
Existing cards keep their `fm-task:` identity, so the component picks them up where the host script left them.
Without `--replace`, `arm` refuses while another mirror script is scheduled.

Confirm the takeover with `bin/fm-board-sync.py status`: it shows `schedule: armed` and a `last pass` line that advances every minute and reads `ok`.
Keep the host script file until the mirror is confirmed running through the component, because it is what a revert restores.

## Reverting

```sh
bin/fm-board-sync.py disarm
```

This removes this home's entry and restores every entry `arm --replace` took over, in one crontab write.
An entry whose host script no longer exists is left out and reported rather than restored.

## Limits

- The mirror is one-way: moving or editing a mirrored card on the board changes nothing in firstmate, and the next pass puts the card back.
- The board refreshes at most once a minute.
- Second mate homes on another machine are not mirrored.
- Each pass keeps a short log of card changes and trouble in `state/.board-sync.log`; the script's header owns that file and the others it keeps under `state/`.
