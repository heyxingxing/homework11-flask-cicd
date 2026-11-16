#!/usr/bin/env bash
# 金丝雀发布演示（在服务器上运行，与 deploy.sh 放在同一目录）。
# 用 nginx:1.26.3 把请求按权重分给两个版本的 hw11-web 镜像。
#   start STABLE_SHA CANARY_SHA   启动 hw11-stable、hw11-canary 和 hw11-nginx（127.0.0.1:18012）
#   weights S C                   修改权重（0 表示下线该版本），nginx -t 通过后 reload
#   sample [N]                    经 nginx 请求 /version N 次（默认 100），统计两个版本各占多少
#   cleanup                       删除这三个容器
set -euo pipefail

REPO=heyxingxing/homework11-flask-cicd
NET=hw11-net
PORT=18012
DIR=$(cd "$(dirname "$0")" && pwd)
CONF_DIR=$DIR/nginx
CONF=$CONF_DIR/nginx-canary.conf

start_web() { # name sha
  docker image inspect "$REPO:$2" >/dev/null
  docker rm -f "$1" >/dev/null 2>&1 || true
  docker run -d --name "$1" --network "$NET" -e APP_VERSION="$2" -e REDIS_HOST=hw11-redis "$REPO:$2" >/dev/null
}

weight_text() { [[ $1 == 0 ]] && echo "down" || echo "weight=$1"; }

apply_weights() { # stable_weight canary_weight
  sed -i -E "s/^( *server hw11-stable:5000).*/\1 $(weight_text "$1");/; s/^( *server hw11-canary:5000).*/\1 $(weight_text "$2");/" "$CONF"
}

reload_nginx() {
  docker exec hw11-nginx nginx -t
  docker exec hw11-nginx nginx -s reload
  # reload 为异步操作，等旧 worker 退出、新配置接管后再继续。
  sleep 2
}

# 等后端能响应再返回：后端未就绪时 nginx 会把它临时标记为不可用，采样结果会全部落到另一个版本。
wait_ready() {
  for _ in $(seq 30); do
    docker exec hw11-nginx curl -fsS --max-time 2 "http://$1:5000/version" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "$1 not ready after 30s" >&2; return 1
}

app_version() { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" | sed -n 's/^APP_VERSION=//p'; }

case "${1:-}" in
  start)
    docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
    start_web hw11-stable "$2"
    start_web hw11-canary "$3"
    apply_weights 9 1   # 每次启动都从 9:1 开始，不沿用上一轮演示留下的权重
    docker rm -f hw11-nginx >/dev/null 2>&1 || true
    # 挂载配置目录而不是单个文件：sed -i 会换新 inode，单文件挂载看不到修改。
    docker run -d --name hw11-nginx --network "$NET" -p "127.0.0.1:${PORT}:80" \
      -v "$CONF_DIR:/etc/nginx/conf.d:ro" nginx:1.26.3 >/dev/null
    wait_ready hw11-stable
    wait_ready hw11-canary
    docker ps --filter "name=^/hw11-(stable|canary|nginx)$" --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}'
    ;;
  weights)
    apply_weights "$2" "$3"
    grep -E 'server hw11-' "$CONF"
    reload_nginx
    ;;
  sample)
    n=${2:-100}
    stable=$(app_version hw11-stable); canary=$(app_version hw11-canary)
    result=$(for _ in $(seq "$n"); do curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/version" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p'; done)
    echo "GET http://127.0.0.1:${PORT}/version x ${n}"
    printf '  stable %s  %3d\n' "${stable:0:7}" "$(grep -c "^${stable}$" <<<"$result" || true)"
    printf '  canary %s  %3d\n' "${canary:0:7}" "$(grep -c "^${canary}$" <<<"$result" || true)"
    ;;
  cleanup)
    docker rm -f hw11-nginx hw11-stable hw11-canary
    ;;
  *)
    sed -n '2,7p' "$0"; exit 2
    ;;
esac
