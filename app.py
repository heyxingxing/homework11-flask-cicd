"""Flask + Redis 商品列表缓存演示（作业11 CI/CD 版本）：网页和 JSON 接口共用 get_products。"""
import json
import os
import time
from datetime import datetime, timedelta, timezone

import redis
from flask import Flask, jsonify, render_template


def positive_int(name, default):
    value = int(os.environ.get(name, default))
    if value <= 0:
        raise ValueError(f"{name} 必须是正整数")
    return value


app = Flask(__name__)
app.json.ensure_ascii = False
REDIS_HOST = os.environ.get("REDIS_HOST", "redis")
REDIS_PORT = positive_int("REDIS_PORT", 6379)
CACHE_TTL = positive_int("CACHE_TTL", 60)
CACHE_KEY = "hw11:products:v1"
cache = redis.Redis(
    host=REDIS_HOST,
    port=REDIS_PORT,
    decode_responses=True,
    socket_connect_timeout=2,
    socket_timeout=2,
    retry_on_timeout=False,
)


def get_products():
    """仅缓存商品和生成时间；命中状态、TTL、耗时每次请求重新计算。"""
    started = time.perf_counter()
    # 事务中同时读取内容和 TTL，避免两条命令之间发生过期而读到不一致状态。
    with cache.pipeline(transaction=True) as pipe:
        raw, ttl = pipe.get(CACHE_KEY).ttl(CACHE_KEY).execute()
    hit = raw is not None
    if hit:
        data = json.loads(raw)
    else:
        # 模拟本地数据查询，不访问外部 API，也不连接商品数据库。
        time.sleep(1)
        data = {
            "products": [
                {"id": "P001", "name": "轻量无线鼠标", "category": "电脑配件", "price": "79.00", "stock": 36},
                {"id": "P002", "name": "便携机械键盘", "category": "电脑配件", "price": "239.00", "stock": 18},
                {"id": "P003", "name": "桌面护眼台灯", "category": "学习用品", "price": "129.00", "stock": 24},
                {"id": "P004", "name": "云计算学习笔记本", "category": "学习用品", "price": "29.90", "stock": 68},
            ],
            "generated_at": datetime.now(timezone(timedelta(hours=8))).isoformat(timespec="microseconds"),
        }
        with cache.pipeline(transaction=True) as pipe:
            # SET 的 ex 参数把值与过期时间一起写入；不缓存本次请求的统计信息。
            _, ttl = pipe.set(CACHE_KEY, json.dumps(data, ensure_ascii=False), ex=CACHE_TTL).ttl(CACHE_KEY).execute()
    return {
        **data,
        "cache_hit": hit,
        "source": "Redis 缓存" if hit else "模拟查询",
        "cache_key": CACHE_KEY,
        "cache_ttl_configured": CACHE_TTL,
        "ttl_seconds": ttl,
        "query_ms": round((time.perf_counter() - started) * 1000, 3),
    }


def cache_error(exc, as_json):
    # Redis 故障直接返回 503，绝不切换到内存缓存；日志保留诊断信息。
    app.logger.error("Redis 查询失败 (%s): %s", type(exc).__name__, exc)
    message = f"Redis 缓存不可用或缓存数据无效，请检查 {REDIS_HOST}:{REDIS_PORT} 与 Redis 服务日志。未使用备用缓存。"
    if as_json:
        return jsonify(error="redis_unavailable", message=message), 503
    return render_template("index.html", result=None, error=message), 503


def app_version():
    # 部署时由流水线传入 commit SHA，用于确认服务器上运行的是哪次提交。
    return os.environ.get("APP_VERSION", "dev")


@app.context_processor
def inject_version():
    return {"app_version": app_version()}


@app.after_request
def no_browser_cache(response):
    # 防止浏览器自己的缓存掩盖后端 Redis 实验结果。
    response.headers["Cache-Control"] = "no-store"
    return response


@app.get("/")
def index():
    try:
        return render_template("index.html", result=get_products(), error=None)
    except (redis.RedisError, ValueError, TypeError) as exc:
        return cache_error(exc, as_json=False)


@app.get("/api/products")
def products_api():
    try:
        return jsonify(get_products())
    except (redis.RedisError, ValueError, TypeError) as exc:
        return cache_error(exc, as_json=True)


@app.get("/health")
def health():
    # 健康检查只 PING，不会提前填充商品缓存。
    try:
        cache.ping()
        return jsonify(status="ok", redis="ok")
    except redis.RedisError as exc:
        return cache_error(exc, as_json=True)


@app.get("/version")
def version():
    return jsonify(app="homework11-flask-cicd", version=app_version())


if __name__ == "__main__":
    # 直接运行时也满足课程要求；容器使用 Gunicorn 加载本文件中的 app。
    app.run(host="0.0.0.0", port=5000, debug=False)
