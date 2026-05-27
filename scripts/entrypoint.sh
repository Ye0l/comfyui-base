#!/usr/bin/env bash
set -euo pipefail

ORIGINAL_START="/start.sh"
PATCHED_START="/tmp/start.patched.sh"
CUSTOM_HOOK=""

if [ -n "${CUSTOM_SCRIPT_URL:-}" ]; then
  echo "[entrypoint] fetching custom hook from $CUSTOM_SCRIPT_URL"
  CUSTOM_HOOK="/tmp/custom-hook.sh"
  if curl -sSL "$CUSTOM_SCRIPT_URL" -o "$CUSTOM_HOOK"; then
    chmod +x "$CUSTOM_HOOK"
  else
    echo "[entrypoint] ERROR: failed to fetch custom hook from $CUSTOM_SCRIPT_URL" >&2
    exit 1
  fi
elif [ -x "/custom-before-comfyui.sh" ]; then
  echo "[entrypoint] using local custom hook: /custom-before-comfyui.sh"
  CUSTOM_HOOK="/custom-before-comfyui.sh"
else
  echo "[entrypoint] no custom hook found (URL not set and local script missing)"
fi

if [ ! -f "$ORIGINAL_START" ]; then
  echo "[entrypoint] ERROR: $ORIGINAL_START not found" >&2
  exit 1
fi

if [ -n "$CUSTOM_HOOK" ] && [ -x "$CUSTOM_HOOK" ]; then
  echo "[entrypoint] patching /start.sh with hook: $CUSTOM_HOOK"
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
else
  echo "[entrypoint] starting without custom hook"
  exec "$ORIGINAL_START"
fi
