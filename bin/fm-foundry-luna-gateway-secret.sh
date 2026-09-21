#!/usr/bin/env bash
# fm-foundry-luna-gateway-secret.sh - print the loopback gateway's admission
# secret on stdout only if that gateway is listening. Pi can use this as a
# models.json `!command` apiKey so it does not store an Azure key, and so a
# down gateway fails as an API-key resolve error that quotes this command
# rather than as a generic "Connection error."
#
# Never prints the secret to stderr. Requires FM_FOUNDRY_LUNA_SECRET_FILE
# (the exact admission bytes, no extra newline) and uses FM_FOUNDRY_LUNA_PORT
# (default 17653). Extra argv is ignored on success; Pi quotes the whole
# command on failure, so callers may pass a fail-reason token that names
# the down-gateway stage.
set -eu

PORT=${FM_FOUNDRY_LUNA_PORT:-17653}
SECRET_FILE=${FM_FOUNDRY_LUNA_SECRET_FILE:-}
HERE=$(cd "$(dirname "$0")" && pwd)

if [ -z "$SECRET_FILE" ]; then
  echo "fm-foundry-luna-gateway-secret: FM_FOUNDRY_LUNA_SECRET_FILE is not set" >&2
  exit 1
fi

if ! (echo >/dev/tcp/127.0.0.1/"$PORT") >/dev/null 2>&1; then
  python3 "$HERE/fm-foundry-luna-proxy.py" classify --gateway-down --port "$PORT" >&2 || true
  exit 1
fi

if [ ! -r "$SECRET_FILE" ]; then
  echo "fm-foundry-luna-gateway-secret: secret file is missing or unreadable" >&2
  exit 1
fi

# stdout is the admission secret. Strip a trailing newline so a 0600 file
# created with printf '%s\n' still matches the gateway's hmac value.
tr -d '\n' < "$SECRET_FILE"
