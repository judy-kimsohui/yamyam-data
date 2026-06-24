#!/usr/bin/env bash
# ================================================================
# transcode_all_hls.sh — 기존 영상 전체 HLS 트랜스코딩 일괄 실행
#
# 사용법:
#   bash ~/yamyam-data/scripts/transcode_all_hls.sh
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

echo "[$(date '+%Y-%m-%d %H:%M:%S')] HLS 일괄 트랜스코딩 시작..."

VIDEO_IDS=$(${MYSQL_Q} 2>/dev/null -e "SELECT id FROM VIDEOS ORDER BY id;")

if [ -z "${VIDEO_IDS}" ]; then
    echo "영상 없음. 종료."
    exit 0
fi

TOTAL=$(echo "${VIDEO_IDS}" | wc -l | tr -d ' ')
echo "대상 영상: ${TOTAL}개"
echo ""

COUNT=0
SKIP=0
for vid_id in ${VIDEO_IDS}; do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${SPRING_URL}/api/videos/${vid_id}/hls")
    case "${HTTP}" in
        202) echo "  ✓ video_id=${vid_id} 트랜스코딩 시작"; COUNT=$((COUNT+1)) ;;
        404) echo "  - video_id=${vid_id} 건너뜀 (dev 모드 또는 영상 없음)"; SKIP=$((SKIP+1)) ;;
        *)   echo "  ⚠ video_id=${vid_id} HTTP ${HTTP}"; SKIP=$((SKIP+1)) ;;
    esac
    sleep 0.3
done

echo ""
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 완료 — 시작 ${COUNT}개, 건너뜀 ${SKIP}개"
