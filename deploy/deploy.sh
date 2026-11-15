#!/usr/bin/env bash
# 在服务器上部署 hw11-web：记录当前镜像 -> 停旧起新 -> 校验 /health 与 /version -> 失败时恢复上一版。
# 用法：bash deploy.sh IMAGE VERSION
#   IMAGE   本次镜像，例如 heyxingxing/homework11-flask-cicd:{commit SHA}
#   VERSION 本次 commit SHA，写入容器的 APP_VERSION，并用于 /version 校验
set -euo pipefail

IMAGE="$1"
VERSION="$2"
NET=hw11-net
REDIS=hw11-redis
WEB=hw11-web
PORT=18011
BASE="http://127.0.0.1:${PORT}"

log() { echo "[deploy $(date '+%F %T')] $*"; }

run_web() {
  docker run -d --name "$WEB" --network "$NET" --restart unless-stopped \
    -p "127.0.0.1:${PORT}:5000" \
    -e APP_VERSION="$2" -e REDIS_HOST="$REDIS" \
    "$1" >/dev/null
}

# 每 2 秒检查一次，最多等待 60 秒；/health 正常且 /version 等于期望值才算通过。
verify() {
  local expected="$1" health="" version="" deadline=$((SECONDS + 60)) n=0
  while ((SECONDS < deadline)); do
    n=$((n + 1))
    health=$(curl -fsS --max-time 3 "$BASE/health" 2>/dev/null || true)
    version=$(curl -fsS --max-time 3 "$BASE/version" 2>/dev/null || true)
    if [[ $health == *'"status":"ok"'* && $version == *"\"version\":\"${expected}\""* ]]; then
      log "check #$n passed"
      log "  GET /health  -> $health"
      log "  GET /version -> $version"
      return 0
    fi
    sleep 2
  done
  log "check failed after $n attempts"
  log "  GET /health  -> ${health:-no response}"
  log "  GET /version -> ${version:-no response} (expected ${expected})"
  return 1
}

log "target image: $IMAGE"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  log "pulling image"
  timeout 120 docker pull "$IMAGE"
fi

docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
if ! docker container inspect "$REDIS" >/dev/null 2>&1; then
  log "starting $REDIS"
  docker run -d --name "$REDIS" --network "$NET" --restart unless-stopped redis:6 >/dev/null
fi
docker start "$REDIS" >/dev/null

PREV_IMAGE=""
PREV_VERSION=""
if docker container inspect "$WEB" >/dev/null 2>&1; then
  PREV_IMAGE=$(docker container inspect -f '{{.Config.Image}}' "$WEB")
  PREV_VERSION=$(docker container inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$WEB" | sed -n 's/^APP_VERSION=//p')
  log "current: $PREV_IMAGE (APP_VERSION=$PREV_VERSION)"
  docker rm -f "$WEB" >/dev/null
elif ss -ltn | grep -q "127.0.0.1:${PORT} "; then
  log "port ${PORT} is already used by another process"
  exit 1
fi

log "starting $WEB with APP_VERSION=$VERSION"
if run_web "$IMAGE" "$VERSION" && verify "$VERSION"; then
  docker ps --filter "name=^/hw11-" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
  log "deploy succeeded"
  exit 0
fi

log "new container failed, last log lines:"
docker logs --tail 20 "$WEB" 2>&1 || true
docker rm -f "$WEB" >/dev/null 2>&1 || true
if [[ -n $PREV_IMAGE ]]; then
  log "restoring $PREV_IMAGE"
  if run_web "$PREV_IMAGE" "$PREV_VERSION" && verify "$PREV_VERSION"; then
    log "rollback succeeded"
  else
    log "rollback check failed"
  fi
fi
exit 1
