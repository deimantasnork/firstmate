# Crew account selection verification

Audience: maintainer verification.

This record supports `bin/fm-account-choose.sh`, the account-selection contract owned by [`../configuration.md`](../configuration.md) ("Crew accounts") and forwarded by [`../../bin/fm-spawn.sh`](../../bin/fm-spawn.sh).
It records only the facts that must be re-established when `quota-axi`, a vendor store layout, or the selection rules change.
Task chronology and the captain's dispatch decisions stay in the private task report.

## Per-store quota evidence

Verified 2026-09-18 with `quota-axi` 0.1.46 on this host, whose fleet carries two Codex stores and two Claude stores.
`quota-axi --help` documents the read this feature depends on: `--profile-only` "requires explicit CLAUDE_CONFIG_DIR or CODEX_HOME plus exactly one matching provider. It reads only that credential file: no Keychain, Pi, CLI RPC, fallback, refresh, or cache."

```sh
CODEX_HOME=/home/herdr/.codex            quota-axi --provider codex  --profile-only --full
CODEX_HOME=/home/herdr/.codex-karolina   quota-axi --provider codex  --profile-only --full
CLAUDE_CONFIG_DIR=/home/herdr/.claude            quota-axi --provider claude --profile-only --full
CLAUDE_CONFIG_DIR=/home/herdr/.claude-karolina   quota-axi --provider claude --profile-only --full
```

| Store | Provider | Read result | Account reported |
| --- | --- | --- | --- |
| `~/.codex` (symlink to `~/.codex-lets-padel`) | codex | `all_models` 0 percent, `runway exhausted_now`, `spendPriority -0.7594` | the captain's own account |
| `~/.codex-karolina` | codex | `all_models` 92 percent, `runway through_reset`, `spendPriority 1.8454` | the colleague's account |
| `~/.claude` | claude | `quotaSemantics.status unknown`, attention `Claude quota unavailable (403)` | not reported |
| `~/.claude-karolina` | claude | `all_models` 72 percent, `runway through_reset` | the colleague's account, `identityStatus verified` |

Two properties of the read are load-bearing and were confirmed directly:

- The exit status is not the evidence. For the unreadable Claude store, `quota-axi --profile-only --full --json` printed a valid schema-5 snapshot whose `quotaSemantics.status` is `unknown` and **exited 1**. Discarding that snapshot on the exit status would turn disclosed uncertainty into a failed probe, so `bin/fm-account-choose.sh` treats a snapshot that passes `fm_quota_json_valid` as readable evidence whatever the exit status, and only a timeout or unparseable output as a probe failure.
- An unreadable store is not a dead account. The same `~/.claude` store answers 403 on an ordinary read as well, while `~/.claude-karolina` refreshes normally on use; the two share the fleet's normal usage path, which is why unmeasurable headroom stays selectable and is reported as `measured=no` rather than refusing the spawn.

The ambient Codex `spendPriority` is not a stable signal across stores in this fleet - it is a number on one account and is absent or `unknown` on another - so the selection ranks on `effectivePercentRemaining` and `runway` and treats a missing `spendPriority` as unmeasured. This is the reason `docs/configuration.md` "Crew accounts" states the disqualifying evidence instead of a priority ordering.

## Selection outcome on the live fleet

Run 2026-09-18 against this host's real stores, with the two-account configuration from `docs/examples/crew-accounts.json`:

```sh
bin/fm-account-choose.sh --vendor codex
bin/fm-account-choose.sh --vendor claude
bin/fm-account-choose.sh --vendor claude --pin karolina
```

- codex: `lets-padel` was skipped as `runway exhausted_now at all_models` and `karolina` was selected at `percent=92 runway=through_reset`, which is the overflowing behavior the captain asked for.
- claude: `lets-padel` was selected with `measured=no` (the 403 store), which is fill-first over disclosed uncertainty rather than a block. An operator who wants the other order for that vendor writes it in `order`.
- the `--pin karolina` run selected `karolina` at `percent=72 runway=through_reset` with `pin=yes`, ignoring no eligibility rule.

The deterministic half of this evidence is reproducible without the live stores:

```sh
bin/fm-test-run.sh tests/fm-account-choose.test.sh
bin/fm-test-run.sh tests/fm-spawn-dispatch-profile.test.sh
```

The first pins the selection order, the reserve, the pin and optional-pin paths, the unmeasurable and unparseable cases, the per-store probe, and the configuration refusals against a fake `quota-axi`; the second pins the store forwarding, the task-record fields, a secondmate home's pinned stores, and the refusal before any record is published.
