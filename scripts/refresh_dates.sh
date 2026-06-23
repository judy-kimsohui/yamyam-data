#!/usr/bin/env bash
# ================================================================
# refresh_dates.sh — 매일 자정에 실행 (cron 등록용)
#
# VIDEOS 테이블의 meal_date 를 +1일 당깁니다.
# 오늘 날짜를 넘어간 영상은 2주 전으로 순환시켜 항상 최신처럼 유지합니다.
#
# 적용 범위: DB 에 등록된 사용자 중 EXCLUDE_USER_IDS 를 제외한 모든 사용자.
#   → 실제 사용자(나 자신)의 업로드 영상에는 영향 없음.
#
# cron 등록 예시 (매일 자정):
#   0 0 * * * /path/to/yamyam/scripts/refresh_dates.sh >> /path/to/yamyam/logs/refresh.log 2>&1
#
# 환경변수로 재정의 가능:
#   DB_CONTAINER DB_USER DB_PASSWORD DB_NAME EXCLUDE_USER_IDS
# ================================================================

DB_CONTAINER="${DB_CONTAINER:-app-mysql-1}"
DB_USER="${DB_USER:-root}"
DB_PASSWORD="${DB_PASSWORD:-ssafy}"
DB_NAME="${DB_NAME:-yamyamdb}"

# 날짜 이동에서 제외할 user_id (나 = ssafy5)
EXCLUDE_USER_IDS="${EXCLUDE_USER_IDS:-5}"

MYSQL="docker exec -i ${DB_CONTAINER} mysql -u${DB_USER} -p${DB_PASSWORD} ${DB_NAME}"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] meal_date 갱신 시작 (제외 user_id: ${EXCLUDE_USER_IDS})"

# DB 에서 목업 대상 user_id 목록 조회 (EXCLUDE_USER_IDS 제외)
MOCK_USER_IDS=$(${MYSQL} --skip-column-names 2>/dev/null -e \
  "SELECT GROUP_CONCAT(id ORDER BY id) FROM USERS WHERE id NOT IN (${EXCLUDE_USER_IDS});")

if [ -z "${MOCK_USER_IDS}" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 목업 사용자 없음. 종료."
    exit 0
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 목업 user_id: ${MOCK_USER_IDS}"

${MYSQL} 2>/dev/null <<EOF
-- 1단계: 대상 사용자의 모든 날짜를 1000일 미래로 옮겨 UNIQUE 충돌 방지
UPDATE VIDEOS
SET meal_date = DATE_ADD(meal_date, INTERVAL 1000 DAY)
WHERE user_id IN (${MOCK_USER_IDS});

-- 2단계: -999일 (순 효과 = +1일)
--   원래 날짜가 "오늘 이상"이었던 영상은 2주 전으로 순환
UPDATE VIDEOS
SET meal_date = CASE
  WHEN meal_date > DATE_ADD(CURDATE(), INTERVAL 999 DAY)
  THEN SUBDATE(CURDATE(), INTERVAL 14 DAY)   -- 2주 전으로 순환
  ELSE DATE_SUB(meal_date, INTERVAL 999 DAY) -- 정상 +1일
END
WHERE user_id IN (${MOCK_USER_IDS});
EOF

if [ $? -eq 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 완료"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 오류 발생 — DB 연결 확인 필요"
    exit 1
fi
