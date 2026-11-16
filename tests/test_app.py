"""用 fakeredis 替换 Redis 客户端，测试接口行为，不连接真实 Redis。"""
import fakeredis
import pytest

import app as hw11


@pytest.fixture
def server():
    return fakeredis.FakeServer()


@pytest.fixture
def client(server, monkeypatch):
    monkeypatch.setattr(hw11, "cache", fakeredis.FakeRedis(server=server, decode_responses=True))
    # 冷缓存路径会 sleep(1) 模拟慢查询，测试中跳过等待。
    monkeypatch.setattr(hw11.time, "sleep", lambda seconds: None)
    hw11.app.config.update(TESTING=True)
    return hw11.app.test_client()


def test_health_ok(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json() == {"status": "ok", "redis": "ok"}


def test_health_redis_down(client, server):
    server.connected = False
    resp = client.get("/health")
    assert resp.status_code == 503
    assert resp.get_json()["error"] == "redis_unavailable"


def test_products_cold_cache_writes_key(client):
    resp = client.get("/api/products")
    body = resp.get_json()
    assert resp.status_code == 200
    assert body["cache_hit"] is False
    assert body["cache_key"] == "hw11:products:v1"
    assert len(body["products"]) == 4
    assert 0 < hw11.cache.ttl("hw11:products:v1") <= hw11.CACHE_TTL


def test_products_second_request_hits_cache(client):
    first = client.get("/api/products").get_json()
    second = client.get("/api/products").get_json()
    assert second["cache_hit"] is True
    assert second["source"] == "Redis 缓存"
    assert second["generated_at"] == first["generated_at"]


def test_products_redis_error(client, server):
    server.connected = False
    resp = client.get("/api/products")
    assert resp.status_code == 503
    assert resp.get_json()["error"] == "redis_unavailable"


def test_version_returns_app_version(client, monkeypatch):
    monkeypatch.setenv("APP_VERSION", "3f2c1ab")
    resp = client.get("/version")
    assert resp.status_code == 200
    assert resp.get_json() == {"app": "homework11-flask-cicd", "version": "3f2c1ab"}


def test_index_page_shows_version_and_cache_state(client, monkeypatch):
    monkeypatch.setenv("APP_VERSION", "3f2c1ab9d0e8")
    first = client.get("/")
    assert first.status_code == 200
    assert "3f2c1ab9d0e8" in first.get_data(as_text=True)
    assert "MISS" in first.get_data(as_text=True)
    assert "HIT" in client.get("/").get_data(as_text=True)


def test_index_page_redis_error_returns_503(client, server):
    server.connected = False
    resp = client.get("/")
    assert resp.status_code == 503
    assert "HTTP 503" in resp.get_data(as_text=True)
