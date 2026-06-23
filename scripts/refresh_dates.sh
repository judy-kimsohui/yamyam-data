#!/usr/bin/env bash
# ================================================================
# refresh_dates.sh — 매일 자정에 실행 (cron 등록용)
#
# 1. VIDEOS 테이블의 meal_date 를 +1일 당깁니다.
#    오늘 날짜를 넘어간 영상은 2주 전으로 순환시켜 항상 최신처럼 유지합니다.
# 2. AI 분석이 안 된 영상(NULL 또는 FAILED)을 Spring API 로 재시도합니다.
#
# 적용 범위: DB 에 등록된 사용자 중 EXCLUDE_USER_IDS 를 제외한 모든 사용자.
#   → 실제 사용자(나 자신)의 업로드 영상에는 영향 없음.
#
# cron 등록 예시 (매일 자정):
#   0 0 * * * ~/yamyam-data/scripts/refresh_dates.sh >> ~/yamyam-data/logs/refresh.log 2>&1
#
# 환경변수로 재정의 가능:
#   DB_CONTAINER DB_USER DB_PASSWORD DB_NAME EXCLUDE_USER_IDS SPRING_URL
# ================================================================

DB_CONTAINER="${DB_CONTAINER:-app-mysql-1}"
DB_USER="${DB_USER:-root}"
DB_PASSWORD="${DB_PASSWORD:-ssafy}"
DB_NAME="${DB_NAME:-yamyamdb}"
SPRING_URL="${SPRING_URL:-http://localhost:8080}"

# 날짜 이동에서 제외할 user_id (나 = ssafy5)
EXCLUDE_USER_IDS="${EXCLUDE_USER_IDS:-5}"

MYSQL="docker exec -i ${DB_CONTAINER} mysql --default-character-set=utf8mb4 -u${DB_USER} -p${DB_PASSWORD} ${DB_NAME}"
MYSQL_Q="docker exec ${DB_CONTAINER} mysql --default-character-set=utf8mb4 -u${DB_USER} -p${DB_PASSWORD} ${DB_NAME} --batch --skip-column-names"

# ── 1. meal_date +1일 갱신 ────────────────────────────────────────
echo "[$(date '+%Y-%m-%d %H:%M:%S')] meal_date 갱신 시작 (제외 user_id: ${EXCLUDE_USER_IDS})"

MOCK_USER_IDS=$(${MYSQL_Q} 2>/dev/null -e \
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
  THEN SUBDATE(CURDATE(), INTERVAL 14 DAY)
  ELSE DATE_SUB(meal_date, INTERVAL 999 DAY)
END
WHERE user_id IN (${MOCK_USER_IDS});
EOF

if [ $? -ne 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 오류 발생 — DB 연결 확인 필요"
    exit 1
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] meal_date 갱신 완료"

# ── 2. AI 미분석/실패 영상 재시도 ────────────────────────────────
echo "[$(date '+%Y-%m-%d %H:%M:%S')] AI 미분석 영상 재시도 시작..."

UNANALYZED_IDS=$(${MYSQL_Q} 2>/dev/null -e \
  "SELECT v.id
   FROM VIDEOS v
   LEFT JOIN NUTRITION_ANALYSIS na ON v.id = na.video_id
   WHERE (na.id IS NULL OR na.status = 'FAILED')
   ORDER BY v.id;")

if [ -z "${UNANALYZED_IDS}" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 미분석 영상 없음."
else
    COUNT=0
    for vid_id in ${UNANALYZED_IDS}; do
        HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
          -X POST "${SPRING_URL}/api/videos/${vid_id}/analyze")
        if [ "${HTTP_STATUS}" = "202" ]; then
            echo "  → video_id=${vid_id} AI 분석 시작"
            COUNT=$((COUNT + 1))
        elif [ "${HTTP_STATUS}" = "204" ]; then
            : # 이미 완료 — 무시
        else
            echo "  ⚠️ video_id=${vid_id} 트리거 실패 (HTTP ${HTTP_STATUS}, Spring 미기동?)"
        fi
        sleep 0.5  # API 과부하 방지
    done
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] AI 분석 트리거 완료 (${COUNT}개 시작됨)"
fi
