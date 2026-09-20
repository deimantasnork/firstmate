#!/usr/bin/env bash
# Codex catalog capability reader shared by spawn and dispatch validation.
# Usage: source this file, then call fm_codex_max_models [codex-home] for a JSON slug array.
# Reads models_cache.json in the supplied account store, defaulting to
# ${CODEX_HOME:-$HOME/.codex}, the installed Codex catalog. An exact slug
# advertises max through supported_reasoning_levels[].effort.
# Missing, unreadable, or malformed catalogs establish no max capability ([]).
# No model-name fallback or network refresh; ultra is never authorized here.

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
