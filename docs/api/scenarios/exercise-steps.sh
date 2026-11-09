#!/usr/bin/env bash
# Exercise definition integration scenarios: test plans + steps (EXS-*)
# Usage: BASE_URL=http://localhost:18081 ./exercise-steps.sh
set -uo pipefail

BASE_URL="${BASE_URL:-http://localhost:18081}"
OWNER1="${OWNER1:-2d93941a-4221-458b-a03d-43bd6315d02e}"
OWNER2="${OWNER2:-11111111-1111-1111-1111-111111111111}"
DB_JDBC="${DATABASE_URL:-postgresql://neondb_owner:npg_Vmfuxhe1WPO5@ep-frosty-hill-ayd5wchg-pooler.c-5.us-east-2.aws.neon.tech/assignment_db}"

PASS=0; FAIL=0
green() { echo -e "\e[32m$*\e[0m"; }
red()   { echo -e "\e[31m$*\e[0m"; }
assert_eq() {
    if [ "$2" == "$3" ]; then PASS=$((PASS+1)); green "PASS $1"; else FAIL=$((FAIL+1)); red "FAIL $1 (actual='$2' expected='$3')"; fi
}

call_api() { # method path owner [body]
    local method=$1 path=$2 owner=$3 body=${4:-}
    local tmp; tmp=$(mktemp)
    if [ -n "$body" ]; then
        STATUS=$(curl -s -m 20 -o "$tmp" -w "%{http_code}" -X "$method" "$BASE_URL$path" \
            -H "X-User-Id: $owner" -H "Content-Type: application/json" -d "$body")
    else
        STATUS=$(curl -s -m 20 -o "$tmp" -w "%{http_code}" -X "$method" "$BASE_URL$path" -H "X-User-Id: $owner")
    fi
    BODY=$(cat "$tmp"); rm -f "$tmp"
}
jget() { echo "$BODY" | jq -r "$1"; }

run_sql() {
    case "$(command -v psql >/dev/null && echo psql || { command -v docker >/dev/null && docker image inspect postgres:16-alpine >/dev/null 2>&1 && echo docker || echo ""; })" in
        psql)   psql "$DB_JDBC" -tA -c "$1" 2>/dev/null ;;
        docker) docker run --rm postgres:16-alpine psql "$DB_JDBC" -tA -c "$1" 2>/dev/null ;;
        *)      echo "__SKIP__" ;;
    esac
}
db_assert_eq() {
    local got; got=$(run_sql "$2")
    if [ "$got" == "__SKIP__" ]; then echo "WARN(db): client unavailable — skipping: $1"; return 0; fi
    assert_eq "$1" "$got" "$3"
}

STAMP=$(date +%s)

# ---------- seed class + published assignment ----------
call_api POST "/api/v1/classes" "$OWNER1" "{\"name\":\"exs-class-$STAMP\",\"semester\":\"20261\"}"
CID=$(echo "$BODY" | jq -r '.data.id')
call_api POST "/api/v1/assignments" "$OWNER1" "{\"title\":\"exs-assign-$STAMP\",\"classId\":\"$CID\",\"gradingStrategy\":\"STUDENT_DOCKER_COMPOSE\"}"
AID=$(echo "$BODY" | jq -r '.data.id')
call_api POST "/api/v1/assignments/$AID/publish" "$OWNER1" >/dev/null
[ -n "$CID" ] && [ "$CID" != "null" ] && { PASS=$((PASS+1)); green "seed ok (class=$CID assignment=$AID)"; } || { red "seed FAILED"; exit 1; }

# ---------- EXS-01 create plan ----------
call_api POST "/api/v1/assignments/$AID/plans" "$OWNER1" \
  '{"name":"CRUD Book API — Basic","description":"basic flow","sequenceOrder":1,"weight":10}'
assert_eq "EXS-01 status" "$STATUS" "201"
PLAN1=$(echo "$BODY" | jq -r '.data.id')
assert_eq "EXS-01 weight default echo" "$(echo "$BODY" | jq -r '.data.weight')" "10"

# ---------- EXS-02 duplicate sequenceOrder ----------
call_api POST "/api/v1/assignments/$AID/plans" "$OWNER1" \
  '{"name":"dup","sequenceOrder":1}'
assert_eq "EXS-02 status" "$STATUS" "400"
assert_eq "EXS-02 message" "$(echo "$BODY" | jq -r '.message')" \
          "A plan with sequence_order 1 already exists in this assignment"

# ---------- EXS-03 second plan seq 2 ----------
call_api POST "/api/v1/assignments/$AID/plans" "$OWNER1" \
  '{"name":"CRUD Book API — Advanced","sequenceOrder":2,"weight":5}'
assert_eq "EXS-03 status" "$STATUS" "201"
PLAN2=$(echo "$BODY" | jq -r '.data.id')

# ---------- EXS-04 nested list empty steps, ordered ----------
call_api GET "/api/v1/assignments/$AID/plans" "$OWNER1"
assert_eq "EXS-04 plans count" "$(echo "$BODY" | jq -r '.data | length')" "2"
assert_eq "EXS-04 ordered by seq" "$(echo "$BODY" | jq -r '.data[0].sequenceOrder'),$(echo "$BODY" | jq -r '.data[1].sequenceOrder')" "1,2"

# ---------- EXS-05 build the docs §8.1 CRUD-Book step chain ----------
call_api POST "/api/v1/assignments/$AID/plans/$PLAN1/steps" "$OWNER1" \
  '{"stepOrder":1,"name":"Create a book","stepType":"HTTP_REQUEST","weight":2,
    "config":{"method":"POST","path":"/api/v1/books",
              "headers":{"Content-Type":"application/json"},
              "body":{"title":"Dế Mèn Phiêu Lưu Ký","author":"Tô Hoài","year":1941},
              "expected_status":201,
              "extract":[{"name":"bookId","from":"response_body","expression":"$.id"}]}}'
assert_eq "EXS-05 s1 create-book" "$STATUS" "201"
STEP_S1=$(echo "$BODY" | jq -r '.data.id')

call_api POST "/api/v1/assignments/$AID/plans/$PLAN1/steps" "$OWNER1" \
  '{"stepOrder":2,"name":"Verify book details","stepType":"HTTP_REQUEST","weight":2,
    "config":{"method":"GET","path":"/api/v1/books/${bookId}","expected_status":200,
              "expected_body_contains":"Dế Mèn Phiêu Lưu Ký"}}'
assert_eq "EXS-05 s2 verify" "$STATUS" "201"

call_api POST "/api/v1/assignments/$AID/plans/$PLAN1/steps" "$OWNER1" \
  '{"stepOrder":3,"name":"Search by title","stepType":"HTTP_REQUEST","weight":2,
    "config":{"method":"GET","path":"/api/v1/books","query_params":{"title":"Dế Mèn"},
              "expected_status":200,"expected_body_contains":"${bookId}"}}'
assert_eq "EXS-05 s3 search" "$STATUS" "201"

call_api POST "/api/v1/assignments/$AID/plans/$PLAN1/steps" "$OWNER1" \
  '{"stepOrder":4,"name":"Check DB schema","stepType":"DB_SCHEMA_CHECK","weight":2,
    "config":{"checks":[
      {"kind":"TABLE_EXISTS","table_name":"books"},
      {"kind":"COLUMN_EXISTS","table_name":"books","column_name":"title","data_type":"VARCHAR"},
      {"kind":"PRIMARY_KEY","table_name":"books","column":"id"}]}}'
assert_eq "EXS-05 s4 schema" "$STATUS" "201"

call_api POST "/api/v1/assignments/$AID/plans/$PLAN1/steps" "$OWNER1" \
  '{"stepOrder":5,"name":"Verify data in DB","stepType":"DB_QUERY","weight":2,"timeoutMs":15000,
    "expectedResult":{"row_count":1,"columns":["title","author","year"]},
    "config":{"query":"SELECT title, author, year FROM books WHERE id = ${bookId}",
              "expected":{"row_count":1,"columns":["title","author","year"]}}}'
assert_eq "EXS-05 s5 db-query" "$STATUS" "201"

# ---------- EXS-06 invalid config matrix ----------
bad_config() { # desc json
    call_api POST "/api/v1/assignments/$AID/plans/$PLAN1/steps" "$OWNER1" \
      "{\"stepOrder\":99,\"name\":\"bad\",\"stepType\":$1,\"config\":$2}"
    assert_eq "$1" "$STATUS" "400"
}
bad_config '"HTTP_REQUEST"'  '{"method":"TELEPORT","path":"/x"}'
bad_config '"HTTP_REQUEST"'  '{"method":"GET","path":"no-slash"}'
bad_config '"HTTP_REQUEST"'  '{"method":"GET","path":"/x","expected_status":42}'
bad_config '"HTTP_REQUEST"'  '{"method":"GET","path":"/x","extract":[{"name":"v"}]}'
bad_config '"HTTP_REQUEST"'  '{"method":"GET","path":"/x","assertions":[{"kind":"magic"}]}'
bad_config '"DB_SCHEMA_CHECK"' '{"checks":[{"kind":"COLUMN_EXISTS","table_name":"books"}]}'
bad_config '"DELAY"'         '{"duration_ms":-5}'
bad_config '"DB_MIGRATION"'  '{"statements":[]}'
bad_config '"EXTRACT"'       '{"variables":[{"name":"orphan"}]}'
bad_config '"HTTP_REQUEST"'  '[]'

# ---------- EXS-07 duplicate step_order ----------
call_api POST "/api/v1/assignments/$AID/plans/$PLAN1/steps" "$OWNER1" \
  '{"stepOrder":3,"name":"dup","stepType":"DELAY","config":{"duration_ms":100}}'
assert_eq "EXS-07 status" "$STATUS" "400"
assert_eq "EXS-07 message" "$(echo "$BODY" | jq -r '.message')" \
          "step_order 3 already exists in plan 'CRUD Book API — Basic'"

# ---------- EXS-08 nested list: ordering + config round-trip ----------
call_api GET "/api/v1/assignments/$AID/plans" "$OWNER1"
assert_eq "EXS-08 p1 steps count" "$(echo "$BODY" | jq -r '.data[0].steps | length')" "5"
assert_eq "EXS-08 orders" "$(echo "$BODY" | jq -r '[.data[0].steps[].stepOrder] | join(",")')" "1,2,3,4,5"
assert_eq "EXS-08 s1 method" "$(echo "$BODY" | jq -r '.data[0].steps[0].config.method')" "POST"
assert_eq "EXS-08 s2 path keeps variable" "$(echo "$BODY" | jq -r '.data[0].steps[1].config.path')" "/api/v1/books/\${bookId}"
assert_eq "EXS-08 s5 expectedResult.row_count" "$(echo "$BODY" | jq -r '.data[0].steps[4].expectedResult.row_count')" "1"

# ---------- EXS-09 update step (rename) ----------
S2_ID=$(echo "$BODY" | jq -r '.data[0].steps[1].id')
call_api PUT "/api/v1/assignments/$AID/plans/$PLAN1/steps/$S2_ID" "$OWNER1" \
  '{"name":"Verify book details v2"}'
assert_eq "EXS-09 status" "$STATUS" "200"
assert_eq "EXS-09 renamed" "$(echo "$BODY" | jq -r '.data.name')" "Verify book details v2"

# ---------- EXS-10 reorder conflict then free move ----------
call_api GET "/api/v1/assignments/$AID/plans" "$OWNER1"
S2_ID=$(echo "$BODY" | jq -r '.data[0].steps[1].id')
S3_ID=$(echo "$BODY" | jq -r '.data[0].steps[2].id')
S5_ID=$(echo "$BODY" | jq -r '.data[0].steps[4].id')
call_api PUT "/api/v1/assignments/$AID/plans/$PLAN1/steps/$S3_ID" "$OWNER1" \
  '{"name":"Search by title","stepOrder":1}'
assert_eq "EXS-10 conflict rejected" "$STATUS" "400"
call_api PUT "/api/v1/assignments/$AID/plans/$PLAN1/steps/$S5_ID" "$OWNER1" \
  '{"name":"Verify data in DB","stepOrder":6}'
assert_eq "EXS-10 free slot move" "$STATUS" "200"

# ---------- EXS-11 delete step ----------
call_api DELETE "/api/v1/assignments/$AID/plans/$PLAN1/steps/$S3_ID" "$OWNER1"
assert_eq "EXS-11 delete status" "$STATUS" "200"
call_api GET "/api/v1/assignments/$AID/plans" "$OWNER1"
assert_eq "EXS-11 steps after delete" "$(echo "$BODY" | jq -r '[.data[0].steps[]] | length')" "4"

# ---------- EXS-12 plan rename / reorder ----------
call_api PUT "/api/v1/assignments/$AID/plans/$PLAN1" "$OWNER1" \
  '{"name":"CRUD Book API — v2","sequenceOrder":3}'
assert_eq "EXS-12 status" "$STATUS" "200"
call_api GET "/api/v1/assignments/$AID/plans" "$OWNER1"
assert_eq "EXS-12 first plan is now seq2 one" "$(echo "$BODY" | jq -r '.data[0].sequenceOrder')" "2"

# ---------- EXS-13 ownership: other lecturer invisible ----------
call_api GET "/api/v1/assignments/$AID/plans" "$OWNER2"
assert_eq "EXS-13 other owner -> 404" "$STATUS" "404"

# ---------- EXS-14 internal contracts ----------
call_api GET "/api/v1/internal/assignments/$AID" "$OWNER2"
assert_eq "EXS-14 config status (raw, no envelope)" "$STATUS" "200"
assert_eq "EXS-14 strategy" "$(echo "$BODY" | jq -r '.gradingStrategy')" "STUDENT_DOCKER_COMPOSE"
assert_eq "EXS-14 maxMemoryMb default" "$(echo "$BODY" | jq -r '.maxMemoryMb')" "256"

call_api GET "/api/v1/internal/assignments/$AID/plans" "$OWNER2"
assert_eq "EXS-14 internal plans count" "$(echo "$BODY" | jq -r 'length')" "2"
assert_eq "EXS-14 sorted first seq" "$(echo "$BODY" | jq -r '.[0].sequenceOrder')" "2"
assert_eq "EXS-14 config carried as string" \
  "$(echo "$BODY" | jq -r '.[1].steps[0].config | fromjson | .method')" "POST"

call_api GET "/api/v1/internal/assignments/$AID/exists" "$OWNER2"
assert_eq "EXS-14 published exists=true" "$(echo "$BODY" | jq -r '.exists')" "true"

# unpublished second assignment
call_api POST "/api/v1/assignments" "$OWNER1" \
  "{\"title\":\"unpub-$STAMP\",\"classId\":\"$CID\",\"gradingStrategy\":\"STUDENT_DOCKER_COMPOSE\"}"
UNPUB=$(echo "$BODY" | jq -r '.data.id')
call_api GET "/api/v1/internal/assignments/$UNPUB/exists" "$OWNER2"
assert_eq "EXS-14 unpublished exists=false" "$(echo "$BODY" | jq -r '.exists')" "false"

db_assert_eq "EXS-14 db: plans of assignment" \
  "select count(*) from test_plans where assignment_id='$AID' and deleted_at is null" "2"

echo ""
echo "=============================="
if [ $FAIL -eq 0 ]; then green "ALL $PASS ASSERTIONS PASSED"; else red "$FAIL ASSERTIONS FAILED ($PASS passed)"; fi
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
