#!/usr/bin/env bash
set -euo pipefail
command -v jq >/dev/null || { printf 'install: jq is required\n' >&2; exit 1; }
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
config_dir=${XDG_CONFIG_HOME:-$HOME/.config}/claude-hq
mkdir -p -- "$HOME/.local/bin" "$config_dir" "$repo/.claude"
ln -sfn -- "$repo/bin/hq" "$HOME/.local/bin/hq"
settings=$repo/.claude/settings.local.json
temp=$(mktemp "$repo/.claude/settings.local.json.XXXXXX")
trap 'rm -f -- "$temp"' EXIT
if [[ -f $settings ]]; then
  jq --arg memory "$repo/memory" 'if type != "object" then error("settings must be an object") else . + {autoMemoryDirectory:$memory} end' "$settings" >"$temp"
else
  jq -n --arg memory "$repo/memory" '{autoMemoryDirectory:$memory}' >"$temp"
fi
chmod 600 "$temp"
mv -- "$temp" "$settings"
if [[ ! -e $config_dir/config.env ]]; then
  (umask 077; cp -- "$repo/config.example.env" "$config_dir/config.env")
fi
printf 'Installed ~/.local/bin/hq; memory configured in repo settings.\n'
printf 'Configure ~/.config/claude-hq/config.env and add ~/.local/bin to PATH.\n'
