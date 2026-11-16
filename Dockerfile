# 第一阶段：在固定版本的 Python/Debian 精简镜像中准备依赖，命名为 builder。
FROM python:3.12.12-slim-bookworm AS builder
# 设置依赖准备阶段的工作目录，目录不存在时会自动创建。
WORKDIR /build
# 先复制版本清单，代码修改时可以复用依赖安装层。
COPY requirements.txt .
# 将依赖装入独立目录；不保存 pip 下载缓存，也不生成 pyc 字节码。
RUN pip install --no-cache-dir --no-compile --target=/opt/deps -r requirements.txt

# 第二阶段：与 builder 使用相同的 Python、系统和目标架构，保证依赖兼容。
FROM python:3.12.12-slim-bookworm AS runtime
# 禁止运行时写入 pyc 文件，减少容器中的临时写入。
ENV PYTHONDONTWRITEBYTECODE=1
# 立即输出 Python 日志，方便 docker logs 查看。
ENV PYTHONUNBUFFERED=1
# 让 Python 能导入独立目录中的 Flask、Redis 和 Gunicorn。
ENV PYTHONPATH=/opt/deps
# 设置应用运行目录。
WORKDIR /app
# 仅复制前一阶段准备好的运行依赖，不复制 /build 和下载临时文件。
COPY --from=builder /opt/deps /opt/deps
# 复制应用入口，不把报告、截图和验证日志打进镜像。
COPY app.py .
# 复制 Flask 的 HTML 模板目录和随页面发布的字体文件。
COPY templates/ ./templates/
COPY static/ ./static/
# 使用非 root 数字用户运行；应用只读源码，日志输出到标准输出。
USER 10001:10001
# 声明容器服务监听的端口；该指令不会发布宿主机端口。
EXPOSE 5000
# 用 Gunicorn 加载 app.py 的 app，绑定容器所有网卡的 5000；不启用 debug。
CMD ["python", "-m", "gunicorn", "--bind", "0.0.0.0:5000", "--workers", "1", "--threads", "4", "--access-logfile", "-", "--error-logfile", "-", "app:app"]
