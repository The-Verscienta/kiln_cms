#!/usr/bin/env bash
#
# summarize.sh — a Markdown table of upgrade rehearsal results (#1540).
#
#   scripts/upgrade_rehearsal/summarize.sh WORK_DIR
#
# Reads every WORK_DIR/rehearse_*/result.json that rehearse.sh wrote.

set -euo pipefail

WORK="${1:?usage: summarize.sh WORK_DIR}"

echo "| From | Result | Time | Overlay | Upgrade notes printed (→ final) | Problems |"
echo "|---|---|---|---|---|---|"

for result in $(ls "$WORK"/rehearse_*/result.json 2>/dev/null | sort -V); do
  jq -r '
    def mins: (. / 60 | floor | tostring) + "m" + (. % 60 | tostring | if length < 2 then "0" + . else . end) + "s";
    "| \(.from) → \(.rc_tag) | \(if .status == "pass" then "✅ pass" else "❌ fail" end) | \(.seconds | mins) | \(.overlay) | \(if (.notes_printed | length) == 0 then "none" else (.notes_printed | join(", ")) end)\(if .notes_printed == .notes_expected then "" else " (expected \(.notes_expected | join(", ")))" end) | \(if (.problems | length) == 0 then "—" else (.problems | map(gsub("\\|"; "\\\\|")) | join("<br>")) end) |"
  ' "$result"
done
