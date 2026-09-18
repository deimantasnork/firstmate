#!/usr/bin/env bash
# fm-account-choose.sh - choose the credential account one dispatch runs on.
#
# Usage:
#   fm-account-choose.sh --vendor <codex|claude> [--pin <name>] [--config <file>]
#                        [--probe-timeout <seconds>]
#   fm-account-choose.sh --validate [--config <file>]
#
# One subscription account is one named entry in local config/crew-accounts.json
# with a Codex store path, a Claude store path, or both (docs/configuration.md
# "Crew accounts" owns the schema and its field semantics). This script chooses
# which account a spawn uses for ONE vendor, using quota-axi evidence read from
# THAT account's own store, and prints the store the caller must forward as
# CODEX_HOME or CLAUDE_CONFIG_DIR. It never launches anything and never writes a
# credential file.
#
# Selection is fill-first over the accounts' declaration order: the first
# account declaring a store for this vendor whose own measured evidence does not
# disqualify it is chosen, so an earlier account is drained down toward its
# reserve before the next one is touched. An account is disqualified only on
# measured evidence: a runway of `exhausted_now`, a known effective remaining
# percent of zero, or a known percent at or below that account's configured
# reserve for the vendor. Unmeasurable headroom - a store
# quota-axi cannot read at all, including an expired access token that only a
# real vendor call would refresh - is disclosed uncertainty, never a block, so
# such an account stays selectable and is reported as `measured=no`.
#
# --pin <name> selects one account explicitly and bypasses every eligibility
# rule: a pin is firstmate's or the captain's own decision, so a reserve or an
# exhausted window never overrides it. The pin's own evidence is still reported.
# --pin-optional softens that pin for a caller resolving SEVERAL vendors with one
# account name, such as a secondmate home that must hold one store per vendor:
# where the pinned account declares no store for this vendor, the selection
# falls through to the ordinary fill-first path instead of refusing.
#
# Evidence comes from `quota-axi --provider <vendor> --profile-only --full
# --json` with that account's store in CODEX_HOME or CLAUDE_CONFIG_DIR, so the
# read is per-account rather than ambient. --profile-only reads only that
# credential file, never the keychain, a CLI RPC, a fallback store, or a cache,
# and it never refreshes or writes anything. Each probe is bounded by
# fm_run_timed, so a hung vendor CLI cannot wedge a dispatch, and raw vendor
# output is parsed here and never printed.
#
# Output (stdout, one `key=value` line each; a key=value value never contains a
# space or a newline):
#   selected=<name>|none       the chosen account, or none when this vendor has
#                              no account configured
#   reason=<text>              why nothing applies (selected=none only)
#   vendor=<vendor>
#   pin=yes|no                 a pin was requested for this selection
#   store_env=<var>            CODEX_HOME or CLAUDE_CONFIG_DIR (selected only)
#   store=<path>               the selected account's store for this vendor
#   measured=yes|no            whether that account's headroom was measurable
#   percent=<0..100>|unknown   effective percent remaining (measured=yes only)
#   runway=<status>|unknown    quota-axi runway status
#   identity=<email>|unknown   the account identity quota-axi reported
#   candidate=<name> store=<path> measured=<yes|no|unknown> percent=<n|unknown>
#                             runway=<status|unknown> -> <verdict>
#                              one line per candidate, in evaluation order;
#                              verdict is `selected`, `selected:headroom
#                              unmeasurable (<reason>)`, `skipped:<reason>`, or
#                              `not-considered:<reason>`
#
# Exit status:
#   0   selected=<name>, or selected=none because this vendor has no configured
#       account; the caller keeps its own behavior for both
#   1   usage or configuration error (unreadable or malformed
#       config/crew-accounts.json, an unknown pin, a pin with no store for this
#       vendor, a store path that is not an existing directory, or missing jq)
#   3   every configured account for this vendor was disqualified on measured
#       evidence; the candidate lines say why, and nothing was selected
#
# Environment:
#   FM_CONFIG_OVERRIDE  select the config directory outright (tests and
#                       specialized setup, the same override the other scripts
#                       honor)
#   FM_ACCOUNT_PROBE_TIMEOUT  hard per-store probe bound in seconds (default 20)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

die_usage() {
  printf 'fm-account-choose: %s\n' "$1" >&2
  usage
}

# One vendor per credential store, and the environment variable its CLI reads
# that store from. Kept as one table here so a caller and its tests cannot
# disagree about the mapping.
account_store_field() {  # <vendor>
  case "$1" in
    codex) printf 'codex_home\n' ;;
    claude) printf 'claude_config_dir\n' ;;
    *) return 1 ;;
  esac
}

account_store_env() {  # <vendor>
  case "$1" in
    codex) printf 'CODEX_HOME\n' ;;
    claude) printf 'CLAUDE_CONFIG_DIR\n' ;;
    *) return 1 ;;
  esac
}

VENDOR=
PIN=
PIN_OPTIONAL=0
CONFIG_FILE=
VALIDATE=0
PROBE_TIMEOUT=${FM_ACCOUNT_PROBE_TIMEOUT:-20}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help) usage ;;
    --validate)
      VALIDATE=1
      shift
      ;;
    --vendor)
      [ -n "${2-}" ] || die_usage "--vendor needs a value"
      VENDOR=$2
      shift 2
      ;;
    --pin)
      [ -n "${2-}" ] || die_usage "--pin needs a value"
      PIN=$2
      shift 2
      ;;
    --pin-optional)
      PIN_OPTIONAL=1
      shift
      ;;
    --config)
      [ -n "${2-}" ] || die_usage "--config needs a path"
      CONFIG_FILE=$2
      shift 2
      ;;
    --probe-timeout)
      [ -n "${2-}" ] || die_usage "--probe-timeout needs a value"
      PROBE_TIMEOUT=$2
      shift 2
      ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

case "$PROBE_TIMEOUT" in
  '' | *[!0-9]* | 0) PROBE_TIMEOUT=20 ;;
esac
if [ "$VALIDATE" -eq 1 ]; then
  [ -z "$PIN" ] || die_usage "--validate and --pin cannot be combined"
  [ -z "$VENDOR" ] || die_usage "--validate checks the whole file and takes no --vendor"
else
  case "$VENDOR" in
    codex | claude) ;;
    '') die_usage "--vendor <codex|claude> is required" ;;
    *) die_usage "--vendor must be codex or claude (got '$VENDOR')" ;;
  esac
fi
if [ -n "$PIN" ]; then
  case "$PIN" in
    [a-z0-9]*) ;;
    *) die_usage "--pin must start with a lowercase letter or digit" ;;
  esac
  case "$PIN" in
    *[!a-z0-9._-]*) die_usage "--pin may contain only lowercase letters, digits, dot, underscore, and dash" ;;
  esac
fi

CONFIG_FILE=${CONFIG_FILE:-$CONFIG_DIR/crew-accounts.json}

config_present() {
  [ -e "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ]
}

# The one owner of the schema's structural rules. Prints the first violation, or
# nothing when the file is valid. Store paths are validated as text here; their
# existence is checked below, because --validate reports it for both vendors
# while a selection only needs the vendor it is choosing.
config_schema_error() {
  jq -r '
    def name_re: "^[a-z0-9][a-z0-9._-]*$";
    def vendors: ["codex", "claude"];
    def store_fields: ["codex_home", "claude_config_dir"];
    # A store is addressed by an absolute path or a ~-prefixed one; anything
    # else would resolve against whatever directory the caller happened to run
    # in, which could silently point a worker at another credential file.
    def path_ok($p):
      ($p | type) == "string" and ($p | length) > 0
      and ($p | test("^(/|~$|~/)"))
      and (($p | [explode[] | select(. < 32)] | length) == 0);
    def field_ok($e):
      ["name", "reserve"] + store_fields | index($e.key) != null;
    if type != "object" then "top-level value must be an object"
    elif has("reserve") then "reserve must be set per account (accounts[].reserve), not at the top level"
    elif (.accounts | type) != "array" then "accounts must be an array"
    else
    .accounts as $accounts |
    [$accounts[] | if type == "object" then .name else null end] as $names |
    if ($accounts | length) == 0 then "accounts needs at least one account"
    elif ([$accounts[] | select(type != "object")] | length) > 0 then "each account must be an object"
    elif ([$accounts[] | select((.name | type) != "string" or ((.name | test(name_re)) | not))] | length) > 0
      then "each account needs a name matching ^[a-z0-9][a-z0-9._-]*$"
    elif ($names | length) != ($names | unique | length) then "account names must be unique"
    elif ([$accounts[] | select((has("codex_home") | not) and (has("claude_config_dir") | not))] | length) > 0
      then "each account needs codex_home, claude_config_dir, or both"
    elif ([$accounts[] | to_entries[] | select(field_ok(.) | not)] | length) > 0
      then "each account accepts only name, codex_home, claude_config_dir, and reserve"
    elif ([$accounts[] | to_entries[] | select(.key as $k | (store_fields | index($k)) != null) | select((path_ok(.value) | not))] | length) > 0
      then "each store path must be absolute or start with ~/ and carry no control character"
    elif ([$accounts[] | select(has("reserve") and ((.reserve | type) != "object"))] | length) > 0
      then "account reserve must be an object keyed by vendor"
    elif ([$accounts[] | .reserve // {} | keys[] | select(. as $k | (vendors | index($k)) == null)] | length) > 0
      then "account reserve names a vendor other than codex or claude"
    elif ([$accounts[] | .reserve // {} | to_entries[] | select((.value | type) != "number" or .value < 0 or .value > 100)] | length) > 0
      then "each account reserve must be a number from 0 through 100"
    else empty
    end
    end
  ' "$CONFIG_FILE" 2>/dev/null
}

# Refuse any structural violation before a probe runs. Returns 1 (with no
# output) when this home has no account config at all, which is the ordinary
# single-store default.
load_config() {
  if ! config_present; then
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    printf 'error: jq is required to read %s\n' "$CONFIG_FILE" >&2
    exit 1
  }
  if [ ! -f "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ]; then
    printf 'error: %s is not a readable regular file\n' "$CONFIG_FILE" >&2
    exit 1
  fi
  if ! jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
    printf 'error: %s is malformed JSON\n' "$CONFIG_FILE" >&2
    exit 1
  fi
  local err rc=0
  err=$(config_schema_error) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'error: %s could not be validated\n' "$CONFIG_FILE" >&2
    exit 1
  fi
  if [ -n "$err" ]; then
    printf 'error: %s - %s\n' "$CONFIG_FILE" "$err" >&2
    exit 1
  fi
  return 0
}

# Expand the one tilde form the schema allows. The caller proves the result is
# an existing directory and treats a failure as a configuration error.
resolve_store_path() {
  local raw=$1
  if [ "$raw" = '~' ]; then
    printf '%s\n' "${HOME:-}"
    return 0
  fi
  if [ "${raw:0:2}" = "$(printf '~')/" ]; then
    printf '%s\n' "${HOME:-}${raw:1}"
    return 0
  fi
  printf '%s\n' "$raw"
}

require_store() {  # <account-name> <field> <raw-path>
  local account=$1 field=$2 raw=$3 resolved
  resolved=$(resolve_store_path "$raw")
  if [ -z "$resolved" ] || [ ! -d "$resolved" ]; then
    printf 'error: %s: account %s %s is not an existing directory: %s\n' \
      "$CONFIG_FILE" "$account" "$field" "${resolved:-$raw}" >&2
    exit 1
  fi
  printf '%s\n' "$resolved"
}

account_store_raw() {  # <account-name> <field>
  jq -r --arg n "$1" --arg f "$2" '
    .accounts[] | select(.name == $n) | (.[$f] // empty)
  ' "$CONFIG_FILE"
}

account_exists() {  # <account-name>
  jq -e --arg n "$1" '[.accounts[] | select(.name == $n)] | length > 0' "$CONFIG_FILE" >/dev/null 2>&1
}

account_reserve() {  # <account-name> <vendor>
  jq -r --arg n "$1" --arg v "$2" '
    .accounts[] | select(.name == $n) | (.reserve[$v] // 0)
  ' "$CONFIG_FILE"
}

# Every account declaring a store for <vendor>, in declaration order.
account_candidates() {  # <vendor>
  local vendor=$1 field
  field=$(account_store_field "$vendor") || return 1
  jq -r --arg f "$field" '
    .accounts[] | select(has($f)) | .name
  ' "$CONFIG_FILE" 2>/dev/null || {
    printf 'error: %s could not be read\n' "$CONFIG_FILE" >&2
    exit 1
  }
}

# ---- quota evidence ----------------------------------------------------------

PROBE_JSON=
PROBE_STATUS=

probe_store() {  # <vendor> <store>
  local vendor=$1 store=$2 out rc=0
  PROBE_JSON=
  PROBE_STATUS=failed
  if ! command -v quota-axi >/dev/null 2>&1; then
    PROBE_STATUS=unavailable
    return 0
  fi
  case "$vendor" in
    codex)
      out=$(CODEX_HOME="$store" fm_run_timed "$PROBE_TIMEOUT" quota-axi \
        --provider codex --profile-only --full --json </dev/null 2>/dev/null) || rc=$?
      ;;
    claude)
      out=$(CLAUDE_CONFIG_DIR="$store" fm_run_timed "$PROBE_TIMEOUT" quota-axi \
        --provider claude --profile-only --full --json </dev/null 2>/dev/null) || rc=$?
      ;;
  esac
  if [ "$rc" -eq 124 ]; then
    PROBE_STATUS=timeout
    return 0
  fi
  # The parse is authoritative, not the exit status: quota-axi 0.1.46 exits 1
  # for a provider in an error state while still printing a valid schema-5
  # snapshot whose quotaSemantics.status is `unknown`. That snapshot is exactly
  # the disclosed-uncertainty evidence this script needs, so a readable one is
  # `ok` even on a non-zero exit, and only output that does not parse is a
  # failed probe.
  if [ -n "$out" ] && printf '%s\n' "$out" | fm_quota_json_valid; then
    PROBE_JSON=$out
    PROBE_STATUS=ok
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    PROBE_STATUS=failed
    return 0
  fi
  PROBE_STATUS=invalid
}

# One space-separated evidence record for <vendor>: measured, percent, runway,
# identity, scope. The account-wide scopes bound every model, so they are the
# account's own headroom; anything else falls back to the worst known row.
probe_evidence() {  # <vendor>
  local vendor=$1
  printf '%s\n' "$PROBE_JSON" | jq -r --arg v "$vendor" '
    def flat: [explode[] | select(. >= 32)] | implode | gsub("[[:space:]]"; "_");
    def show($x): if $x == null or $x == "" then "unknown" else ($x | flat) end;
    [.providers[] | select(.provider == $v)] as $ps |
    if ($ps | length) == 0 then
      ["no", "unknown", "unknown", "unknown", "unknown"] | join(" ")
    else
      ($ps[0]) as $p |
      ([$p.quotaSemantics.effectiveAvailability[]?
        | select(.status == "known" and (.effectivePercentRemaining | type) == "number")]) as $known |
      if ($known | length) == 0 then
        ["no", "unknown", "unknown", show($p.account.email), "unknown"] | join(" ")
      else
        ([$known[] | select(.scope == "all_models" or .scope == "all_products")]) as $acct |
        (if ($acct | length) > 0 then $acct else $known end) as $rows |
        ([$rows[].effectivePercentRemaining] | min) as $pct |
        (if any($rows[]; ((.runway.status // "unknown") == "exhausted_now")) then "exhausted_now"
         else (($rows[0].runway.status // "unknown")) end) as $runway |
        (([$rows[] | select(((.runway.status // "") == "exhausted_now")
                            or .effectivePercentRemaining <= 0) | .scope] | first)
         // ($rows[0].scope // "unknown")) as $scope |
        ["yes", ($pct | tostring), $runway, show($p.account.email), show($scope)] | join(" ")
      end
    end
  '
}

probe_failure_reason() {
  case "$PROBE_STATUS" in
    ok) printf 'none\n' ;;
    unavailable) printf 'quota-axi is not installed\n' ;;
    timeout) printf 'the quota read timed out\n' ;;
    invalid) printf 'quota-axi returned an invalid snapshot\n' ;;
    *) printf 'the quota read failed\n' ;;
  esac
}

# ---- validation mode ---------------------------------------------------------

if [ "$VALIDATE" -eq 1 ]; then
  load_config || exit 0
  while IFS= read -r account; do
    [ -n "$account" ] || continue
    for field in codex_home claude_config_dir; do
      raw=$(account_store_raw "$account" "$field")
      [ -n "$raw" ] || continue
      require_store "$account" "$field" "$raw" >/dev/null
    done
  done <<EOF
$(jq -r '.accounts[].name' "$CONFIG_FILE")
EOF
  exit 0
fi

# ---- selection ---------------------------------------------------------------

STORE_ENV=$(account_store_env "$VENDOR")

if ! load_config; then
  if [ -n "$PIN" ]; then
    printf 'error: %s is missing, so --pin %s cannot be resolved\n' "$CONFIG_FILE" "$PIN" >&2
    exit 1
  fi
  printf 'selected=none\nreason=no %s\n' "$CONFIG_FILE"
  exit 0
fi

emit_selection() {  # <name> <store> <measured> <percent> <runway> <identity> <pin>
  printf 'selected=%s\n' "$1"
  printf 'vendor=%s\n' "$VENDOR"
  printf 'pin=%s\n' "$7"
  printf 'store_env=%s\n' "$STORE_ENV"
  printf 'store=%s\n' "$2"
  printf 'measured=%s\n' "$3"
  if [ "$3" = yes ]; then
    printf 'percent=%s\n' "$4"
  else
    printf 'percent=unknown\n'
  fi
  printf 'runway=%s\n' "$5"
  printf 'identity=%s\n' "$6"
}

emit_candidate() {  # <name> <store> <measured> <percent> <runway> <verdict>
  printf 'candidate=%s store=%s measured=%s percent=%s runway=%s -> %s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6"
}

if [ -n "$PIN" ]; then
  account_exists "$PIN" || {
    printf 'error: %s: account %s is not declared\n' "$CONFIG_FILE" "$PIN" >&2
    exit 1
  }
  PIN_FIELD=$(account_store_field "$VENDOR")
  PIN_RAW=$(account_store_raw "$PIN" "$PIN_FIELD")
  if [ -z "$PIN_RAW" ]; then
    if [ "$PIN_OPTIONAL" -eq 1 ]; then
      PIN=
    else
      printf 'error: %s: account %s declares no %s store\n' "$CONFIG_FILE" "$PIN" "$VENDOR" >&2
      exit 1
    fi
  fi
fi

if [ -n "$PIN" ]; then
  PIN_STORE=$(require_store "$PIN" "$PIN_FIELD" "$PIN_RAW") || exit 1
  probe_store "$VENDOR" "$PIN_STORE"
  read -r PIN_MEASURED PIN_PCT PIN_RUNWAY PIN_IDENTITY _ <<<"$(probe_evidence "$VENDOR")"
  emit_candidate "$PIN" "$PIN_STORE" "$PIN_MEASURED" "$PIN_PCT" "$PIN_RUNWAY" selected
  emit_selection "$PIN" "$PIN_STORE" "$PIN_MEASURED" "$PIN_PCT" "$PIN_RUNWAY" "$PIN_IDENTITY" yes
  exit 0
fi

CANDIDATE_ORDER=$(account_candidates "$VENDOR") || exit 1
CANDIDATES=()
while IFS= read -r name; do
  [ -n "$name" ] || continue
  CANDIDATES+=("$name")
done <<EOF
$CANDIDATE_ORDER
EOF

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  printf 'selected=none\nreason=no %s account is configured in %s\n' "$VENDOR" "$CONFIG_FILE"
  exit 0
fi

CANDIDATE_LINES=()
SELECTED=
SELECTED_STORE=
SELECTED_MEASURED=
SELECTED_PCT=
SELECTED_RUNWAY=
SELECTED_IDENTITY=

for name in "${CANDIDATES[@]}"; do
  field=$(account_store_field "$VENDOR")
  raw=$(account_store_raw "$name" "$field")
  store=$(require_store "$name" "$field" "$raw") || exit 1
  if [ -n "$SELECTED" ]; then
    CANDIDATE_LINES+=("$(printf 'candidate=%s store=%s measured=unknown percent=unknown runway=unknown -> not-considered:an earlier account was selected' "$name" "$store")")
    continue
  fi
  probe_store "$VENDOR" "$store"
  read -r measured pct runway identity scope <<<"$(probe_evidence "$VENDOR")"
  reserve=$(account_reserve "$name" "$VENDOR")
  if [ "$measured" != yes ]; then
    SELECTED=$name
    SELECTED_STORE=$store
    SELECTED_MEASURED=$measured
    SELECTED_PCT=$pct
    SELECTED_RUNWAY=$runway
    SELECTED_IDENTITY=$identity
    reason=$(probe_failure_reason)
    [ "$reason" != none ] || reason='quota-axi reports no measurable window'
    CANDIDATE_LINES+=("$(printf 'candidate=%s store=%s measured=%s percent=%s runway=%s -> selected:headroom unmeasurable (%s)' "$name" "$store" "$measured" "$pct" "$runway" "$reason")")
    continue
  fi
  verdict=
  if [ "$runway" = exhausted_now ]; then
    verdict="skipped:runway exhausted_now at $scope"
  elif awk -v p="$pct" 'BEGIN { exit !(p <= 0) }'; then
    verdict="skipped:0% remaining at $scope"
  elif awk -v p="$pct" -v r="$reserve" 'BEGIN { exit !(r > 0 && p <= r) }'; then
    verdict="skipped:$pct% remaining is at or below the $reserve% reserve"
  fi
  if [ -n "$verdict" ]; then
    CANDIDATE_LINES+=("$(printf 'candidate=%s store=%s measured=%s percent=%s runway=%s -> %s' "$name" "$store" "$measured" "$pct" "$runway" "$verdict")")
    continue
  fi
  SELECTED=$name
  SELECTED_STORE=$store
  SELECTED_MEASURED=$measured
  SELECTED_PCT=$pct
  SELECTED_RUNWAY=$runway
  SELECTED_IDENTITY=$identity
  CANDIDATE_LINES+=("$(printf 'candidate=%s store=%s measured=%s percent=%s runway=%s -> selected' "$name" "$store" "$measured" "$pct" "$runway")")
done

for line in "${CANDIDATE_LINES[@]}"; do
  printf '%s\n' "$line"
done

if [ -z "$SELECTED" ]; then
  printf 'error: no %s account is usable: every configured account was disqualified on measured evidence\n' "$VENDOR" >&2
  exit 3
fi

emit_selection "$SELECTED" "$SELECTED_STORE" "$SELECTED_MEASURED" "$SELECTED_PCT" \
  "$SELECTED_RUNWAY" "$SELECTED_IDENTITY" no
exit 0
