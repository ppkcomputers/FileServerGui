#!/bin/sh

# Resolve directory of this script using standard POSIX methods
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QML_FILE="${SCRIPT_DIR}/server-gui.qml"

# Move process execution into the script directory
cd "$SCRIPT_DIR" || exit 1

if pgrep -f "quickshell.*${QML_FILE}" >/dev/null; then
    pkill -f "quickshell.*${QML_FILE}"
else
    # Disown the process so it detaches cleanly from the shortcut runner
    nohup quickshell -p "${QML_FILE}" >/dev/null 2>&1 &
fi
