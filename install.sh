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
# Claude Code SessionEnd hook: start `hq gc --apply` fully detached so exit is
# never delayed. Merged beside existing SessionEnd hooks; rerunning replaces it.
claude_settings=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json
gc_hook=$(printf 'setsid -f %q gc --apply >/dev/null 2>&1 </dev/null' "$HOME/.local/bin/hq")
mkdir -p -- "${claude_settings%/*}"
claude_temp=$(mktemp "$claude_settings.XXXXXX")
trap 'rm -f -- "$temp" "$claude_temp"' EXIT
if [[ -f $claude_settings ]]; then
  cp -p -- "$claude_settings" "$claude_temp"
  jq --arg cmd "$gc_hook" 'if type != "object" then error("settings must be an object") else
    .hooks.SessionEnd = ([(.hooks.SessionEnd // [])[]
      | .hooks |= map(select((.command // "") | test("hq gc --apply") | not))
      | select(.hooks | length > 0)] + [{hooks:[{type:"command",command:$cmd,timeout:1}]}]) end' \
    "$claude_settings" >"$claude_temp"
else
  jq -n --arg cmd "$gc_hook" '{hooks:{SessionEnd:[{hooks:[{type:"command",command:$cmd,timeout:1}]}]}}' >"$claude_temp"
fi
mv -- "$claude_temp" "$claude_settings"
printf 'Installed ~/.local/bin/hq; memory configured in repo settings.\n'
printf 'Claude SessionEnd hook runs hq gc --apply (detached) in %s.\n' "$claude_settings"
printf 'Configure ~/.config/claude-hq/config.env and add ~/.local/bin to PATH.\n'
printf '\nOptional janitor timer (not enabled by this installer):\n'
printf 'mkdir -p ~/.config/systemd/user\n'
printf 'cp %q/systemd/claude-hq-janitor.{service,timer} ~/.config/systemd/user/\n' "$repo"
printf '# Adjust WorkingDirectory and ExecStart in the copied service if needed.\n'
printf 'systemctl --user daemon-reload\n'
printf 'systemctl --user enable --now claude-hq-janitor.timer\n'
printf '\nSuggested user setting: "cleanupPeriodDays": 14 in ~/.claude/settings.json (edit it yourself).\n'
