#!/usr/bin/env bash
# ================================================================
# refresh_dates.sh — 매일 자정에 실행 (cron 등록용)
# AI 재시도는 retry_analysis.sh 가 1시간마다 처리.
#
# cron 등록 예시:
#   0 0 * * * ~/yamyam-data/scripts/refresh_dates.sh >> ~/yamyam-data/logs/refresh.log 2>&1
#   0 * * * * ~/yamyam-data/scripts/retry_analysis.sh >> ~/yamyam-data/logs/retry.log 2>&1
#
# 환경변수로 재정의 가능:
#   DB_CONTAINER DB_USER DB_PASSWORD DB_NAME EXCLUDE_USER_IDS
# ================================================================

DB_CONTAINER="${DB_CONTAINER:-app-mysql-1}"
DB_USER="${DB_USER:-root}"
DB_PASSWORD="${DB_PASSWORD:-ssafy}"
DB_NAME="${DB_NAME:-yamyamdb}"

EXCLUDE_USER_IDS="${EXCLUDE_USER_IDS:-5}"

MYSQL="docker exec -i ${DB_CONTAINER} mysql --default-character-set=utf8mb4 -u${DB_USER} -p${DB_PASSWORD} ${DB_NAME}"
MYSQL_Q="docker exec ${DB_CONTAINER} mysql --default-character-set=utf8mb4 -u${DB_USER} -p${DB_PASSWORD} ${DB_NAME} --batch --skip-column-names"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] meal_date 갱신 시작 (제외 user_id: ${EXCLUDE_USER_IDS})"

MOCK_USER_IDS=$(${MYSQL_Q} 2>/dev/null -e \
  "SELECT GROUP_CONCAT(id ORDER BY id) FROM USERS WHERE id NOT IN (${EXCLUDE_USER_IDS});")

if [ -z "${MOCK_USER_IDS}" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 목업 사용자 없음. 종료."
    exit 0
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 목업 user_id: ${MOCK_USER_IDS}"

${MYSQL} 2>/dev/null <<EOF
UPDATE VIDEOS
SET meal_date = DATE_ADD(meal_date, INTERVAL 1000 DAY)
WHERE user_id IN (${MOCK_USER_IDS});

UPDATE VIDEOS
SET meal_date = CASE
  WHEN meal_date > DATE_ADD(CURDATE(), INTERVAL 999 DAY)
  THEN SUBDATE(CURDATE(), INTERVAL 14 DAY)
  ELSE DATE_SUB(meal_date, INTERVAL 999 DAY)
END
WHERE user_id IN (${MOCK_USER_IDS});
EOF

if [ $? -ne 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 오류 발생"
    exit 1
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] meal_date 갱신 완료"
