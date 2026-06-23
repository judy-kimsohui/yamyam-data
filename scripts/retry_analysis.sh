#!/usr/bin/env bash
# ================================================================
# retry_analysis.sh — 1시간마다 실행
#
# NUTRITION_ANALYSIS 없거나 FAILED인 영상에 AI 분석 재시도.
# retry_count >= 3 이면 스킵 (Spring이 429 반환).
#
# cron 등록 예시 (매 시 정각):
#   0 * * * * ~/yamyam-data/scripts/retry_analysis.sh >> ~/yamyam-data/logs/retry.log 2>&1
#
# 환경변수로 재정의 가능:
#   DB_CONTAINER DB_USER DB_PASSWORD DB_NAME SPRING_URL
# ================================================================

DB_CONTAINER="${DB_CONTAINER:-app-mysql-1}"
DB_USER="${DB_USER:-root}"
DB_PASSWORD="${DB_PASSWORD:-ssafy}"
DB_NAME="${DB_NAME:-yamyamdb}"
SPRING_URL="${SPRING_URL:-http://localhost:8080}"

MYSQL_Q="docker exec ${DB_CONTAINER} mysql --default-character-set=utf8mb4 \
  -u${DB_USER} -p${DB_PASSWORD} ${DB_NAME} --batch --skip-column-names"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] AI 분석 재시도 시작..."

RETRY_IDS=$(${MYSQL_Q} 2>/dev/null -e \
  "SELECT v.id
   FROM VIDEOS v
   LEFT JOIN NUTRITION_ANALYSIS na ON v.id = na.video_id
   WHERE (na.id IS NULL OR na.status = 'FAILED')
     AND (na.retry_count IS NULL OR na.retry_count < 3)
   ORDER BY v.id;")

if [ -z "${RETRY_IDS}" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 재시도 대상 없음."
    exit 0
fi

COUNT=0
SKIPPED=0
for vid_id in ${RETRY_IDS}; do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${SPRING_URL}/api/videos/${vid_id}/analyze")
    case "${HTTP}" in
        202) echo "  → video_id=${vid_id} 분석 시작"; COUNT=$((COUNT+1)) ;;
        204) : ;;  # 이미 완료
        429) echo "  ✗ video_id=${vid_id} 3회 초과 포기"; SKIPPED=$((SKIPPED+1)) ;;
        *)   echo "  ⚠ video_id=${vid_id} HTTP ${HTTP} (Spring 미기동?)" ;;
    esac
    sleep 0.3
done

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 완료 — 시작 ${COUNT}개, 포기 ${SKIPPED}개"
