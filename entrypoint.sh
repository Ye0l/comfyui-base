#!/usr/bin/env bash
set -euo pipefail

echo "[entrypoint] patching /start.sh"

ORIGINAL_START="/start.sh"
PATCHED_START="/tmp/start.patched.sh"
CUSTOM_HOOK="/custom-before-comfyui.sh"

if [ ! -f "$ORIGINAL_START" ]; then
  echo "[entrypoint] ERROR: $ORIGINAL_START not found" >&2
  exit 1
fi

if [ ! -x "$CUSTOM_HOOK" ]; then
  echo "[entrypoint] ERROR: $CUSTOM_HOOK not executable" >&2
  exit 1
fi

awk -v hook="$CUSTOM_HOOK" '
BEGIN {
  inserted = 0
}

{
  if (!inserted && $0 ~ /^[[:space:]]*python[[:space:]]+main\.py[[:space:]]+\$FIXED_ARGS/) {
    print "echo \"[entrypoint] running custom hook before ComfyUI\""
    print hook
    print "echo \"[entrypoint] custom hook finished\""
    inserted = 1
  }

  print
}

END {
  if (!inserted) {
    print "[entrypoint] ERROR: could not find ComfyUI launch line in /start.sh" > "/dev/stderr"
    exit 42
  }
}
' "$ORIGINAL_START" > "$PATCHED_START"

chmod +x "$PATCHED_START"

echo "[entrypoint] patched start.sh ready"
exec "$PATCHED_START"
