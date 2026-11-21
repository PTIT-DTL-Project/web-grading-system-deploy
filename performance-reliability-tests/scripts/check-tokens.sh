#!/usr/bin/env bash
# Preflight for multi-VU k6 profiles: verify the configured token file before a
# load run. Prints only derived facts (index, expiry, issuer, roles) so the token
# values never reach the terminal or the run artifacts.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$TEST_ROOT/.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

: "${TOKENS_FILE:?Set TOKENS_FILE (relative to k6/) to a JSON array of test tokens}"

token_file="$TEST_ROOT/k6/$TOKENS_FILE"
if [[ ! -f "$token_file" ]]; then
  echo "TOKENS_FILE not found at $token_file (paths resolve from k6/, as in k6 open())." >&2
  exit 2
fi

python3 - "$token_file" <<'PY'
import base64
import json
import sys
import time
from datetime import datetime, timezone

try:
    tokens = json.loads(open(sys.argv[1], encoding="utf-8").read())
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"Cannot read token file as JSON: {exc.__class__.__name__}")
if not isinstance(tokens, list) or not tokens:
    raise SystemExit("Token file must be a non-empty JSON array of strings.")

now = int(time.time())
problems = 0
seen = set()


def claims_of(token):
    parts = token.split(".")
    if len(parts) != 3:
        return None
    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    try:
        decoded = json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        return None
    return decoded if isinstance(decoded, dict) else None

for index, entry in enumerate(tokens, 1):
    if isinstance(entry, str):
        token, refresh = entry.strip(), ""
    elif isinstance(entry, dict):
        token = entry.get("access_token", "").strip() if isinstance(entry.get("access_token"), str) else ""
        refresh = entry.get("refresh_token", "").strip() if isinstance(entry.get("refresh_token"), str) else ""
    else:
        print(f"token[{index}]: INVALID (entry must be a string or an object with access_token/refresh_token)")
        problems += 1
        continue

    if not token:
        print(f"token[{index}]: INVALID (empty access token)")
        problems += 1
        continue
    if token.lower().startswith("bearer "):
        print(f"token[{index}]: INVALID (remove the 'Bearer ' prefix)")
        problems += 1
        continue
    if token in seen:
        print(f"token[{index}]: DUPLICATE (each VU needs a distinct student token)")
        problems += 1
        continue
    seen.add(token)

    parts = token.split(".")
    if len(parts) != 3:
        print(f"token[{index}]: INVALID (not a JWT)")
        problems += 1
        continue
    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    try:
        claims = json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        print(f"token[{index}]: INVALID (payload is not decodable JSON)")
        problems += 1
        continue

    exp = claims.get("exp")
    if not isinstance(exp, (int, float)):
        print(f"token[{index}]: INVALID (no exp claim)")
        problems += 1
        continue

    # A refresh token outlives the access token, and the k6 scripts exchange it
    # automatically, so an expired access token is still usable when the refresh
    # token is valid. Only a missing/expired refresh token blocks the run.
    refresh_exp = None
    if refresh:
        refresh_claims = claims_of(refresh)
        if refresh_claims and isinstance(refresh_claims.get("exp"), (int, float)):
            refresh_exp = refresh_claims["exp"]
    refresh_usable = bool(refresh) and (refresh_exp is None or refresh_exp > now + 60)

    remaining_min = int((exp - now) // 60)
    expires_at = datetime.fromtimestamp(exp, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if exp > now and remaining_min >= 10:
        state = "OK"
    elif refresh_usable:
        state = "REFRESHABLE"
    elif exp <= now:
        state = "EXPIRED"
        problems += 1
    else:
        state = "EXPIRES_SOON"
        problems += 1

    roles = claims.get("realm_access", {}).get("roles", [])
    roles = [r for r in roles if r in ("STUDENT", "LECTURER", "ADMIN")] if isinstance(roles, list) else []
    print(
        f"token[{index}]: {state} exp={expires_at} remaining={remaining_min}min "
        f"issuer={claims.get('iss', '?')} roles={roles or '?'} refresh={'yes' if refresh else 'no'}"
    )
    if not refresh:
        print(f"token[{index}]: NO_REFRESH_TOKEN (a run longer than the access-token lifetime will fail with 401)")
    elif not refresh_usable:
        print(f"token[{index}]: REFRESH_EXPIRED (log in again for this test student)")
        problems += 1

print()
print(f"tokens={len(tokens)} problems={problems}")
if problems:
    print("Fix every EXPIRED/EXPIRES_SOON/INVALID/REFRESH_EXPIRED entry by logging in again for that test student, then rerun.")
raise SystemExit(1 if problems else 0)
PY
