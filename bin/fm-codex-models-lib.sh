#!/usr/bin/env bash
# Codex catalog capability reader shared by spawn, dispatch validation, and
# account selection.
# Usage: source this file, then call
#   fm_codex_max_models [codex-home]     for a JSON slug array of max-capable models
#   fm_codex_catalog_models [codex-home] for every advertised slug, one per line
# Both read models_cache.json in the supplied account store, defaulting to
# ${CODEX_HOME:-$HOME/.codex}, the installed Codex catalog. An exact slug
# advertises max through supported_reasoning_levels[].effort.
# Missing, unreadable, or malformed catalogs establish no max capability ([]).
# fm_codex_catalog_models lists every model object's slug, hidden ones included,
# sorted and de-duplicated; a slug carrying a control character is not listed.
# It exits 1 with no output for a missing, unreadable, or malformed catalog (or
# no jq), so a caller can tell "catalog absent" from "model absent"; a valid
# catalog listing no models exits 0 with no output.
# No model-name fallback or network refresh, and nothing is ever written,
# created, or cached; ultra is never authorized here.

fm_codex_max_models() {
  local catalog="${1:-${CODEX_HOME:-$HOME/.codex}}/models_cache.json" models
  if [ -f "$catalog" ] && [ -r "$catalog" ] && command -v jq >/dev/null 2>&1; then
    models=$(jq -ces '
      if length != 1 or (.[0].models | type) != "array" then error("invalid catalog")
      else [.[0].models[] | select(type == "object")
        | select((.slug | type) == "string" and (.slug | length) > 0)
        | select((.supported_reasoning_levels | type) == "array")
        | select(any(.supported_reasoning_levels[]; type == "object" and .effort == "max"))
        | .slug] | unique
      end
    ' "$catalog" 2>/dev/null) && { printf '%s\n' "$models"; return 0; }
  fi
  printf '[]\n'
}

fm_codex_catalog_models() {
  local catalog="${1:-${CODEX_HOME:-$HOME/.codex}}/models_cache.json" models
  [ -f "$catalog" ] && [ -r "$catalog" ] && command -v jq >/dev/null 2>&1 || return 1
  models=$(jq -rs '
    if length != 1 or (.[0].models | type) != "array" then error("invalid catalog")
    else [.[0].models[] | select(type == "object")
      | select((.slug | type) == "string" and (.slug | length) > 0)
      | select(all(.slug | explode[]; . >= 32 and . != 127))
      | .slug] | unique | .[]
    end
  ' "$catalog" 2>/dev/null) || return 1
  [ -z "$models" ] || printf '%s\n' "$models"
}
