#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-skills.sh, which links the shared skills
# under $HOME/.agents/skills into the Claude store a claude launch selected.
# tests/fm-worker-account.test.sh and tests/fm-spawn-dispatch-profile.test.sh
# prove the spawn passes the selected store and no other.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-skills)
SKILLS="$ROOT/bin/fm-claude-skills.sh"

# new_case <name>: an isolated HOME and an absent Claude store. Sets CASE,
# USER_HOME, SHARED, and STORE.
new_case() {
  CASE="$TMP_ROOT/$1"
  USER_HOME="$CASE/home"
  SHARED="$USER_HOME/.agents/skills"
  STORE="$CASE/claude-store"
  mkdir -p "$USER_HOME"
}

# shared_skill <name>: one shared skill directory holding a SKILL.md.
shared_skill() {
  mkdir -p "$SHARED/$1"
  printf 'name: %s\n' "$1" > "$SHARED/$1/SKILL.md"
}

run_skills() {
  HOME="$USER_HOME" "$SKILLS" "$@" 2>&1
}

test_absent_entries_are_linked_to_the_shared_skill() {
  local out rc
  new_case absent
  shared_skill no-mistakes
  shared_skill quota-axi
  out=$(run_skills "$STORE"); rc=$?
  expect_code 0 "$rc" "linking into a store with no skills directory should succeed: $out"
  assert_equals "$SHARED/no-mistakes" "$(readlink "$STORE/skills/no-mistakes")" \
    "an absent entry should become a link to the shared skill"
  assert_equals "$SHARED/quota-axi" "$(readlink "$STORE/skills/quota-axi")" \
    "every absent shared skill should be linked"
  assert_grep 'name: no-mistakes' "$STORE/skills/no-mistakes/SKILL.md" \
    "the linked skill should read through to the shared SKILL.md"
  assert_contains "$out" "linked $STORE/skills/no-mistakes -> $SHARED/no-mistakes" \
    "the helper should name each link it made"
  out=$(run_skills "$STORE"); rc=$?
  expect_code 0 "$rc" "a repeat run should succeed"
  assert_equals "" "$out" "a repeat run with nothing missing should print nothing"
  pass "absent entries are linked to the shared skill, and a repeat run changes nothing"
}

test_existing_entries_are_left_untouched() {
  local out rc
  new_case existing
  for name in own-dir own-file own-link dangling missing; do
    shared_skill "$name"
  done
  mkdir -p "$STORE/skills/own-dir" "$CASE/elsewhere"
  printf 'store-local copy\n' > "$STORE/skills/own-dir/SKILL.md"
  printf 'a file\n' > "$STORE/skills/own-file"
  ln -s "$CASE/elsewhere" "$STORE/skills/own-link"
  ln -s "$CASE/no-such-target" "$STORE/skills/dangling"
  out=$(run_skills "$STORE"); rc=$?
  expect_code 0 "$rc" "a store with existing entries should succeed: $out"
  [ -d "$STORE/skills/own-dir" ] && [ ! -L "$STORE/skills/own-dir" ] \
    || fail "an existing skill directory must stay a real directory"
  assert_grep 'store-local copy' "$STORE/skills/own-dir/SKILL.md" \
    "an existing skill directory's content must be untouched"
  [ -f "$STORE/skills/own-file" ] && [ ! -L "$STORE/skills/own-file" ] \
    || fail "an existing file entry must stay a regular file"
  assert_grep 'a file' "$STORE/skills/own-file" "an existing file entry's content must be untouched"
  assert_equals "$CASE/elsewhere" "$(readlink "$STORE/skills/own-link")" \
    "an existing link must keep its own target"
  assert_equals "$CASE/no-such-target" "$(readlink "$STORE/skills/dangling")" \
    "a dangling link must be left as it is, not replaced"
  assert_equals "$SHARED/missing" "$(readlink "$STORE/skills/missing")" \
    "the one absent entry should still be linked"
  assert_not_contains "$out" "own-" "no existing entry should be reported as linked"
  assert_not_contains "$out" "dangling" "a dangling link should not be reported as linked"
  pass "existing directories, files, links, and dangling links are left untouched"
}

test_only_skill_directories_are_linked() {
  local out rc
  new_case only-dirs
  shared_skill real-skill
  mkdir -p "$SHARED/.hidden"
  printf 'not a skill\n' > "$SHARED/README"
  out=$(run_skills "$STORE"); rc=$?
  expect_code 0 "$rc" "a shared directory with non-skill entries should succeed: $out"
  assert_present "$STORE/skills/real-skill" "the shared skill directory should be linked"
  [ ! -e "$STORE/skills/.hidden" ] && [ ! -L "$STORE/skills/.hidden" ] \
    || fail "a hidden shared entry must not be linked"
  [ ! -e "$STORE/skills/README" ] && [ ! -L "$STORE/skills/README" ] \
    || fail "a shared file must not be linked as a skill"
  pass "only non-hidden shared directories are linked"
}

test_no_shared_skills_is_a_no_op() {
  local out rc
  new_case no-shared
  out=$(run_skills "$STORE"); rc=$?
  expect_code 0 "$rc" "an absent shared directory should succeed"
  assert_equals "" "$out" "an absent shared directory should print nothing"
  assert_absent "$STORE" "an absent shared directory must not create the store"
  mkdir -p "$SHARED"
  out=$(run_skills "$STORE"); rc=$?
  expect_code 0 "$rc" "an empty shared directory should succeed"
  assert_absent "$STORE/skills" "an empty shared directory must not create a skills directory"
  pass "no shared skills leaves the store untouched"
}

test_unlinkable_store_fails_without_touching_it() {
  local out rc
  new_case unlinkable
  shared_skill no-mistakes
  mkdir -p "$STORE"
  printf 'not a directory\n' > "$STORE/skills"
  out=$(run_skills "$STORE"); rc=$?
  expect_code 1 "$rc" "a skills path that is not a directory should fail"
  assert_contains "$out" "no-mistakes" "the failure should name the skill it could not link"
  assert_grep 'not a directory' "$STORE/skills" "the store's own skills entry must be untouched"
  pass "a store that cannot hold the link fails, names the skill, and is left untouched"
}

test_usage_errors() {
  local out rc
  new_case usage
  shared_skill no-mistakes
  out=$(cd "$CASE" && run_skills relative/store); rc=$?
  expect_code 2 "$rc" "a relative store should be a usage error"
  assert_contains "$out" "not an absolute path" "the refusal should say why"
  assert_absent "$CASE/relative" "a relative store must not be written"
  out=$(run_skills); rc=$?
  expect_code 2 "$rc" "a missing store should be a usage error"
  pass "a relative or missing store is a usage error"
}

test_absent_entries_are_linked_to_the_shared_skill
test_existing_entries_are_left_untouched
test_only_skill_directories_are_linked
test_no_shared_skills_is_a_no_op
test_unlinkable_store_fails_without_touching_it
test_usage_errors

echo "# all fm-claude-skills tests passed"
