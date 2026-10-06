#!/usr/bin/env bash
set -euo pipefail

# Restore the pre-test disabled shell.json snapshot and restart only Omarchy's
# shell. This deliberately does not remove the installed plugin or backend.
BACKUP=${RAZER_ROLLBACK_BACKUP:-}
CONFIG="${HOME}/.config/omarchy/shell.json"

if [[ -z "$BACKUP" || ! -f "$BACKUP" || ! -r "$BACKUP" ]]; then
  echo "Set RAZER_ROLLBACK_BACKUP to the intended readable shell.json.disabled snapshot." >&2
  exit 1
fi

# Refuse to restore anything except the expected disabled snapshot.
jq -e '
  (.plugins | type == "array") and
  (.bar.layout.right | type == "array") and
  ([.plugins[]? | select(.id == "xianbei233.razer-control")] | length == 0) and
  ([.bar.layout.right[]? | select(.id == "xianbei233.razer-control")] | length == 0)
' "$BACKUP" >/dev/null || {
  echo "Rollback backup is not a valid Razer-disabled shell config: $BACKUP" >&2
  exit 1
}

tmp="$(mktemp "${CONFIG}.rollback.XXXXXX")"
cleanup() { rm -f -- "$tmp"; }
trap cleanup EXIT
cp -p -- "$BACKUP" "$tmp"
jq -e '
  ([.plugins[]? | select(.id == "xianbei233.razer-control")] | length == 0) and
  ([.bar.layout.right[]? | select(.id == "xianbei233.razer-control")] | length == 0)
' "$tmp" >/dev/null
mv -f -- "$tmp" "$CONFIG"
trap - EXIT

omarchy restart shell
