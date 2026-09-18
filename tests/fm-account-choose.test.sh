#!/usr/bin/env bash
# Behavior tests for bin/fm-account-choose.sh, the credential-account selector
# behind config/crew-accounts.json.
#
# The suite drives the real script with a fake `quota-axi` on PATH and real
# throwaway store directories. Each store holds its own fixture snapshot
# (`.fm-quota.json`) and optionally its own exit status (`.fm-exit`), so a case
# pins exactly what the selector reads for that account, and the fake logs every
# invocation so a case can prove which store and which flags were used.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHOOSER="$ROOT/bin/fm-account-choose.sh"
TMP_ROOT=$(fm_test_tmproot fm-account-choose)

FIXTURE=
FAKEBIN=
QUOTA_LOG=
CONFIG=
STORE_A=
STORE_B=

# --- fixtures ---------------------------------------------------------------

make_fake_quota() {
  local fakebin=$1
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
provider=
case "${1:-}" in
  --provider) provider=${2:-} ;;
  *) printf 'fake quota-axi: unexpected argv: %s\n' "$*" >&2; exit 2 ;;
esac
if [ "${FM_FAKE_QUOTA_LOG:-}" ]; then
  printf 'argv=%s CODEX_HOME=%s CLAUDE_CONFIG_DIR=%s\n' \
    "$*" "${CODEX_HOME:-}" "${CLAUDE_CONFIG_DIR:-}" >> "$FM_FAKE_QUOTA_LOG"
fi
case "$provider" in
  codex) store=${CODEX_HOME:-} ;;
  claude) store=${CLAUDE_CONFIG_DIR:-} ;;
  *) printf 'fake quota-axi: unexpected provider: %s\n' "${provider:-none}" >&2; exit 2 ;;
esac
if [ -z "$store" ]; then
  printf 'fake quota-axi: no %s store selected\n' "$provider" >&2
  exit 2
fi
[ -f "$store/.fm-quota.json" ] || { printf 'fake quota-axi: no fixture at %s\n' "$store" >&2; exit 2; }
cat "$store/.fm-quota.json"
if [ -f "$store/.fm-exit" ]; then
  exit "$(cat "$store/.fm-exit")"
fi
exit 0
SH
  chmod +x "$fakebin/quota-axi"
}

# quota_json <provider> <percent> <runway> <email> <scope>
quota_json() {
  cat <<JSON
{
  "generatedAt": "2026-09-18T00:00:00.000Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "$1",
      "source": "oauth",
      "account": { "email": "$4" },
      "state": { "status": "fresh", "stale": false },
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "$5",
            "status": "known",
            "effectivePercentRemaining": $2,
            "runway": { "status": "$3" }
          }
        ]
      }
    }
  ]
}
JSON
}

# unknown_json <provider> - the shape quota-axi prints for a store whose quota
# cannot be read at all (an unreadable or rejected credential).
unknown_json() {
  cat <<JSON
{
  "generatedAt": "2026-09-18T00:00:00.000Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "$1",
      "state": { "status": "error", "stale": false, "error": "quota unavailable" },
      "quotaSemantics": {
        "status": "unknown",
        "description": "no windows",
        "effectiveAvailability": []
      }
    }
  ]
}
JSON
}

write_store() {  # <dir> <json> [exit-status]
  local dir=$1 json=$2 exit_code=${3:-0}
  mkdir -p "$dir"
  printf '%s\n' "$json" > "$dir/.fm-quota.json"
  printf '%s\n' "$exit_code" > "$dir/.fm-exit"
}

# The default fleet shape: the captain's own account first, the colleague's
# second with a 20 percent Claude reserve.
write_default_config() {
  cat > "$CONFIG" <<JSON
{
  "accounts": [
    {
      "name": "primary",
      "codex_home": "$STORE_A",
      "claude_config_dir": "$STORE_A"
    },
    {
      "name": "secondary",
      "codex_home": "$STORE_B",
      "claude_config_dir": "$STORE_B",
      "reserve": { "claude": 20 }
    }
  ]
}
JSON
}

choose() {  # <args...>
  FM_CONFIG_OVERRIDE="$FIXTURE/config" FM_FAKE_QUOTA_LOG="$QUOTA_LOG" \
    HOME="$FIXTURE/home" PATH="$FAKEBIN:$PATH" "$CHOOSER" "$@" 2>&1
}

setup_case() {
  FIXTURE="$TMP_ROOT/$1"
  mkdir -p "$FIXTURE/config" "$FIXTURE/home" "$FIXTURE/fake"
  FAKEBIN="$FIXTURE/fake"
  QUOTA_LOG="$FIXTURE/quota.log"
  CONFIG="$FIXTURE/config/crew-accounts.json"
  STORE_A="$FIXTURE/store-primary"
  STORE_B="$FIXTURE/store-secondary"
  : > "$QUOTA_LOG"
  make_fake_quota "$FAKEBIN"
}

field() {  # <output> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | tail -1
}

# --- cases ------------------------------------------------------------------

test_fill_first_over_declaration_order() {
  local out status
  setup_case fill-first
  write_store "$STORE_A" "$(quota_json codex 100 through_reset primary@example.com all_models)"
  write_store "$STORE_B" "$(quota_json codex 87 through_reset secondary@example.com all_models)"
  write_default_config

  out=$(choose --vendor codex)
  status=$?
  expect_code 0 "$status" "a healthy first account should select"$'\n'"$out"
  [ "$(field "$out" selected)" = primary ] || fail "fill-first did not keep the first account: $out"
  [ "$(field "$out" store)" = "$STORE_A" ] || fail "fill-first reported the wrong store: $out"
  pass "fill-first keeps the first account while it has measured headroom"
}

test_exhausted_first_account_overflows_to_the_second() {
  local out status
  setup_case exhausted-overflow
  write_store "$STORE_A" "$(quota_json codex 0 exhausted_now primary@example.com all_models)"
  write_store "$STORE_B" "$(quota_json codex 87 through_reset secondary@example.com all_models)"
  write_default_config

  out=$(choose --vendor codex)
  status=$?
  expect_code 0 "$status" "an exhausted first account should overflow to the second"$'\n'"$out"
  [ "$(field "$out" selected)" = secondary ] || fail "exhausted account was not skipped: $out"
  assert_contains "$out" "candidate=primary" "skipped candidate was not reported"
  assert_contains "$out" "skipped:runway exhausted_now at all_models" "skip reason was not reported: $out"
  assert_contains "$out" "percent=87" "the selected account's measured percent was not reported: $out"
  pass "an exhausted first account overflows to the second on measured evidence"
}

test_zero_percent_first_account_overflows() {
  local out status
  setup_case zero-percent
  write_store "$STORE_A" "$(quota_json codex 0 unknown primary@example.com all_models)"
  write_store "$STORE_B" "$(quota_json codex 40 through_reset secondary@example.com all_models)"
  write_default_config

  out=$(choose --vendor codex)
  status=$?
  expect_code 0 "$status" "a 0 percent account should overflow"$'\n'"$out"
  [ "$(field "$out" selected)" = secondary ] || fail "0 percent account was not skipped: $out"
  assert_contains "$out" "skipped:0% remaining" "zero-percent skip reason was not reported: $out"
  pass "a measured 0 percent account overflows even without an exhausted_now runway"
}

test_reserve_floor_holds_the_colleagues_claude_account() {
  local out status
  setup_case reserve-floor
  write_store "$STORE_A" "$(quota_json claude 0 exhausted_now primary@example.com all_models)"
  write_store "$STORE_B" "$(quota_json claude 19 through_reset secondary@example.com all_models)"
  write_default_config

  out=$(choose --vendor claude)
  status=$?
  expect_code 3 "$status" "a below-reserve account must not be selected"$'\n'"$out"
  assert_contains "$out" "skipped:19% remaining is at or below the 20% reserve" "reserve skip reason was not reported: $out"
  assert_not_contains "$out" "selected=secondary" "a below-reserve account was selected"
  pass "the configured reserve is enforced before the colleague's account is used"
}

test_reserve_floor_holds_at_the_boundary_and_a_pin_still_selects() {
  local out status store_env
  setup_case reserve-boundary
  write_store "$STORE_A" "$(quota_json claude 0 exhausted_now primary@example.com all_models)"
  write_store "$STORE_B" "$(quota_json claude 20 through_reset secondary@example.com all_models)"
  write_default_config

  out=$(choose --vendor claude)
  status=$?
  expect_code 3 "$status" "an account exactly at its reserve must not be auto-selected"$'\n'"$out"
  assert_contains "$out" "skipped:20% remaining is at or below the 20% reserve" "the reserve floor itself was not held: $out"
  assert_not_contains "$out" "selected=secondary" "an account exactly at the reserve was auto-selected"

  out=$(choose --vendor claude --pin secondary)
  status=$?
  expect_code 0 "$status" "an explicit pin must still select the account at its reserve"$'\n'"$out"
  [ "$(field "$out" selected)" = secondary ] || fail "the pin did not select the boundary account: $out"
  store_env=$(field "$out" store_env)
  [ "$store_env" = CLAUDE_CONFIG_DIR ] || fail "wrong store variable for claude: $out"
  pass "the reserve floor itself is not auto-selectable, and an explicit pin still selects it"
}

test_fractional_percent_and_reserve_still_hold_the_floor() {
  local out status
  setup_case reserve-fraction
  write_store "$STORE_A" "$(quota_json claude 0 exhausted_now primary@example.com all_models)"
  write_store "$STORE_B" "$(quota_json claude 19.5 through_reset secondary@example.com all_models)"
  write_default_config

  out=$(choose --vendor claude)
  status=$?
  expect_code 3 "$status" "a measured percent below an integer reserve must be held"$'\n'"$out"
  assert_contains "$out" "skipped:19.5% remaining is at or below the 20% reserve" "the fractional percent bypassed the reserve: $out"
  assert_not_contains "$out" "selected=secondary" "an account below the reserve was selected"

  write_store "$STORE_B" "$(quota_json claude 25.4 through_reset secondary@example.com all_models)"
  cat > "$CONFIG" <<JSON
{
  "accounts": [
    { "name": "primary", "claude_config_dir": "$STORE_A" },
    { "name": "secondary", "claude_config_dir": "$STORE_B", "reserve": { "claude": 25.5 } }
  ]
}
JSON
  out=$(choose --vendor claude)
  status=$?
  expect_code 3 "$status" "a fractional reserve must still be enforced"$'\n'"$out"
  assert_contains "$out" "skipped:25.4% remaining is at or below the 25.5% reserve" "the fractional reserve was ignored: $out"
  assert_not_contains "$out" "selected=secondary" "an account below a fractional reserve was selected"
  pass "a fractional measured percent and a fractional reserve both hold the floor"
}

test_account_without_a_vendor_store_is_not_a_candidate() {
  local out status
  setup_case vendor-store-missing
  write_store "$STORE_B" "$(quota_json codex 87 through_reset secondary@example.com all_models)"
  mkdir -p "$FIXTURE/store-claude-only"
  cat > "$CONFIG" <<JSON
{
  "accounts": [
    { "name": "claude-only", "claude_config_dir": "$FIXTURE/store-claude-only" },
    { "name": "secondary", "codex_home": "$STORE_B" }
  ]
}
JSON

  out=$(choose --vendor codex)
  status=$?
  expect_code 0 "$status" "an account with no store for the vendor must not be fatal"$'\n'"$out"
  [ "$(field "$out" selected)" = secondary ] || fail "the usable account was not selected: $out"
  assert_not_contains "$out" "candidate=claude-only" "an account with no store for the vendor was a candidate: $out"
  pass "an account with no store for the vendor is skipped, not fatal"
}

test_top_level_reserve_is_refused() {
  local out status
  setup_case top-level-reserve
  write_store "$STORE_A" "$(quota_json claude 90 through_reset primary@example.com all_models)"
  write_store "$STORE_B" "$(quota_json claude 90 through_reset secondary@example.com all_models)"
  cat > "$CONFIG" <<JSON
{
  "accounts": [
    { "name": "primary", "claude_config_dir": "$STORE_A" },
    { "name": "secondary", "claude_config_dir": "$STORE_B" }
  ],
  "reserve": { "claude": 20 }
}
JSON

  out=$(choose --vendor claude)
  status=$?
  expect_code 1 "$status" "a top-level reserve that would enforce nothing must be refused"$'\n'"$out"
  assert_contains "$out" "reserve must be set per account (accounts[].reserve), not at the top level" \
    "the refusal did not point at the per-account form: $out"

  out=$(choose --validate)
  status=$?
  expect_code 1 "$status" "--validate must refuse a top-level reserve"$'\n'"$out"
  assert_contains "$out" "accounts[].reserve" "--validate did not report the top-level reserve: $out"
  pass "a top-level reserve is refused with a pointer to the per-account form"
}

test_top_level_scalar_is_refused() {
  local out status
  setup_case top-level-scalar
  printf '%s\n' '"hello"' > "$CONFIG"

  out=$(choose --validate)
  status=$?
  expect_code 1 "$status" "--validate must refuse a top-level scalar"$'\n'"$out"
  assert_contains "$out" "top-level value must be an object" "--validate accepted a top-level scalar: $out"

  out=$(choose --vendor codex)
  status=$?
  expect_code 1 "$status" "selection must refuse a top-level scalar"$'\n'"$out"
  assert_contains "$out" "top-level value must be an object" "selection did not name the top-level type: $out"
  assert_not_contains "$out" "could not be read" "selection fell through to a generic read error: $out"
  pass "a top-level JSON scalar is refused as an invalid account file"
}

test_reserve_does_not_apply_to_codex() {
  local out status
  setup_case reserve-codex
  write_store "$STORE_A" "$(quota_json codex 0 exhausted_now primary@example.com all_models)"
  write_store "$STORE_B" "$(quota_json codex 19 through_reset secondary@example.com all_models)"
  write_default_config

  out=$(choose --vendor codex)
  status=$?
  expect_code 0 "$status" "codex has no reserve, so 19 percent is selectable"$'\n'"$out"
  [ "$(field "$out" selected)" = secondary ] || fail "codex account below the claude reserve was skipped: $out"
  pass "the reserve applies only to the vendor it names"
}

test_unmeasurable_first_account_is_selected_as_disclosed_uncertainty() {
  local out status
  setup_case unmeasurable-first
  write_store "$STORE_A" "$(unknown_json claude)"
  write_store "$STORE_B" "$(quota_json claude 64 through_reset secondary@example.com all_models)"
  write_default_config

  out=$(choose --vendor claude)
  status=$?
  expect_code 0 "$status" "unmeasurable headroom must not block the first account"$'\n'"$out"
  [ "$(field "$out" selected)" = primary ] || fail "fill-first did not keep the unmeasurable first account: $out"
  [ "$(field "$out" measured)" = no ] || fail "unmeasurable headroom was not disclosed: $out"
  [ "$(field "$out" identity)" = unknown ] || fail "an unknown identity should be reported as unknown: $out"
  assert_contains "$out" "selected:headroom unmeasurable (quota-axi reports no measurable window)" \
    "unmeasurable selection was not explained: $out"
  pass "an unmeasurable first account stays selectable and is disclosed as uncertainty"
}

test_nonzero_quota_exit_still_reads_its_valid_snapshot() {
  local out status
  setup_case nonzero-exit
  # quota-axi 0.1.46 exits 1 for an error-state provider while still printing a
  # valid schema-5 snapshot; that snapshot is the evidence, not the exit status.
  write_store "$STORE_A" "$(unknown_json claude)" 1
  write_store "$STORE_B" "$(quota_json claude 64 through_reset secondary@example.com all_models)"
  write_default_config

  out=$(choose --vendor claude)
  status=$?
  expect_code 0 "$status" "a valid snapshot on a non-zero exit should still be evidence"$'\n'"$out"
  [ "$(field "$out" selected)" = primary ] || fail "the readable-but-error snapshot was treated as a dead account: $out"
  assert_contains "$out" "selected:headroom unmeasurable (quota-axi reports no measurable window)" \
    "the error-state snapshot was not reported as unmeasurable: $out"
  pass "a valid snapshot on a non-zero quota-axi exit is evidence, not a failure"
}

test_unreadable_snapshot_is_disclosed_uncertainty() {
  local out status
  setup_case invalid-snapshot
  write_store "$STORE_A" 'not a quota snapshot'
  write_store "$STORE_B" "$(quota_json claude 64 through_reset secondary@example.com all_models)"
  write_default_config

  out=$(choose --vendor claude)
  status=$?
  expect_code 0 "$status" "an unparseable snapshot must not block dispatch"$'\n'"$out"
  [ "$(field "$out" selected)" = primary ] || fail "unparseable evidence did not fall back to fill-first: $out"
  assert_contains "$out" "selected:headroom unmeasurable (quota-axi returned an invalid snapshot)" \
    "the invalid snapshot was not named as the reason: $out"
  [ "$(field "$out" measured)" = no ] || fail "an unparseable probe was not reported as measured=no: $out"
  [ "$(field "$out" percent)" = unknown ] || fail "an unparseable probe reported a percent: $out"
  [ "$(field "$out" runway)" = unknown ] || fail "an unparseable probe reported a runway: $out"
  [ "$(field "$out" identity)" = unknown ] || fail "an unparseable probe reported an identity: $out"
  assert_contains "$out" "candidate=primary store=$STORE_A measured=no percent=unknown runway=unknown -> selected:headroom unmeasurable (quota-axi returned an invalid snapshot)" \
    "the unmeasurable candidate line did not carry the documented unknown fields: $out"
  pass "an unparseable snapshot is disclosed uncertainty rather than a block"
}

test_probe_reads_the_accounts_own_store_through_its_env_var() {
  local out log
  setup_case probe-store
  write_store "$STORE_A" "$(quota_json codex 0 exhausted_now primary@example.com all_models)"
  write_store "$STORE_B" "$(quota_json codex 87 through_reset secondary@example.com all_models)"
  write_default_config

  out=$(choose --vendor codex) || fail "selection should succeed: $out"
  [ "$(field "$out" selected)" = secondary ] || fail "expected the second account: $out"
  log=$(cat "$QUOTA_LOG")
  assert_contains "$log" "CODEX_HOME=$STORE_A" "the first account's own store was not probed: $log"
  assert_contains "$log" "CODEX_HOME=$STORE_B" "the second account's own store was not probed: $log"
  assert_contains "$log" "--profile-only" "the per-store profile-only read was not used: $log"
  assert_contains "$log" "--provider codex" "the vendor provider was not requested: $log"
  pass "each candidate is probed through its own store with a profile-only read"
}

test_pin_overrides_exhaustion_and_the_reserve() {
  local out status log
  setup_case pin-override
  write_store "$STORE_A" "$(quota_json claude 0 exhausted_now primary@example.com all_models)"
  write_store "$STORE_B" "$(quota_json claude 5 through_reset secondary@example.com all_models)"
  write_default_config

  out=$(choose --vendor claude --pin secondary)
  status=$?
  expect_code 0 "$status" "an explicit pin must not be refused"$'\n'"$out"
  [ "$(field "$out" selected)" = secondary ] || fail "the pin did not select its account: $out"
  [ "$(field "$out" pin)" = yes ] || fail "the pin was not disclosed: $out"
  assert_contains "$out" "percent=5" "the pinned account's evidence was not reported: $out"
  log=$(cat "$QUOTA_LOG")
  assert_contains "$log" "CLAUDE_CONFIG_DIR=$STORE_B" "the pin did not read its own store: $log"
  assert_not_contains "$log" "CLAUDE_CONFIG_DIR=$STORE_A" "the pin probed an unused account's store: $log"
  pass "an explicit pin selects its account even below the reserve"
}

test_pin_of_an_undeclared_account_is_a_configuration_error() {
  local out status
  setup_case pin-unknown
  write_store "$STORE_A" "$(quota_json claude 50 through_reset primary@example.com all_models)"
  write_store "$STORE_B" "$(quota_json claude 50 through_reset secondary@example.com all_models)"
  write_default_config

  out=$(choose --vendor claude --pin nobody)
  status=$?
  expect_code 1 "$status" "an unknown pin must be refused"$'\n'"$out"
  assert_contains "$out" "account nobody is not declared" "the refusal did not name the account: $out"
  pass "a pin naming an undeclared account is a configuration error"
}

test_pin_without_a_store_for_the_vendor_is_refused() {
  local out status
  setup_case pin-wrong-vendor
  write_store "$STORE_A" "$(quota_json codex 50 through_reset primary@example.com all_models)"
  write_store "$STORE_B" "$(quota_json codex 50 through_reset secondary@example.com all_models)"
  cat > "$CONFIG" <<JSON
{
  "accounts": [
    { "name": "codex-only", "codex_home": "$STORE_A" }
  ]
}
JSON

  out=$(choose --vendor claude --pin codex-only)
  status=$?
  expect_code 1 "$status" "a pin with no claude store must be refused"$'\n'"$out"
  assert_contains "$out" "declares no claude store" "the refusal did not name the missing store: $out"
  pass "a pin whose account has no store for the vendor is refused"
}

test_optional_pin_falls_through_to_automatic_selection() {
  local out status
  setup_case pin-optional
  write_store "$STORE_A" "$(quota_json codex 0 exhausted_now primary@example.com all_models)"
  write_store "$STORE_B" "$(quota_json codex 87 through_reset secondary@example.com all_models)"
  mkdir -p "$FIXTURE/store-claude-only"
  cat > "$CONFIG" <<JSON
{
  "accounts": [
    { "name": "primary", "codex_home": "$STORE_A" },
    { "name": "secondary", "codex_home": "$STORE_B" },
    { "name": "claude-only", "claude_config_dir": "$FIXTURE/store-claude-only" }
  ]
}
JSON

  out=$(choose --vendor codex --pin claude-only --pin-optional)
  status=$?
  expect_code 0 "$status" "an optional pin without this vendor's store must fall through"$'\n'"$out"
  [ "$(field "$out" selected)" = secondary ] || fail "optional pin did not fall through to selection: $out"
  [ "$(field "$out" pin)" = no ] || fail "a fallen-through pin was still reported as the pin: $out"
  pass "an optional pin falls through where the account declares no store for the vendor"
}

test_no_eligible_account_refuses_with_evidence() {
  local out status
  setup_case none-eligible
  write_store "$STORE_A" "$(quota_json codex 0 exhausted_now primary@example.com all_models)"
  write_store "$STORE_B" "$(quota_json codex 0 unknown secondary@example.com all_models)"
  write_default_config

  out=$(choose --vendor codex)
  status=$?
  expect_code 3 "$status" "every account being exhausted must refuse"$'\n'"$out"
  assert_not_contains "$out" "selected=primary" "an exhausted account was selected"
  assert_not_contains "$out" "selected=secondary" "an exhausted account was selected"
  assert_contains "$out" "candidate=primary" "the refusal did not report its evidence: $out"
  assert_contains "$out" "candidate=secondary" "the refusal did not report its evidence: $out"
  pass "all accounts exhausted refuses the selection with its evidence"
}

test_no_config_selects_nothing() {
  local out status
  setup_case no-config
  rm -f "$CONFIG"

  out=$(choose --vendor codex)
  status=$?
  expect_code 0 "$status" "an absent config keeps the single-store default"$'\n'"$out"
  [ "$(field "$out" selected)" = none ] || fail "an absent config did not report none: $out"
  assert_contains "$out" "reason=no " "an absent config did not explain itself: $out"

  # A pin is an explicit decision, so it must never be silently dropped for want
  # of a file to resolve it against.
  out=$(choose --vendor codex --pin secondary)
  status=$?
  expect_code 1 "$status" "a pin with no config must be refused"$'\n'"$out"
  assert_contains "$out" "is missing, so --pin secondary cannot be resolved" "the refusal did not name the pin: $out"
  pass "no account config means no selection, and a pin without one is refused"
}

test_vendor_with_no_configured_account_selects_nothing() {
  local out status
  setup_case vendor-uncovered
  write_store "$STORE_A" "$(quota_json codex 50 through_reset primary@example.com all_models)"
  cat > "$CONFIG" <<JSON
{
  "accounts": [
    { "name": "codex-only", "codex_home": "$STORE_A" }
  ]
}
JSON

  out=$(choose --vendor claude)
  status=$?
  expect_code 0 "$status" "an uncovered vendor is not an error"$'\n'"$out"
  [ "$(field "$out" selected)" = none ] || fail "an uncovered vendor did not report none: $out"
  assert_contains "$out" "reason=no claude account is configured" "the reason did not name the vendor: $out"
  pass "a vendor with no configured account selects nothing"
}

test_missing_store_directory_is_a_configuration_error() {
  local out status
  setup_case missing-store
  write_store "$STORE_B" "$(quota_json codex 87 through_reset secondary@example.com all_models)"
  # The first account's store directory is deliberately absent.
  rm -rf "$STORE_A"
  write_default_config

  out=$(choose --vendor codex)
  status=$?
  expect_code 1 "$status" "a missing store directory must be refused"$'\n'"$out"
  assert_contains "$out" "account primary codex_home is not an existing directory" \
    "the refusal did not name the account and field: $out"
  pass "a configured store that is not an existing directory refuses the spawn"
}

test_malformed_config_is_refused() {
  local out status
  setup_case malformed
  printf '%s\n' '{"accounts":[{"name":"a","codex_home":"relative/path"}]}' > "$CONFIG"

  out=$(choose --vendor codex)
  status=$?
  expect_code 1 "$status" "a relative store path must be refused"$'\n'"$out"
  assert_contains "$out" "each store path must be absolute" "the schema error was not reported: $out"

  printf '%s\n' '{"accounts": []}' > "$CONFIG"
  out=$(choose --vendor codex)
  status=$?
  expect_code 1 "$status" "an empty accounts array must be refused"$'\n'"$out"
  assert_contains "$out" "accounts needs at least one account" "the schema error was not reported: $out"

  printf '%s\n' '{"accounts":[{"name":"a","codex_home":"/tmp"},{"name":"a","codex_home":"/tmp"}]}' > "$CONFIG"
  out=$(choose --vendor codex)
  status=$?
  expect_code 1 "$status" "duplicate account names must be refused"$'\n'"$out"
  assert_contains "$out" "account names must be unique" "the schema error was not reported: $out"

  printf '%s\n' '{"accounts":"hello"}' > "$CONFIG"
  out=$(choose --vendor codex)
  status=$?
  expect_code 1 "$status" "a non-array accounts value must be refused"$'\n'"$out"
  assert_contains "$out" "accounts must be an array" "the schema error was not reported: $out"

  printf '%s\n' '{"accounts":[5]}' > "$CONFIG"
  out=$(choose --vendor codex)
  status=$?
  expect_code 1 "$status" "a non-object account entry must be refused"$'\n'"$out"
  assert_contains "$out" "each account must be an object" "the schema error was not reported: $out"

  printf '%s\n' '{"accounts":[{"name":"a","codex_home":"/tmp"}],"order":{"claude":["a"]}}' > "$CONFIG"
  out=$(choose --vendor codex)
  status=$?
  expect_code 1 "$status" "a removed top-level order key must be refused"$'\n'"$out"
  assert_contains "$out" "top-level keys must be accounts only" "the removed order key was silently accepted: $out"
  assert_contains "$out" "order" "the refusal did not name the offending key: $out"

  printf '%s\n' '{"accounts":[{"name":"a","codex_home":"/tmp"}],"notes":"legacy"}' > "$CONFIG"
  out=$(choose --vendor codex)
  status=$?
  expect_code 1 "$status" "an unknown top-level key must be refused"$'\n'"$out"
  assert_contains "$out" "top-level keys must be accounts only" "an unknown top-level key was silently accepted: $out"

  printf '%s\n' 'not json' > "$CONFIG"
  out=$(choose --vendor codex)
  status=$?
  expect_code 1 "$status" "malformed JSON must be refused"$'\n'"$out"
  assert_contains "$out" "is malformed JSON" "the malformed-JSON error was not reported: $out"
  pass "malformed account configuration is reported rather than selected around"
}

test_validate_checks_the_whole_file() {
  local out status
  setup_case validate
  write_store "$STORE_A" "$(quota_json codex 10 through_reset primary@example.com all_models)"
  write_store "$STORE_B" "$(quota_json claude 10 through_reset secondary@example.com all_models)"
  write_default_config

  out=$(choose --validate)
  status=$?
  expect_code 0 "$status" "a valid file must validate silently"$'\n'"$out"
  [ -z "$out" ] || fail "a valid file produced output: $out"

  rm -rf "$STORE_B"
  out=$(choose --validate)
  status=$?
  expect_code 1 "$status" "a missing store must fail validation"$'\n'"$out"
  assert_contains "$out" "account secondary" "validation did not name the failing account: $out"

  write_default_config
  rm -f "$CONFIG"
  out=$(choose --validate)
  status=$?
  expect_code 0 "$status" "an absent file is not a validation failure"$'\n'"$out"
  pass "--validate reports a broken account file for both vendors and accepts absence"
}

test_home_relative_store_paths_expand() {
  local out status
  setup_case home-relative
  mkdir -p "$FIXTURE/home/.claude"
  write_store "$FIXTURE/home/.claude" "$(quota_json claude 55 through_reset primary@example.com all_models)"
  cat > "$CONFIG" <<'JSON'
{
  "accounts": [
    { "name": "primary", "claude_config_dir": "~/.claude" }
  ]
}
JSON

  out=$(choose --vendor claude)
  status=$?
  expect_code 0 "$status" "a home-relative store should resolve"$'\n'"$out"
  [ "$(field "$out" store)" = "$FIXTURE/home/.claude" ] || fail "the store was not expanded against HOME: $out"
  pass "a ~-prefixed store path resolves against the launching user's home"
}

test_usage_errors() {
  local out status
  setup_case usage
  out=$(choose --vendor grok)
  status=$?
  expect_code 2 "$status" "an unknown vendor is a usage error"$'\n'"$out"
  out=$(choose)
  status=$?
  expect_code 2 "$status" "a missing vendor is a usage error"$'\n'"$out"

  # Ensure the manual inspection path documents the contract.
  out=$(FM_CONFIG_OVERRIDE="$FIXTURE/config" "$CHOOSER" --help 2>&1)
  status=$?
  expect_code 2 "$status" "--help prints usage"$'\n'"$out"
  assert_contains "$out" "fm-account-choose.sh --vendor <codex|claude>" "usage did not show the selection form"
  pass "usage errors exit 2 and print the contract"
}

# --- runner -----------------------------------------------------------------

test_fill_first_over_declaration_order
test_exhausted_first_account_overflows_to_the_second
test_zero_percent_first_account_overflows
test_reserve_floor_holds_the_colleagues_claude_account
test_fractional_percent_and_reserve_still_hold_the_floor
test_reserve_floor_holds_at_the_boundary_and_a_pin_still_selects
test_reserve_does_not_apply_to_codex
test_unmeasurable_first_account_is_selected_as_disclosed_uncertainty
test_nonzero_quota_exit_still_reads_its_valid_snapshot
test_unreadable_snapshot_is_disclosed_uncertainty
test_probe_reads_the_accounts_own_store_through_its_env_var
test_pin_overrides_exhaustion_and_the_reserve
test_pin_of_an_undeclared_account_is_a_configuration_error
test_pin_without_a_store_for_the_vendor_is_refused
test_optional_pin_falls_through_to_automatic_selection
test_no_eligible_account_refuses_with_evidence
test_no_config_selects_nothing
test_vendor_with_no_configured_account_selects_nothing
test_account_without_a_vendor_store_is_not_a_candidate
test_top_level_reserve_is_refused
test_top_level_scalar_is_refused
test_missing_store_directory_is_a_configuration_error
test_malformed_config_is_refused
test_validate_checks_the_whole_file
test_home_relative_store_paths_expand
test_usage_errors

printf '%s\n' '# all fm-account-choose tests passed'
