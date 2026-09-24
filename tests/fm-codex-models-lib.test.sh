#!/usr/bin/env bash
# Behavior tests for bin/fm-codex-models-lib.sh, the Codex catalog capability
# reader. Each case writes a throwaway store holding its own models_cache.json
# and calls the sourced functions the way spawn, dispatch validation, and
# account selection do.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-codex-models-lib.sh
. "$ROOT/bin/fm-codex-models-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-models-lib)

catalog_store() {  # <name> <catalog-json|missing>
  local store="$TMP_ROOT/$1"
  mkdir -p "$store"
  [ "$2" = missing ] || printf '%s\n' "$2" > "$store/models_cache.json"
  printf '%s\n' "$store"
}

store_listing() {  # <store>
  find "$1" -print | sort
  find "$1" -type f -exec cksum {} + | sort
}

CATALOG='{"models":[
  {"slug":"gpt-6-sol","visibility":"list","supported_reasoning_levels":[{"effort":"max"}]},
  {"slug":"gpt-6-luna","visibility":"list","supported_reasoning_levels":[{"effort":"xhigh"}]},
  {"slug":"gpt-reserve","visibility":"hide"},
  {"slug":"gpt-6-luna"},
  {"slug":""},
  {"slug":"bad\nslug"},
  7
]}'

test_catalog_with_the_model_lists_it() {
  local store out status
  store=$(catalog_store with-model "$CATALOG")
  out=$(fm_codex_catalog_models "$store")
  status=$?
  expect_code 0 "$status" "a readable catalog should list its models"
  [ "$out" = $'gpt-6-luna\ngpt-6-sol\ngpt-reserve' ] ||
    fail "the catalog was not listed one sorted, de-duplicated slug per line with hidden entries kept: $out"
  printf '%s\n' "$out" | grep -Fxq gpt-6-sol || fail "the advertised model was not listed: $out"
  pass "a catalog advertising the model lists every slug, hidden ones included, in sorted order"
}

test_catalog_without_the_model_omits_it() {
  local store out status
  store=$(catalog_store without-model '{"models":[{"slug":"gpt-6-luna"},{"slug":"gpt-5.5"}]}')
  out=$(fm_codex_catalog_models "$store")
  status=$?
  expect_code 0 "$status" "a readable catalog lacking the model is still evidence"
  [ "$out" = $'gpt-5.5\ngpt-6-luna' ] || fail "the readable catalog was not listed: $out"
  if printf '%s\n' "$out" | grep -Fxq gpt-6-sol; then
    fail "a catalog without the model listed it: $out"
  fi

  store=$(catalog_store empty '{"models":[]}')
  out=$(fm_codex_catalog_models "$store")
  status=$?
  expect_code 0 "$status" "a valid catalog listing no models is readable"
  [ -z "$out" ] || fail "an empty catalog printed output: $out"
  pass "a readable catalog without the model exits 0 and omits it"
}

test_missing_or_malformed_catalog_exits_one_silently() {
  local store out status label
  for label in missing not-json wrong-shape two-documents empty-file; do
    case "$label" in
      missing) store=$(catalog_store "$label" missing) ;;
      not-json) store=$(catalog_store "$label" 'not json') ;;
      wrong-shape) store=$(catalog_store "$label" '{"models":{"slug":"gpt-6-sol"}}') ;;
      two-documents) store=$(catalog_store "$label" $'{"models":[]}\n{"models":[]}') ;;
      empty-file) store=$(catalog_store "$label" missing); : > "$store/models_cache.json" ;;
    esac
    out=$(fm_codex_catalog_models "$store")
    status=$?
    expect_code 1 "$status" "a $label catalog must report no evidence"
    [ -z "$out" ] || fail "a $label catalog printed output: $out"
  done

  store=$(catalog_store unreadable "$CATALOG")
  chmod 000 "$store/models_cache.json"
  if [ ! -r "$store/models_cache.json" ]; then
    out=$(fm_codex_catalog_models "$store")
    status=$?
    expect_code 1 "$status" "an unreadable catalog must report no evidence"
    [ -z "$out" ] || fail "an unreadable catalog printed output: $out"
  fi
  chmod 600 "$store/models_cache.json"
  pass "a missing, unreadable, or malformed catalog exits 1 with no output"
}

test_catalog_defaults_to_the_ambient_codex_home() {
  local store out
  store=$(catalog_store ambient '{"models":[{"slug":"gpt-6-astra"}]}')
  out=$(CODEX_HOME="$store" fm_codex_catalog_models) || fail "the ambient catalog was not read"
  [ "$out" = gpt-6-astra ] || fail "the ambient catalog was not listed: $out"
  pass "with no store argument the catalog comes from CODEX_HOME"
}

test_catalog_read_writes_nothing() {
  local store before after
  store=$(catalog_store read-only "$CATALOG")
  mkdir -p "$TMP_ROOT/no-catalog"
  before=$(store_listing "$store"; store_listing "$TMP_ROOT/no-catalog")
  fm_codex_catalog_models "$store" >/dev/null
  fm_codex_catalog_models "$TMP_ROOT/no-catalog" >/dev/null
  after=$(store_listing "$store"; store_listing "$TMP_ROOT/no-catalog")
  [ "$before" = "$after" ] || fail "reading a catalog changed the store: $before -> $after"
  pass "reading a catalog never writes, creates, or caches anything"
}

test_max_models_is_unchanged() {
  local store out
  store=$(catalog_store max "$CATALOG")
  out=$(fm_codex_max_models "$store")
  [ "$out" = '["gpt-6-sol"]' ] || fail "max capability changed for a readable catalog: $out"
  store=$(catalog_store max-missing missing)
  out=$(fm_codex_max_models "$store")
  [ "$out" = '[]' ] || fail "max capability changed for a missing catalog: $out"
  store=$(catalog_store max-malformed 'not json')
  out=$(fm_codex_max_models "$store")
  [ "$out" = '[]' ] || fail "max capability changed for a malformed catalog: $out"
  pass "max capability still prints a JSON array and [] without a readable catalog"
}

test_catalog_with_the_model_lists_it
test_catalog_without_the_model_omits_it
test_missing_or_malformed_catalog_exits_one_silently
test_catalog_defaults_to_the_ambient_codex_home
test_catalog_read_writes_nothing
test_max_models_is_unchanged

printf '%s\n' '# all fm-codex-models-lib tests passed'
