#!/usr/bin/env bash
# Lab-only recording shim for the agb CLI. Never contacts the real broker.
# Logs every call; `drain` emits the staged delivery once, `ack` snapshots the
# lab backlog so the log proves what was durable at ack time.
LAB=/tmp/fm-lab.Zp4Mdz
LOG="$LAB/agb-calls.log"
printf '%s argv: agb' "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" >> "$LOG"
printf ' %q' "$@" >> "$LOG"; printf '\n' >> "$LOG"
case "${1:-}" in
  drain)
    staged="$LAB/agb-staged-delivery"
    if [ -s "$staged" ]; then
      cat "$staged"
      mv "$staged" "$staged.drained.$(date +%s%N)"
    else
      echo "no mail"
    fi
    ;;
  ack)
    shift
    {
      echo "--- backlog at ack time ---"
      cat "$LAB/data/backlog.md" 2>/dev/null || echo "(no backlog file)"
      echo "--- end backlog ---"
    } >> "$LOG"
    for id in "$@"; do case "$id" in --*) ;; *) echo "acked $id" ;; esac; done
    ;;
  who|help|--help|"")
    echo "agb (lab shim): only drain and ack are available in this lab" ;;
  *)
    echo "agb (lab shim): '$1' is not available in this lab" >&2; exit 1 ;;
esac
