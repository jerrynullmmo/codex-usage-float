#!/bin/zsh
set -eu
app="$1"
config="$HOME/Library/Application Support/Codex Usage Float/local-signing-identity.txt"
identity="${USAGE_SIGNING_IDENTITY-}"
if [[ -z "$identity" && -f "$config" ]]; then
  identity="$(<"$config")"
fi
identity="${identity:--}"
codesign --force --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
