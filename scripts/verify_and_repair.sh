#!/bin/bash
# scripts/verify_and_repair.sh
# Run from the repo root, right after a (possibly watchdog-stopped) build
# step, before checkpointing. Runs `codesign --verify --deep --strict=all`
# on every .framework/.xpc/.app directly under wk/WebKitBuild/Debug, and
# removes any that fail verification, so a later phase does a clean
# rebuild of just that one piece instead of silently trusting a file that
# was caught mid-write when THIS phase's own watchdog fired.
set -u

ok=0
repaired=0

while IFS= read -r -d '' bundle; do
  if codesign --verify --deep --strict=all "$bundle" >/dev/null 2>&1; then
    ok=$((ok + 1))
  else
    echo "::warning::$bundle failed codesign verification -- removing so the next phase relinks it"
    rm -rf "$bundle"
    repaired=$((repaired + 1))
  fi
done < <(find wk/WebKitBuild/Debug -maxdepth 1 \( -name "*.framework" -o -name "*.xpc" -o -name "*.app" \) -print0 2>/dev/null)

echo "Verify & repair finished: $(date -u +%FT%TZ) -- ${ok} OK, ${repaired} repaired"
