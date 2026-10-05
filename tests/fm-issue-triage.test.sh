#!/usr/bin/env bash
# Offline behavior tests for registered issue discovery, real durable inbox
# publication/replay, hourly attempt throttling, and trusted-check lifecycle.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-issue-triage)
CHECK="$ROOT/bin/fm-issue-triage.sh"
NOW=1791201600

make_home() {
  local home="$TMP_ROOT/$1" fb
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/responses"
  fb=$(fm_fakebin "$home")
  cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s %s\n' "${1:-}" "${2:-}" "${3:-}" >> "$FM_ISSUE_TEST_HOME/calls"
[ "$#" -eq 6 ] && [ "$1" = api ] && [ "$2" = GET ] && [ "$4" = --full ] && [ "$5" = --jq ] || exit 90
case "$3" in
  /repos/*/issues\?state=open\&sort=updated\&direction=desc\&per_page=100) ;;
  *) exit 91 ;;
esac
repo=${3#/repos/}; repo=${repo%%/issues*}; file="$FM_ISSUE_TEST_HOME/responses/${repo//\//--}"
if [ -f "$file.failure" ]; then
  cat "$file.failure"
  printf 'extra diagnostic\nsecond diagnostic\n' >&2
  exit 1
fi
if [ -f "$file.malformed" ]; then
  printf 'unexpected: response\n'
  exit 0
fi
[ ! -f "$file.delay" ] || sleep "$(cat "$file.delay")"
# Execute the public --jq projection against GitHub-shaped fixtures; represent
# its one string field with TOON's JSON-compatible quoting, as gh-axi does.
jq "$6" "$file.json" | jq -r '.issues_json | @json | "issues_json: " + .'
SH
  chmod +x "$fb/gh-axi"
  : > "$home/calls"
  printf '%s\n' "$home"
}

add_project() {
  local home=$1 name=$2 url=$3 annotation=${4:-}
  mkdir -p "$home/projects/$name"
  git -C "$home/projects/$name" init -q
  [ -z "$url" ] || git -C "$home/projects/$name" remote add origin "$url"
  printf -- '- %s%s - fixture (added 2026-10-05)\n' "$name" "$annotation" >> "$home/data/projects.md"
}

write_issue() {
  local home=$1 repo=$2 stamp=${3:-2026-10-05T11:00:00Z}
  jq -n --arg repo "$repo" --arg stamp "$stamp" '[
    {number:12,state:"open",title:"Queue \"this\", safely",html_url:("https://github.com/"+$repo+"/issues/12"),
      user:{login:"reporter"},labels:[{name:"bug"},{name:"help wanted"}],
      created_at:"2026-10-04T12:00:00Z",updated_at:$stamp,
      body:"First line\nSecond line, with literal $(commands) and `code`."},
    {number:13,state:"open",pull_request:{url:"https://api.github.com/pulls/13"}},
    {number:14,state:"closed"}
  ]' > "$home/responses/${repo//\//--}.json"
}

run_check() {
  local home=$1 clock=$2
  shift 2
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_ISSUE_TRIAGE_NOW="$clock" FM_CHECK_TIMEOUT=30 \
    FM_ISSUE_TEST_HOME="$home" PATH="$home/fakebin:$PATH" "$@" bash "$CHECK" check
}

run_action() {
  local home=$1
  shift
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" bash "$CHECK" "$@"
}

notes() { find "$1/state/inbox" -maxdepth 1 -type f -name '*.note' 2>/dev/null | wc -l | tr -d ' '; }
registered() {
  FM_HOME="$1" bash -c '
    . "$1/bin/fm-pr-lib.sh"
    . "$1/bin/fm-check-lib.sh"
    fm_custom_check_registered "$FM_HOME/state" issue-triage' bash "$ROOT"
}

home=$(make_home registry)
add_project "$home" 'alpha space' https://github.com/Org/Alpha.git
add_project "$home" beta git@github.com:org/beta.git ' [direct-PR +yolo branch=work/]'
add_project "$home" duplicate ssh://git@github.com/org/alpha.git ' [no-mistakes]'
add_project "$home" local '' ' [local-only]'
add_project "$home" gitlab https://gitlab.com/org/other.git
printf -- '- missing [no-mistakes] - clone absent\n- ../escape - unsafe name\n' >> "$home/data/projects.md"
write_issue "$home" org/alpha
printf '[]\n' > "$home/responses/org--beta.json"
out=$(run_check "$home" "$NOW") || fail 'registry sweep failed'
assert_equals '' "$out" 'successful discovery is silent and relies on the durable inbox wake'
assert_equals 2 "$(wc -l < "$home/calls" | tr -d ' ')" 'one read per distinct registered GitHub repository'
assert_grep '/repos/org/alpha/issues?state=open' "$home/calls" 'HTTPS origin and spaced registry name are parsed'
assert_grep '/repos/org/beta/issues?state=open' "$home/calls" 'bracket annotation and SSH origin are parsed'
assert_equals 1 "$(notes "$home")" 'one open issue is delivered; PRs and closed issues are excluded'
note=$(find "$home/state/inbox" -maxdepth 1 -name '*.note')
assert_grep 'request_id=issue:org/alpha#12@2026-10-05T11:00:00Z' "$note" 'exact issue request id survives publication'
for text in 'Repo: org/alpha' 'Issue: #12' 'Title: Queue "this", safely' \
  'URL: https://github.com/org/alpha/issues/12' 'Author: reporter' 'Labels: bug, help wanted' \
  'Created: 1d ago' 'Updated: 1h ago' 'Body excerpt: First line Second line'; do
  assert_grep "$text" "$note" 'triage note carries the requested issue context'
done
assert_equals '2026-10-05T11:00:00Z' "$(jq -r '.seen["org/alpha#12"]' "$home/state/.issue-triage")" 'seen ledger advances after delivery'
assert_grep 'check: captain inbox note' "$home/state/.wake-queue" 'the note durably wakes firstmate'
pass 'registry parsing and a new issue use one bounded listing and real durable intake'

out=$(run_check "$home" "$((NOW + 3599))")
assert_equals '' "$out" 'ineligible sweeps are silent'
assert_equals 2 "$(wc -l < "$home/calls" | tr -d ' ')" 'GitHub is not polled before one hour'
out=$(run_check "$home" "$((NOW + 3600))")
assert_equals '' "$out" 'an unchanged eligible sweep is silent'
assert_equals 1 "$(notes "$home")" 'unchanged issue is not delivered again'
assert_equals 4 "$(wc -l < "$home/calls" | tr -d ' ')" 'one new listing per repo after the interval'
# Lose only the seen entry to model a crash after inbox publication; the exact
# request-id replay must still suppress both another note and another wake.
jq '.seen={}' "$home/state/.issue-triage" > "$home/reset"
mv "$home/reset" "$home/state/.issue-triage"
run_check "$home" "$((NOW + 7200))"
assert_equals 1 "$(notes "$home")" 'inbox replay is idempotent when the seen ledger was not committed'
assert_equals 1 "$(grep -c 'check: captain inbox note' "$home/state/.wake-queue")" 'replay does not wake twice'
write_issue "$home" org/alpha 2026-10-05T13:00:00Z
run_check "$home" "$((NOW + 10800))"
assert_equals 2 "$(notes "$home")" 'a later update is delivered once more'
assert_equals 1 "$(find "$home/state/inbox" -maxdepth 1 -name '*.note' -exec grep -lF 'request_id=issue:org/alpha#12@2026-10-05T13:00:00Z' {} \; | wc -l | tr -d ' ')" 'updated request id is exact and unique'
out=$(run_check "$home" "$((NOW + 14400))")
assert_equals '' "$out" 'no changes means silence'
assert_equals 2 "$(notes "$home")" 'the changed version is not delivered twice'
pass 'throttle, unchanged replay, crash replay, and changed issue delivery converge'

home=$(make_home failures)
add_project "$home" inaccessible https://github.com/org/hidden.git
add_project "$home" failure https://github.com/org/broken.git
add_project "$home" healthy https://github.com/org/healthy.git
printf 'code: NOT_FOUND\n' > "$home/responses/org--hidden.failure"
printf 'code: AUTH_REQUIRED\nerror: credentials missing\n' > "$home/responses/org--broken.failure"
write_issue "$home" org/healthy
rc=0
out=$(run_check "$home" "$NOW" 2>&1) || rc=$?
expect_code 1 "$rc" 'credential failure is nonzero'
assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 'failure prints exactly one line'
assert_contains "$out" 'GitHub listing failed for org/broken' 'failure names the affected repository'
assert_contains "$out" 'AUTH_REQUIRED' 'the credential failure code is visible in the single wake line'
assert_not_contains "$out" 'org/hidden' 'an unreadable repo is skipped'
assert_equals 1 "$(notes "$home")" 'a failing repo does not prevent healthy intake'
assert_equals 3 "$(wc -l < "$home/calls" | tr -d ' ')" 'failures do not trigger additional GitHub requests'
run_check "$home" "$((NOW + 10))"
assert_equals 3 "$(wc -l < "$home/calls" | tr -d ' ')" 'a failed sweep is throttled too'
rm "$home/responses/org--broken.failure"
printf '[]\n' > "$home/responses/org--broken.json"
run_check "$home" "$((NOW + 3600))"
touch "$home/responses/org--healthy.malformed"
rc=0
out=$(run_check "$home" "$((NOW + 7200))" 2>&1) || rc=$?
expect_code 1 "$rc" 'malformed response is not a healthy empty poll'
assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 'malformed-response failure is one line'
assert_contains "$out" 'invalid GitHub listing' 'malformed-response cause is visible'
pass 'unreadable repos skip while real API and response failures remain visible'

home=$(make_home timeout)
add_project "$home" slow https://github.com/org/slow.git
printf '[]\n' > "$home/responses/org--slow.json"
printf '5\n' > "$home/responses/org--slow.delay"
rc=0
out=$(run_check "$home" "$NOW" FM_CHECK_TIMEOUT=8 2>&1) || rc=$?
expect_code 1 "$rc" 'a bounded GitHub timeout fails'
assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 'timeout has a single failure line'
assert_contains "$out" 'exit 124' 'timeout is explicit'
pass 'GitHub probes respect the watcher budget and timeouts wake firstmate'

home=$(make_home lifecycle)
assert_equals '' "$(run_action "$home" arm --if-armed)" 'bootstrap does not opt a new home in'
assert_absent "$home/state/issue-triage.check.sh" 'no unrequested check is created'
run_action "$home" arm >/dev/null
registered "$home" || fail 'arm must bind the shim bytes'
cp "$home/state/issue-triage.check.sh" "$home/first-shim"
run_action "$home" arm --if-armed >/dev/null
cmp -s "$home/first-shim" "$home/state/issue-triage.check.sh" || fail 'shim bytes must be stable'
printf '# drift\n' >> "$home/state/issue-triage.check.sh"
rc=0
out=$(run_action "$home" arm --if-armed 2>&1) || rc=$?
expect_code 1 "$rc" 'bootstrap refuses to bless an untrusted check'
assert_contains "$out" 'not trusted' 'trust refusal is visible'
run_action "$home" arm >/dev/null
printf '{}\n' > "$home/state/.issue-triage"
run_action "$home" disarm >/dev/null
assert_absent "$home/state/issue-triage.check.sh" 'disarm removes the shim'
assert_absent "$home/state/issue-triage.check-trust" 'disarm removes the trust binding'
assert_absent "$home/state/.issue-triage" 'disarm removes the ledger'
run_action "$home" arm --if-armed
assert_absent "$home/state/issue-triage.check.sh" 'bootstrap does not undo disarm'
ln -s "$home/first-shim" "$home/state/issue-triage.check.sh"
rc=0
out=$(run_action "$home" arm 2>&1) || rc=$?
expect_code 1 "$rc" 'arm refuses a symlink destination'
assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 'unsafe destination failure is one line'
cmp -s "$home/first-shim" "$home/state/issue-triage.check.sh" || fail 'arm must not change the symlink target'
pass 'trusted static activation, refresh, disarm, and destination guards work locally'

home=$(make_home registration-failure)
run_action "$home" arm >/dev/null
cp "$home/state/issue-triage.check.sh" "$home/original-shim"
toolbelt="$home/toolbelt"
mkdir -p "$toolbelt"
for script in fm-issue-triage.sh fm-pr-lib.sh fm-check-lib.sh fm-timeout-lib.sh fm-wake-lib.sh fm-path-lib.sh; do
  cp "$ROOT/bin/$script" "$toolbelt/$script"
done
printf '#!/usr/bin/env bash\nexit 1\n' > "$toolbelt/fm-check-register.sh"
chmod +x "$toolbelt/fm-check-register.sh"
rc=0
out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  bash "$toolbelt/fm-issue-triage.sh" arm 2>&1) || rc=$?
expect_code 1 "$rc" 'registration failure refuses arm'
assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 'registration failure is one line'
cmp -s "$home/original-shim" "$home/state/issue-triage.check.sh" || fail 'failed re-arm must restore the previously trusted shim'
registered "$home" || fail 'failed re-arm must preserve the previous working trust binding'
run_action "$home" disarm >/dev/null
rc=0
out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  bash "$toolbelt/fm-issue-triage.sh" arm 2>&1) || rc=$?
expect_code 1 "$rc" 'first registration failure refuses arm'
assert_absent "$home/state/issue-triage.check.sh" 'failed first arm must not leave an untrusted shim for the watcher'
pass 'failed registration restores working activation or removes an unbound first shim'
