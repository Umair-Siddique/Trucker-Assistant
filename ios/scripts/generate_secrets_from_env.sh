#!/bin/sh
# Reads project-root .env and writes Flutter xcconfig for Info.plist substitution.
set -e
ENV_FILE="${SRCROOT}/../.env"
OUT_FILE="${SRCROOT}/Flutter/GeneratedSecrets.xcconfig"
if [ -f "$ENV_FILE" ]; then
  LINE=$(grep -E '^GOOGLE_MAPS_API_KEY=' "$ENV_FILE" | tail -1 || true)
  VAL=${LINE#GOOGLE_MAPS_API_KEY=}
  VAL=$(printf '%s' "$VAL" | sed 's/^"//;s/"$//')
  VAL=$(printf '%s' "$VAL" | sed "s/^'//;s/'$//")
  printf 'GOOGLE_MAPS_API_KEY=%s\n' "$VAL" > "$OUT_FILE"
else
  echo "GOOGLE_MAPS_API_KEY=" > "$OUT_FILE"
fi
