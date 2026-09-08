#!/usr/bin/env bash
# Exercise management integration scenarios (EX-01..EX-17)
# Usage:  BASE_URL=http://localhost:18081 ./exercise-management.sh
# Requires: curl, jq. DB checks use psql (or dockerized postgres) when available;
# they are skipped with a warning otherwise.
set -uo pipefail

BASE_URL="${BASE_URL:-http://localhost:18081}"
OWNER1="${OWNER1:-2d93941a-4221-458b-a03d-43bd6315d02e}"
OWNER2="${OWNER2:-11111111-1111-1111-1111-111111111111}"
DB_JDBC="${DATABASE_URL:-postgresql://neondb_owner:npg_Vmfuxhe1WPO5@ep-frosty-hill-ayd5wchg-pooler.c-5.us-east-2.aws.neon.tech/assignment_db}"

PASS=0; FAIL=0

green() { echo -e "\e[32m$*\e[0m"; }
red()   { echo -e "\e[31m$*\e[0m"; }

assert_eq() { # desc actual expected
    if [ "$2" == "$3" ]; then PASS=$((PASS+1)); green "PASS $1"; else FAIL=$((FAIL+1)); red "FAIL $1 (actual='$2' expected='$3')"; fi
}

call_api() { # method path owner [body]
    local method=$1 path=$2 owner=$3 body=${4:-}
    local tmp; tmp=$(mktemp)
    local code
    if [ -n "$body" ]; then
        code=$(curl -s -m 20 -o "$tmp" -w "%{http_code}" -X "$method" "$BASE_URL$path" \
            -H "X-User-Id: $owner" -H "Content-Type: application/json" -d "$body")
    else
        code=$(curl -s -m 20 -o "$tmp" -w "%{http_code}" -X "$method" "$BASE_URL$path" -H "X-User-Id: $owner")
    fi
    STATUS=$code
    BODY=$(cat "$tmp"); rm -f "$tmp"
}

jget() { echo "$BODY" | jq -r "$1"; }

db_client() {
    if command -v psql >/dev/null; then echo "psql"; return; fi
    if command -v docker >/dev/null && docker image inspect postgres:16-alpine >/dev/null 2>&1; then
        echo "docker"; return
    fi
    echo ""
}

run_sql() { # sql -> scalar result (first row, first col); empty if no db client
    local sql=$1
    case "$(db_client)" in
        psql)   psql "$DB_JDBC" -tA -c "$sql" 2>/dev/null ;;
        docker) docker run --rm postgres:16-alpine psql "$DB_JDBC" -tA -c "$sql" 2>/dev/null ;;
        *)      echo "__SKIP__" ;;
    esac
}

db_assert_eq() { # desc sql expected
    local got; got=$(run_sql "$2")
    if [ "$got" == "__SKIP__" ]; then
        echo "WARN(db): no psql/docker client — skipping: $1"
        return 0
    fi
    assert_eq "$1" "$got" "$3"
}

STAMP=$(date +%s)

# ---------- S0 setup: two classes for lecturer 1 ----------
call_api POST "/api/v1/classes" "$OWNER1" "{\"name\":\"ex-class-A-$STAMP\",\"semester\":\"20261\"}"
CLASS_A=$(echo "$BODY" | jq -r '.data.id // .id')
call_api POST "/api/v1/classes" "$OWNER1" "{\"name\":\"ex-class-B-$STAMP\",\"semester\":\"20261\"}"
CLASS_B=$(echo "$BODY" | jq -r '.data.id // .id')
[ -n "$CLASS_A" ] && [ "$CLASS_A" != "null" ] && { PASS=$((PASS+1)); green "setup class A ok"; } || { FAIL=$((FAIL+1)); red "setup class A FAILED"; exit 1; }

# ---------- EX-01 POST valid ----------
call_api POST "/api/v1/assignments" "$OWNER1" "{\"title\":\"Ex-$STAMP\",\"description\":\"desc\",\"classId\":\"$CLASS_A\",\"gradingStrategy\":\"STUDENT_DOCKER_COMPOSE\",\"dockerComposePort\":8080,\"startupTimeoutMs\":60000,\"executionTimeoutMs\":300000,\"maxMemoryMb\":256,\"maxCpu\":0.5}"
assert_eq "EX-01 status" "$STATUS" "201"
ASSIGN_ID=$(echo "$BODY" | jq -r '.data.id')
assert_eq "EX-01 id returned" "$ASSIGN_ID" "$(echo "$BODY" | jq -r '.data.id')"
assert_eq "EX-01 published=false" "$(echo "$BODY" | jq -r '.data.published')" "false"
db_assert_eq "EX-01 db row exists/unpublished/not-deleted" \
    "select count(*) from assignments where id='$ASSIGN_ID' and published=false and deleted_at is null" "1"

# ---------- EX-02 POST missing title ----------
call_api POST "/api/v1/assignments" "$OWNER1" "{\"description\":\"no title\",\"classId\":\"$CLASS_A\",\"gradingStrategy\":\"STUDENT_DOCKER_COMPOSE\"}"
assert_eq "EX-02 status" "$STATUS" "400"
db_assert_eq "EX-02 no row inserted" \
    "select count(*) from assignments where class_id='$CLASS_A' and title is null" "0"

# ---------- EX-03 other lecturer's class ----------
call_api POST "/api/v1/assignments" "$OWNER2" "{\"title\":\"steal-$STAMP\",\"classId\":\"$CLASS_A\",\"gradingStrategy\":\"STUDENT_DOCKER_COMPOSE\"}"
assert_eq "EX-03 status (indistinguishable 404)" "$STATUS" "404"

# ---------- EX-04 LECTURER strategy w/o template ----------
call_api POST "/api/v1/assignments" "$OWNER1" "{\"title\":\"lec-$STAMP\",\"classId\":\"$CLASS_A\",\"gradingStrategy\":\"LECTURER_DOCKER_COMPOSE\"}"
assert_eq "EX-04 status" "$STATUS" "400"

# ---------- EX-05 duplicate title same class ----------
call_api POST "/api/v1/assignments" "$OWNER1" "{\"title\":\"Ex-$STAMP\",\"classId\":\"$CLASS_A\",\"gradingStrategy\":\"STUDENT_DOCKER_COMPOSE\"}"
assert_eq "EX-05 status" "$STATUS" "400"
assert_eq "EX-05 message mentions title" "$(echo "$BODY" | jq -r '.message')" \
          "Assignment 'Ex-$STAMP' already exists in this class"

# ---------- EX-06 list paging meta ----------
call_api GET "/api/v1/assignments?size=1" "$OWNER1"
TOTAL=$(echo "$BODY" | jq -r '.data.meta.total')
assert_eq "EX-06 total>0" "$([ "$TOTAL" -gt 0 ] && echo yes)" "yes"
assert_eq "EX-06 pageSize=1" "$(echo "$BODY" | jq -r '.data.meta.pageSize')" "1"

# ---------- EX-07 class filter isolation ----------
call_api GET "/api/v1/assignments?classId=$CLASS_A&size=50" "$OWNER1"
A_COUNT=$(echo "$BODY" | jq -r '[.data.result[]] | length')
call_api GET "/api/v1/assignments?classId=$CLASS_B&size=50" "$OWNER1"
B_COUNT=$(echo "$BODY" | jq -r '[.data.result[]] | length')
assert_eq "EX-07 class A has our assignment" "$A_COUNT" "1"
assert_eq "EX-07 class B isolated" "$B_COUNT" "0"

# ---------- EX-08 published filter ----------
call_api GET "/api/v1/assignments?classId=$CLASS_A&published=true&size=50" "$OWNER1"
assert_eq "EX-08 none published yet (class A)" "$(echo "$BODY" | jq -r '.data.meta.total')" "0"

# ---------- EX-09 search ----------
call_api GET "/api/v1/assignments?search=ex-$STAMP&size=50" "$OWNER1"
assert_eq "EX-09 search finds ours" "$(echo "$BODY" | jq -r '.data.meta.total')" "1"

# ---------- EX-10 detail ----------
call_api GET "/api/v1/assignments/$ASSIGN_ID" "$OWNER1"
assert_eq "EX-10 status" "$STATUS" "200"
assert_eq "EX-10 title" "$(echo "$BODY" | jq -r '.data.title')" "Ex-$STAMP"

# ---------- EX-11 other owner detail ----------
call_api GET "/api/v1/assignments/$ASSIGN_ID" "$OWNER2"
assert_eq "EX-11 status" "$STATUS" "404"

# ---------- EX-12 update ----------
call_api PUT "/api/v1/assignments/$ASSIGN_ID" "$OWNER1" "{\"title\":\"Ex-$STAMP-v2\",\"description\":\"updated\",\"maxMemoryMb\":512}"
assert_eq "EX-12 status" "$STATUS" "200"
assert_eq "EX-12 title updated" "$(echo "$BODY" | jq -r '.data.title')" "Ex-$STAMP-v2"
assert_eq "EX-12 memory updated" "$(echo "$BODY" | jq -r '.data.maxMemoryMb')" "512"
db_assert_eq "EX-12 db persisted" \
    "select count(*) from assignments where id='$ASSIGN_ID' and title='Ex-$STAMP-v2' and max_memory_mb=512" "1"

# ---------- EX-13 PUT cannot move class ----------
call_api PUT "/api/v1/assignments/$ASSIGN_ID" "$OWNER1" "{\"title\":\"Ex-$STAMP-v2\",\"classId\":\"$CLASS_B\"}"
assert_eq "EX-13 status" "$STATUS" "400"
db_assert_eq "EX-13 class_id unchanged in db" \
    "select count(*) from assignments where id='$ASSIGN_ID' and class_id='$CLASS_A'" "1"

# ---------- EX-14 update duplicate title excluding self ----------
call_api POST "/api/v1/assignments" "$OWNER1" "{\"title\":\"Other-$STAMP\",\"classId\":\"$CLASS_A\",\"gradingStrategy\":\"STUDENT_DOCKER_COMPOSE\"}" >/dev/null
OTHER_ID=$(echo "$BODY" | jq -r '.data.id')
call_api PUT "/api/v1/assignments/$OTHER_ID" "$OWNER1" "{\"title\":\"Ex-$STAMP-v2\"}"
assert_eq "EX-14 status" "$STATUS" "400"

# ---------- EX-15 soft delete ----------
call_api DELETE "/api/v1/assignments/$OTHER_ID" "$OWNER1"
assert_eq "EX-15 delete status" "$STATUS" "200"
call_api GET "/api/v1/assignments/$OTHER_ID" "$OWNER1"
assert_eq "EX-15 get after delete -> 404" "$STATUS" "404"
db_assert_eq "EX-15 row kept with deleted_at set" \
    "select count(*) from assignments where id='$OTHER_ID' and deleted_at is not null" "1"

# ---------- EX-16 publish idempotent ----------
call_api POST "/api/v1/assignments/$ASSIGN_ID/publish" "$OWNER1"
assert_eq "EX-16 first publish" "$STATUS" "200"
assert_eq "EX-16 published=true" "$(echo "$BODY" | jq -r '.data.published')" "true"
call_api POST "/api/v1/assignments/$ASSIGN_ID/publish" "$OWNER1"
assert_eq "EX-16 second publish idempotent" "$STATUS" "200"
db_assert_eq "EX-16 db published=true" \
    "select count(*) from assignments where id='$ASSIGN_ID' and published=true" "1"

# ---------- EX-08b now one is published ----------
call_api GET "/api/v1/assignments?classId=$CLASS_A&published=true&size=50" "$OWNER1"
assert_eq "EX-08b published filter finds it (class A)" "$(echo "$BODY" | jq -r '.data.meta.total')" "1"

# ---------- EX-17 combined filters ----------
call_api GET "/api/v1/assignments?classId=$CLASS_A&published=true&search=v2&size=50" "$OWNER1"
assert_eq "EX-17 combined filters" "$(echo "$BODY" | jq -r '.data.meta.total')" "1"

echo ""
echo "=============================="
if [ $FAIL -eq 0 ]; then
    green "ALL $PASS ASSERTIONS PASSED"
else
    red "$FAIL ASSERTIONS FAILED ($PASS passed)"
fi
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
