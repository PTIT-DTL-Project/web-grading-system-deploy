#!/usr/bin/env bash
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$TEST_ROOT/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing environment file: $ENV_FILE (copy .env.example to .env and configure staging)." >&2
  exit 2
fi

# The env file is operator-controlled local configuration; never enable shell tracing here.
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${BASE_URL:?Set BASE_URL to the isolated staging URL}"
: "${ASSIGNMENT_ID:?Set ASSIGNMENT_ID to a published staging assignment}"

if [[ "${TARGET_ENV:-}" != "staging" ]]; then
  echo "Refusing to run: set TARGET_ENV=staging only after verifying the target environment." >&2
  exit 2
fi
if [[ -z "${EXPECTED_STAGING_HOST:-}" ]]; then
  echo "Refusing to run: set EXPECTED_STAGING_HOST to the exact approved staging hostname." >&2
  exit 2
fi
if [[ "${RUN_CONFIRM:-}" != "I_CONFIRM_STAGING_TESTS" ]]; then
  echo "Refusing to run: set RUN_CONFIRM=I_CONFIRM_STAGING_TESTS after completing the staging checklist." >&2
  exit 2
fi

host="$(python3 - "$BASE_URL" <<'PY'
from urllib.parse import urlparse
import sys
url = urlparse(sys.argv[1])
if url.scheme not in {"http", "https"} or not url.hostname:
    raise SystemExit("BASE_URL must be an absolute http(s) URL.")
print(url.hostname.lower())
PY
)" || exit 2
if [[ "$host" != "${EXPECTED_STAGING_HOST,,}" ]]; then
  echo "Refusing BASE_URL host '$host'; it does not match EXPECTED_STAGING_HOST." >&2
  exit 2
fi
if [[ "$host" =~ (^|[.-])(prod|production)([.-]|$) ]]; then
  echo "Refusing production-like BASE_URL host: $host" >&2
  exit 2
fi

RUN_API_READ="${RUN_API_READ:-true}"
API_PROFILE="${API_PROFILE:-smoke}"
RUN_GRADING_SMOKE="${RUN_GRADING_SMOKE:-false}"
RUN_RECONCILIATION="${RUN_RECONCILIATION:-$RUN_GRADING_SMOKE}"
RUN_SELF_HEAL_TEST="${RUN_SELF_HEAL_TEST:-false}"

is_bool() { [[ "$1" == "true" || "$1" == "false" ]]; }
is_bool "$RUN_API_READ" || { echo "RUN_API_READ must be true or false." >&2; exit 2; }
is_bool "$RUN_GRADING_SMOKE" || { echo "RUN_GRADING_SMOKE must be true or false." >&2; exit 2; }
is_bool "$RUN_RECONCILIATION" || { echo "RUN_RECONCILIATION must be true or false." >&2; exit 2; }
is_bool "$RUN_SELF_HEAL_TEST" || { echo "RUN_SELF_HEAL_TEST must be true or false." >&2; exit 2; }
if [[ "$RUN_API_READ" == false && "$RUN_GRADING_SMOKE" == false && "$RUN_SELF_HEAL_TEST" == false ]]; then
  echo "Enable at least one test with RUN_API_READ, RUN_GRADING_SMOKE or RUN_SELF_HEAL_TEST." >&2
  exit 2
fi
if [[ "$RUN_RECONCILIATION" == true && "$RUN_GRADING_SMOKE" != true ]]; then
  echo "RUN_RECONCILIATION=true requires RUN_GRADING_SMOKE=true." >&2
  exit 2
fi
case "$API_PROFILE" in smoke|load|stress|spike) ;; *) echo "API_PROFILE must be smoke, load, stress or spike." >&2; exit 2 ;; esac
if [[ "$RUN_API_READ" == true || "$RUN_GRADING_SMOKE" == true ]] && ! command -v k6 >/dev/null 2>&1; then
  echo "k6 is required but was not found in PATH." >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to write the run report." >&2
  exit 2
fi
if [[ "$RUN_API_READ" == true || "$RUN_GRADING_SMOKE" == true ]]; then
  if [[ -z "${ACCESS_TOKEN:-}" && -z "${TOKENS_FILE:-}" ]]; then
    echo "Set ACCESS_TOKEN or TOKENS_FILE for k6 tests." >&2
    exit 2
  fi
  if [[ "$RUN_API_READ" == true && "$API_PROFILE" != smoke && -z "${TOKENS_FILE:-}" ]]; then
    echo "Multi-VU profiles require TOKENS_FILE with distinct test-student tokens." >&2
    exit 2
  fi
  if [[ -n "${TOKENS_FILE:-}" ]]; then
    token_file="$TEST_ROOT/k6/$TOKENS_FILE"
    if [[ ! -f "$token_file" ]]; then
      echo "TOKENS_FILE was not found relative to k6/ (as resolved by k6 open())." >&2
      exit 2
    fi
    required_tokens=1
    if [[ "$RUN_API_READ" == true ]]; then
      case "$API_PROFILE" in load) required_tokens=3 ;; stress|spike) required_tokens=5 ;; esac
    fi
    if ! REQUIRED_TOKENS="$required_tokens" python3 - "$token_file" <<'PY'
import json, os, sys


def access_token_of(entry):
    """Accept a bare token string or an {access_token, refresh_token} object."""
    if isinstance(entry, str):
        return entry.strip()
    if isinstance(entry, dict) and isinstance(entry.get("access_token"), str):
        return entry["access_token"].strip()
    return ""


try:
    tokens = json.loads(open(sys.argv[1], encoding="utf-8").read())
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)
required = int(os.environ["REQUIRED_TOKENS"])
if not isinstance(tokens, list):
    raise SystemExit(1)
access_tokens = [access_token_of(entry) for entry in tokens]
if len(access_tokens) < required or any(not token for token in access_tokens) or len(set(access_tokens)) != len(access_tokens):
    raise SystemExit(1)
PY
    then
      echo "TOKENS_FILE must contain at least $required_tokens distinct, non-empty tokens as a JSON array (token string or {access_token, refresh_token} object)." >&2
      exit 2
    fi
  fi
fi
if [[ "$RUN_GRADING_SMOKE" == true ]]; then
  zip_path="${ZIP_PATH:-}"
  if [[ -z "$zip_path" || ! -f "$TEST_ROOT/k6/$zip_path" && ! -f "$TEST_ROOT/$zip_path" ]]; then
    echo "ZIP_PATH must point to a prepared staging ZIP (see .env.example for path resolution)." >&2
    exit 2
  fi
fi
if [[ "$RUN_RECONCILIATION" == true ]]; then
  for var in SUBMISSION_DB_URL EXECUTOR_DB_URL RESULT_DB_URL; do
    if [[ -z "${!var:-}" ]]; then
      echo "Set $var to a read-only staging database URL or disable RUN_RECONCILIATION." >&2
      exit 2
    fi
  done
fi
if [[ "$RUN_SELF_HEAL_TEST" == true ]]; then
  : "${KUBE_CONTEXT:?Set KUBE_CONTEXT to the approved staging context}"
  : "${KUBE_NAMESPACE:?Set KUBE_NAMESPACE to the staging namespace}"
  if [[ "${FAULT_TEST_CONFIRM:-}" != "I_UNDERSTAND_THIS_BREAKS_STAGING" ]]; then
    echo "Set FAULT_TEST_CONFIRM=I_UNDERSTAND_THIS_BREAKS_STAGING to authorize the staging self-heal test." >&2
    exit 2
  fi
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "kubectl is required for RUN_SELF_HEAL_TEST=true." >&2
    exit 2
  fi
  if [[ ! -r /dev/tty ]]; then
    echo "An interactive terminal is required for the self-heal confirmation." >&2
    exit 2
  fi
  current_context="$(kubectl config current-context)"
  if [[ "$current_context" != "$KUBE_CONTEXT" || "$current_context" =~ (^|[-_])(prod|production)([-_]|$) || "$KUBE_NAMESPACE" =~ (^|[-_])(prod|production)([-_]|$) ]]; then
    echo "Refusing self-heal test: verify the current staging context and namespace." >&2
    exit 2
  fi
fi

run_id="$(date -u +%Y%m%dT%H%M%SZ)_$$"
results_root="${RESULTS_DIR:-$TEST_ROOT/results}"
mkdir -p "$results_root"
chmod 700 "$results_root"
results_root="$(cd -- "$results_root" && pwd)"
result_dir="$results_root/$run_id"
mkdir -p "$result_dir"
chmod 700 "$result_dir"
commit="$(git -C "$TEST_ROOT" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "$result_dir/run-metadata.txt" <<EOF
run_id=$run_id
started_at_utc=$started_at
target_environment=staging
base_url_host=$host
assignment_id=$ASSIGNMENT_ID
git_commit=$commit
api_read_enabled=$RUN_API_READ
api_profile=$API_PROFILE
grading_smoke_enabled=$RUN_GRADING_SMOKE
reconciliation_enabled=$RUN_RECONCILIATION
self_heal_test_enabled=$RUN_SELF_HEAL_TEST
EOF

run_status=0
api_status=SKIPPED
grading_status=SKIPPED
reconcile_status=SKIPPED
self_heal_status=SKIPPED
submission_id=""

run_k6() {
  local name="$1" log_file="$2"
  shift 2
  echo "==> Running $name"
  local started finished
  started="$(date +%s)"
  if "$@" > "$log_file" 2>&1; then
    finished="$(date +%s)"
    printf '%s\n' "$((finished - started))" > "${log_file%.log}.duration_seconds"
    echo "[$name] PASS (details saved in $(basename "$log_file"))"
    return 0
  else
    local rc=$?
    finished="$(date +%s)"
    printf '%s\n' "$((finished - started))" > "${log_file%.log}.duration_seconds"
    echo "[$name] FAIL (exit $rc; details saved in $(basename "$log_file"))"
    return "$rc"
  fi
}

if [[ "$RUN_API_READ" == true ]]; then
  if run_k6 "api-read-$API_PROFILE" "$result_dir/api-read-$API_PROFILE.log" \
    env PROFILE="$API_PROFILE" k6 run \
      --out "json=$result_dir/api-read-$API_PROFILE.json" \
      --summary-trend-stats 'avg,min,med,max,p(90),p(95),p(99)' \
      --summary-export "$result_dir/api-read-$API_PROFILE-summary.json" \
      "$TEST_ROOT/k6/api-read-load.js"; then
    api_status=PASS
  else
    api_status=FAIL
    run_status=1
  fi
fi

if [[ "$RUN_GRADING_SMOKE" == true ]]; then
  if run_k6 "grading-smoke" "$result_dir/grading-smoke.log" \
    env PROFILE=smoke k6 run \
      --out "json=$result_dir/grading-smoke.json" \
      --summary-trend-stats 'avg,min,med,max,p(90),p(95),p(99)' \
      --summary-export "$result_dir/grading-smoke-summary.json" \
      "$TEST_ROOT/k6/grading-flow.js"; then
    grading_status=PASS
  else
    grading_status=FAIL
    run_status=1
  fi
  submission_id="$(grep -Eo 'submission_id=[[:xdigit:]-]{36}' "$result_dir/grading-smoke.log" | tail -n 1 | cut -d= -f2 || true)"
  if [[ "$RUN_RECONCILIATION" == true ]]; then
    if [[ -z "$submission_id" ]]; then
      echo "Cannot reconcile: grading log contains no submission_id." | tee "$result_dir/reconciliation.log"
      reconcile_status=FAIL
      run_status=1
    elif SUBMISSION_ID="$submission_id" "$SCRIPT_DIR/reconcile.sh" > "$result_dir/reconciliation.log" 2>&1; then
      reconcile_status=PASS
      cat "$result_dir/reconciliation.log"
    else
      rc=$?
      reconcile_status=FAIL
      run_status=1
      cat "$result_dir/reconciliation.log"
      echo "[reconciliation] FAIL (exit $rc)"
    fi
  fi
fi

if [[ "$RUN_SELF_HEAL_TEST" == true ]]; then
  echo "==> Running guarded ArgoCD self-heal test"
  if FAULT_TEST_CONFIRM="$FAULT_TEST_CONFIRM" KUBE_CONTEXT="$KUBE_CONTEXT" KUBE_NAMESPACE="$KUBE_NAMESPACE" \
    "$SCRIPT_DIR/guarded-fault-test.sh" test-selfheal-replicas < /dev/tty 2>&1 | tee "$result_dir/self-heal.log"; then
    self_heal_status=PASS
  else
    rc=$?
    self_heal_status=FAIL
    run_status=1
    echo "[self-heal] FAIL (exit $rc)"
  fi
  cat "$result_dir/self-heal.log"
fi

finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export REPORT_DIR="$result_dir" REPORT_RUN_ID="$run_id" REPORT_STARTED_AT="$started_at" REPORT_FINISHED_AT="$finished_at"
export REPORT_HOST="$host" REPORT_ASSIGNMENT_ID="$ASSIGNMENT_ID" REPORT_COMMIT="$commit"
export REPORT_API_STATUS="$api_status" REPORT_API_PROFILE="$API_PROFILE" REPORT_GRADING_STATUS="$grading_status"
export REPORT_RECONCILE_STATUS="$reconcile_status" REPORT_SUBMISSION_ID="$submission_id" REPORT_SELF_HEAL_STATUS="$self_heal_status"
python3 - <<'PY'
import json
import os
from pathlib import Path

out = Path(os.environ["REPORT_DIR"])
rows = []

def load_summary(name, label):
    path = out / name
    if not path.exists():
        return
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        rows.append((label, "Could not parse summary JSON"))
        return
    metrics = data.get("metrics", {})
    def value(metric, key):
        metric_data = metrics.get(metric, {})
        values = metric_data.get("values", metric_data)
        found = values.get(key, values.get("value"))
        return "-" if found is None else f"{found:.3f}" if isinstance(found, (float, int)) else str(found)
    duration_file = out / name.replace("-summary.json", ".duration_seconds")
    duration_s = duration_file.read_text().strip() + "s" if duration_file.exists() else "-"
    vus = value("vus_max", "max")
    requests = value("http_reqs", "count")
    detail = (
        f"duration {duration_s}, max VU {vus}, requests {requests}; "
        f"HTTP avg/p50/p95/p99 {value('http_req_duration', 'avg')}/"
        f"{value('http_req_duration', 'med')}/{value('http_req_duration', 'p(95)')}/"
        f"{value('http_req_duration', 'p(99)')} ms; "
        f"RPS {value('http_reqs', 'rate')}; failed {value('http_req_failed', 'rate')}"
    )
    for metric in ("submission_to_terminal_seconds", "submission_to_result_seconds"):
        if metric in metrics:
            detail += f"; {metric} avg/p95 {value(metric, 'avg')}/{value(metric, 'p(95)')} s"
    rows.append((label, detail))

load_summary(f"api-read-{os.environ['REPORT_API_PROFILE']}-summary.json", "API read")
load_summary("grading-smoke-summary.json", "Grading smoke")

lines = [
    f"# Test run {os.environ['REPORT_RUN_ID']}",
    "",
    f"- Bắt đầu (UTC): {os.environ['REPORT_STARTED_AT']}",
    f"- Kết thúc (UTC): {os.environ['REPORT_FINISHED_AT']}",
    "- Môi trường: staging",
    f"- Máy chủ kiểm thử: {os.environ['REPORT_HOST']}",
    f"- Assignment: `{os.environ['REPORT_ASSIGNMENT_ID']}`",
    f"- Git commit: `{os.environ['REPORT_COMMIT']}`",
    f"- API read ({os.environ['REPORT_API_PROFILE']}): {os.environ['REPORT_API_STATUS']}",
    f"- Grading smoke: {os.environ['REPORT_GRADING_STATUS']}",
    f"- Đối soát cơ sở dữ liệu: {os.environ['REPORT_RECONCILE_STATUS']}",
    f"- ArgoCD tự khôi phục số bản sao: {os.environ['REPORT_SELF_HEAL_STATUS']}",
]
if os.environ.get("REPORT_SUBMISSION_ID"):
    lines.append(f"- Submission ID: `{os.environ['REPORT_SUBMISSION_ID']}`")
lines += ["", "## Số liệu k6", "", "| Kịch bản | Số liệu tóm tắt |", "|---|---|"]
lines += [f"| {label} | {detail} |" for label, detail in rows] or ["| Chưa có | Không có summary JSON được tạo. |"]
lines += [
    "",
    "## Tệp bằng chứng",
    "",
    "- `run-metadata.txt`: môi trường, thời điểm và commit (không chứa token/URL cơ sở dữ liệu).",
    "- Thư mục kết quả giới hạn quyền truy cập cho tài khoản hiện tại; JSON k6 thô có thể chứa ID kiểm thử hoặc URL tải tạm thời, không chia sẻ nguyên trạng.",
    "- `*.json`: dữ liệu k6 thô; `*-summary.json`: tổng hợp k6; `*.duration_seconds`: thời lượng chạy thực tế.",
    "- `*.log`: đầu ra từng lần chạy; `reconciliation.log`: trạng thái các bản ghi sau grading smoke; `self-heal.log`: kết quả thử tự khôi phục nếu được bật.",
    "",
    "Lưu ý: số liệu chỉ có ý nghĩa cho cấu hình và staging của lần chạy này; đối chiếu trạng thái, log và điều kiện môi trường trước khi đưa vào báo cáo.",
    "",
]
(out / "report.md").write_text("\n".join(lines))
PY

printf '\nRun artifacts saved to: %s\n' "$result_dir"
printf 'Summary: %s\n' "$result_dir/report.md"
exit "$run_status"
