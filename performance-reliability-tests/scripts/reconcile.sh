#!/usr/bin/env bash
set -euo pipefail

: "${SUBMISSION_DB_URL:?Set SUBMISSION_DB_URL to a read-only submission_db connection}"
: "${EXECUTOR_DB_URL:?Set EXECUTOR_DB_URL to a read-only executor_db connection}"
: "${RESULT_DB_URL:?Set RESULT_DB_URL to a read-only result_db connection}"
: "${SUBMISSION_ID:?Set SUBMISSION_ID to the UUID created by this test run}"

if [[ ! "$SUBMISSION_ID" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
  echo "SUBMISSION_ID must be a canonical UUID" >&2
  exit 2
fi

run_query() {
  local label="$1" url="$2" query="$3"
  echo "=== ${label} ==="
  psql "$url" -X --set=ON_ERROR_STOP=1 -c "$query"
}

run_query submission "$SUBMISSION_DB_URL" \
  "SELECT id, assignment_id, student_id, status, created_at, updated_at FROM submissions WHERE id = '$SUBMISSION_ID'::uuid AND deleted_at IS NULL;"
run_query executor "$EXECUTOR_DB_URL" \
  "SELECT id, submission_id, status, retry_count, started_at, completed_at, created_at, updated_at FROM grading_jobs WHERE submission_id = '$SUBMISSION_ID'::uuid AND deleted_at IS NULL;"
run_query results "$RESULT_DB_URL" \
  "SELECT id, submission_id, status, score, scope, is_latest, started_at, completed_at, created_at FROM results WHERE submission_id = '$SUBMISSION_ID'::uuid AND deleted_at IS NULL ORDER BY created_at;"

submission_count="$(psql "$SUBMISSION_DB_URL" -XAt --set=ON_ERROR_STOP=1 -c "SELECT count(*) FROM submissions WHERE id = '$SUBMISSION_ID'::uuid AND deleted_at IS NULL;")"
job_count="$(psql "$EXECUTOR_DB_URL" -XAt --set=ON_ERROR_STOP=1 -c "SELECT count(*) FROM grading_jobs WHERE submission_id = '$SUBMISSION_ID'::uuid AND deleted_at IS NULL;")"
result_count="$(psql "$RESULT_DB_URL" -XAt --set=ON_ERROR_STOP=1 -c "SELECT count(*) FROM results WHERE submission_id = '$SUBMISSION_ID'::uuid AND deleted_at IS NULL;")"

printf '\nsubmission_rows=%s job_rows=%s result_rows=%s\n' "$submission_count" "$job_count" "$result_count"
if [[ "$submission_count" != 1 || "$job_count" != 1 || "$result_count" -lt 1 ]]; then
  echo "RECONCILIATION=FAIL (expected 1 submission, exactly 1 grading job, and at least 1 result row)" >&2
  exit 1
fi
echo "RECONCILIATION=PASS (also inspect statuses and result details above)"
