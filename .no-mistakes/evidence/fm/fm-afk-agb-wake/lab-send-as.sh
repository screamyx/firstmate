#!/usr/bin/env bash
# send-as.sh <sender-name> <message> : a real headless Claude session named
# <sender-name> delivers <message> verbatim to fm-lab-primary over SendMessage.
LAB=/tmp/fm-lab.Zp4Mdz; name=$1; msg=$2
cd "$LAB/sender" || exit 1
UNSETS=$(env | grep -oE '^(CLAUDE[A-Z0-9_]*|AGB_[A-Z0-9_]*|HERDR_[A-Z0-9_]*|LUVUS_[A-Z0-9_]*|AGUI_[A-Z0-9_]*|TMUX|TMUX_PANE|NO_MISTAKES_[A-Z0-9_]*|FM_[A-Z0-9_]*)=' | tr -d = | sed 's/^/-u /' | tr '\n' ' ')
printf '%s\n' "$msg" > "$LAB/sender/msg.txt"
exec timeout 300 env $UNSETS claude -p -n "$name" --dangerously-skip-permissions --model sonnet \
  "You are a delivery relay. Load the tools with ToolSearch select:SendMessage,ListAgents, then call SendMessage once with to='fm-lab-primary' and message set to the exact contents of the file $LAB/sender/msg.txt (read it with the Read tool; send it verbatim, without the trailing newline, nothing added or removed). Then stop. Do nothing else."
