# Crew account selection verification

Audience: maintainer verification.

This record supports `bin/fm-account-choose.sh`, the account-selection contract owned by [`../configuration.md`](../configuration.md) ("Crew accounts") and forwarded by [`../../bin/fm-spawn.sh`](../../bin/fm-spawn.sh).
It records only the facts that must be re-established when `quota-axi`, a vendor store layout, or the selection rules change, stated so any two-store fleet can reproduce them.
Task chronology and the captain's dispatch decisions stay in the private task report.

## Per-store quota evidence

Verified with `quota-axi` 0.1.x on a host carrying two Codex stores and two Claude stores.
`quota-axi --help` documents the read this feature depends on: `--profile-only` "requires explicit CLAUDE_CONFIG_DIR or CODEX_HOME plus exactly one matching provider. It reads only that credential file: no Keychain, Pi, CLI RPC, fallback, refresh, or cache."

```sh
CODEX_HOME=<first-codex-store>   quota-axi --provider codex  --profile-only --full
CODEX_HOME=<second-codex-store>  quota-axi --provider codex  --profile-only --full
CLAUDE_CONFIG_DIR=<first-claude-store>   quota-axi --provider claude --profile-only --full
CLAUDE_CONFIG_DIR=<second-claude-store>  quota-axi --provider claude --profile-only --full
```

| Store | Provider | Read result | Account reported |
| --- | --- | --- | --- |
| first codex store | codex | a measured `all_models` bound with an `exhausted_now` runway and a numeric `spendPriority` | the first account's email |
| second codex store | codex | a measurable `all_models` bound with a `through_reset` runway and a numeric `spendPriority` | the second account's email |
| first claude store | claude | `quotaSemantics.status unknown` with no measurable window and an attention entry | not reported |
| second claude store | claude | a measurable `all_models` bound with a `through_reset` runway and a verified identity | the second account's email |

Two properties of the read are load-bearing and were confirmed directly:

- The exit status is not the evidence. For the store with no measurable window, `quota-axi --profile-only --full --json` printed a valid schema-5 snapshot whose `quotaSemantics.status` is `unknown` and **exited non-zero**. Discarding that snapshot on the exit status would turn disclosed uncertainty into a failed probe, so `bin/fm-account-choose.sh` treats a snapshot that passes `fm_quota_json_valid` as readable evidence whatever the exit status, and only a timeout or unparseable output as a probe failure.
- An unreadable store is not a dead account. A store whose credential file cannot be read can still refresh normally on a later real vendor call, and both stores share the fleet's normal usage path; that is why unmeasurable headroom stays selectable and is reported as `measured=no` rather than refusing the spawn.

The ambient Codex `spendPriority` is not a stable signal across stores - it is a number on one store and absent or `unknown` on another - so the selection ranks on `effectivePercentRemaining` and `runway` and treats a missing `spendPriority` as unmeasured. This is the reason `docs/configuration.md` "Crew accounts" states the disqualifying evidence instead of a priority ordering.

## Selection outcome on a two-store fleet

Run against two local stores whose configuration shape is the one in `docs/examples/crew-accounts.json`:

```sh
bin/fm-account-choose.sh --vendor codex
bin/fm-account-choose.sh --vendor claude
bin/fm-account-choose.sh --vendor claude --pin <second-account>
```

- codex: the first account was skipped as `runway exhausted_now at all_models` and the second was selected on its measured `through_reset` headroom, which is the overflowing behavior the captain asked for.
- claude: the first account was selected with `measured=no`, because its store reported no measurable window; that is fill-first over disclosed uncertainty rather than a block. An operator who wants the other order for that vendor reorders the accounts.
- the pin run selected the named account with `pin=yes`, ignoring no eligibility rule.

The deterministic half of this evidence is reproducible without any live stores:

```sh
bin/fm-test-run.sh tests/fm-account-choose.test.sh
bin/fm-test-run.sh tests/fm-spawn-dispatch-profile.test.sh
```

The first pins the declaration order, the reserve, the pin and optional-pin paths, the unmeasurable and unparseable cases, the per-store probe, and the configuration refusals against a fake `quota-axi`; the second pins the store forwarding, the task-record fields, a secondmate home's pinned stores, and the refusal before any record is published.
