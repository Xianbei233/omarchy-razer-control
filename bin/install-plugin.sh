#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONFIG_HOME=${XDG_CONFIG_HOME:-"$HOME/.config"}
OMARCHY_CONFIG="$CONFIG_HOME/omarchy"
PLUGINS_DIR="$OMARCHY_CONFIG/plugins"
PLUGIN="$PLUGINS_DIR/xianbei233.razer-control"
SHELL_JSON="$OMARCHY_CONFIG/shell.json"
STATE_HOME=${XDG_STATE_HOME:-"$HOME/.local/state"}
BACKUP_ROOT="$STATE_HOME/omarchy-razer-control/plugin-backups"
BIN_DIR=${HOME:?}/.local/bin

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
[ -d "$ROOT/plugin" ] || { echo "plugin/ source is missing" >&2; exit 1; }

mkdir -p "$PLUGINS_DIR" "$BIN_DIR" "$BACKUP_ROOT"

# Old versions incorrectly put copies beneath plugins/, where the registry
# discovers their duplicate manifests. Archive only verified backups of this
# plugin, and never leave plugin backups in the registry scan root.
for old in "$PLUGINS_DIR"/xianbei233.razer-control.backup-*; do
    [ -e "$old" ] || continue
    if [ -L "$old" ] || [ ! -d "$old" ] || [ ! -f "$old/manifest.json" ] || \
       ! jq -e '.id == "xianbei233.razer-control"' "$old/manifest.json" >/dev/null 2>&1; then
        printf 'Leaving unverified backup untouched: %s\n' "$old" >&2
        continue
    fi
    archive=$(mktemp -d "$BACKUP_ROOT/xianbei233.razer-control.backup.XXXXXXXX")
    if ! mv -- "$old" "$archive/plugin"; then
        rmdir "$archive"
        echo "Unable to archive old plugin backup: $old" >&2
        exit 1
    fi
    printf 'Archived old plugin backup: %s -> %s\n' "$old" "$archive/plugin"
done

if [ -e "$PLUGIN" ]; then
    archive=$(mktemp -d "$BACKUP_ROOT/xianbei233.razer-control.XXXXXXXX")
    if ! mv -- "$PLUGIN" "$archive/plugin"; then
        rmdir "$archive"
        echo "Unable to archive existing plugin: $PLUGIN" >&2
        exit 1
    fi
    printf 'Archived existing plugin: %s\n' "$archive/plugin"
fi
mkdir -p "$PLUGIN"
cp -R "$ROOT/plugin/." "$PLUGIN/"
install -m 755 "$ROOT/target/release/omarchy-razer-control" "$BIN_DIR/omarchy-razer-control"

if [ -e "$SHELL_JSON" ]; then
    cp -p "$SHELL_JSON" "$SHELL_JSON.backup-$(date +%Y%m%d%H%M%S)-$$"
    jq 'if (.plugins|type) != "array" or (.bar.layout.right|type) != "array" then error("shell.json requires plugins[] and bar.layout.right[]") else
      .plugins = (if any(.plugins[]; .id == "xianbei233.razer-control") then .plugins else .plugins + [{"id":"xianbei233.razer-control"}] end) |
      .bar.layout.right = (if any(.bar.layout.right[]; .id == "xianbei233.razer-control") then .bar.layout.right else .bar.layout.right + [{"id":"xianbei233.razer-control"}] end)
    end' "$SHELL_JSON" > "$SHELL_JSON.tmp"
else
    echo 'shell.json missing: refusing to invent an Omarchy configuration' >&2
    exit 1
fi
mv "$SHELL_JSON.tmp" "$SHELL_JSON"
printf 'Installed user plugin at %s\n' "$PLUGIN"
printf '%s\n' 'No system files or udev rules were changed.'
