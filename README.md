# homework11-flask-cicd

Flask + Redis 商品缓存应用，配套 GitHub Actions 流水线：push 到 `main` 后依次运行单元测试、构建并推送 Docker 镜像、部署到校内服务器。课程作业 11（虚拟化与云计算）。

| 路径 | 内容 |
|---|---|
| `app.py`、`templates/`、`static/` | 应用：`/`、`/api/products`、`/health`、`/version` |
| `tests/`、`requirements-dev.txt` | pytest + fakeredis 单元测试 |
| `Dockerfile` | 多阶段构建，Gunicorn 运行 |
| `.github/workflows/ci-cd.yml` | test → build-push → deploy |
| `deploy/deploy.sh` | 服务器上的部署、校验与回滚脚本 |
| `deploy/canary-demo.sh`、`nginx/nginx-canary.conf` | 金丝雀发布示例（nginx 权重分流） |

## 流水线概览

push 到 `main`（或手动 `workflow_dispatch`）后依次执行：

1. **test**（GitHub 托管 runner）：安装依赖，运行 8 个 pytest 用例，用 fakeredis 替代 Redis。
2. **build-push**（GitHub 托管 runner）：用 Docker 官方 action 构建 `linux/amd64` 镜像，推送 `{用户名}/homework11-flask-cicd:{commit SHA}` 和 `latest`；再把推送的镜像拉回，保存为 gzip artifact（保留 1 天）。
3. **deploy**（本机 self-hosted runner，标签 `hw11-deploy`）：下载 artifact，经 SSH 传到服务器，`docker load` 后运行 `deploy.sh`，校验 `/health` 和 `/version`，失败时恢复上一版镜像。

前一个 job 失败，后面的 job 不运行（`needs`）。deploy 只在 `main` 分支运行，并用 `concurrency` 保证同一时间只有一次部署。

镜像传输方式：服务器直连 Docker Hub 超时（`docker pull` 47 秒后失败），因此采用 artifact + scp + `docker load`。

## Secrets 与 Variables

在仓库网页的 **Settings → Secrets and variables → Actions** 中设置：Secrets 在 *Secrets* 标签页的 *New repository secret*，Variables 在 *Variables* 标签页的 *New repository variable*。

| 名称 | 类型 | 用途 | 使用位置 |
|---|---|---|---|
| `DOCKERHUB_TOKEN` | Secret | Docker Hub Access Token（Read & Write），推送镜像时登录用 | build-push 的 `docker/login-action` |
| `SSH_PRIVATE_KEY` | Secret | 部署专用的 ed25519 私钥，登录服务器 | deploy 的 Prepare SSH 步骤 |
| `SSH_KNOWN_HOSTS` | Secret | 服务器的主机公钥记录，用于校验服务器身份 | deploy 的 Prepare SSH 步骤 |
| `DOCKERHUB_USERNAME` | Variable | Docker Hub 用户名，用于登录和拼接镜像名 | workflow 的 `IMAGE_NAME`、build-push 登录 |
| `DEPLOY_HOST` | Variable | 服务器地址 `10.126.56.21` | deploy |
| `DEPLOY_USER` | Variable | 服务器登录用户 `yifei` | deploy |

注：用户名放在 Variable 而不是 Secret 中，否则日志里的镜像名会被打码成 `***`。仓库的 `DOCKERHUB_TOKEN` 由本人在网页上填写，其余 Secrets 与 Variables 用 `gh secret set`、`gh variable set` 写入。仓库中不含 Token、私钥和密码。

## 复现步骤

### 1 Docker Hub

在 Docker Hub 的 Account settings → Personal access tokens 中生成 Token，权限选 Read & Write。镜像仓库 `homework11-flask-cicd` 在首次推送时自动创建为公开仓库。

### 2 GitHub 仓库与配置（本机）

```bash
gh repo create {用户名}/homework11-flask-cicd --private
gh variable set DOCKERHUB_USERNAME --body {Docker Hub 用户名}
gh variable set DEPLOY_HOST --body 10.126.56.21
gh variable set DEPLOY_USER --body yifei
```

为部署单独生成一把密钥，公钥追加到服务器，私钥和主机记录写入 Secrets：

```bash
ssh-keygen -t ed25519 -N "" -C hw11-deploy -f ~/.ssh/hw11_deploy_ed25519
cat ~/.ssh/hw11_deploy_ed25519.pub | ssh campus-jump 'cat >> ~/.ssh/authorized_keys'
ssh-keygen -F 10.126.56.21 | grep -v '^#' > /tmp/hw11_known_hosts
gh secret set SSH_PRIVATE_KEY < ~/.ssh/hw11_deploy_ed25519
gh secret set SSH_KNOWN_HOSTS < /tmp/hw11_known_hosts
```

`DOCKERHUB_TOKEN` 在网页上设置（见上表）。

### 3 注册本机 runner

deploy 在本机执行：服务器地址 `10.126.56.21` 是校内地址，GitHub 托管的 runner 连不进来；服务器的 Ubuntu 18.04 又运行不了新版 runner（自带的 Node 20 要求 glibc 2.28）；本机能 SSH 到服务器，因此作为中转。

```bash
mkdir -p ~/actions-runners/hw11 && cd ~/actions-runners/hw11
curl -fsSLO https://github.com/actions/runner/releases/download/v2.338.2/actions-runner-osx-arm64-2.338.2.tar.gz
shasum -a 256 actions-runner-osx-arm64-2.338.2.tar.gz     # 与发布页的 osx-arm64 校验值比对
tar xzf actions-runner-osx-arm64-2.338.2.tar.gz
./config.sh --unattended --url https://github.com/{用户名}/homework11-flask-cicd \
  --token "$(gh api -X POST repos/{用户名}/homework11-flask-cicd/actions/runners/registration-token --jq .token)" \
  --name hw11-mac --labels hw11-deploy --work _work
./svc.sh install && ./svc.sh start      # 用户级 launchd 服务
```

### 4 推送并观察

```bash
git push -u origin main
gh run watch
```

### 5 验证三处一致

```bash
ssh campus-jump 'docker inspect -f "{{.Config.Image}}" hw11-web; curl -s http://127.0.0.1:18011/version'
curl -s "https://hub.docker.com/v2/repositories/{用户名}/homework11-flask-cicd/tags?page_size=10"
git rev-parse HEAD
```

Docker Hub 的 SHA 标签、服务器上 `hw11-web` 的镜像标签和 `/version` 返回值都应等于 `git rev-parse HEAD`。

### 6 回滚验证与金丝雀演示（服务器上，在 `/home/yifei/homework11-cicd` 目录）

```bash
bash deploy.sh nginx:1.26.3 0000000                       # 新容器不通过检查，脚本恢复上一版，退出码 1
bash canary-demo.sh start {稳定版 SHA} {金丝雀版 SHA}
bash canary-demo.sh sample 100
bash canary-demo.sh weights 1 1
bash canary-demo.sh weights 0 1
bash canary-demo.sh weights 1 0
bash canary-demo.sh cleanup
```

## 访问与停止方法

### 访问

本机建立隧道后，浏览器打开 `http://127.0.0.1:18011`（页面）或 `http://127.0.0.1:18011/version`：

```bash
ssh -N -L 18011:127.0.0.1:18011 campus-jump
```

作业提交前，`hw11-web`、`hw11-redis` 和本机 runner 服务保持运行。

### 停止与移除

```bash
# 本机：停止并移除 runner
cd ~/actions-runners/hw11
./svc.sh stop && ./svc.sh uninstall
./config.sh remove --token "$(gh api -X POST repos/{用户名}/homework11-flask-cicd/actions/runners/remove-token --jq .token)"

# 服务器：只删除本作业的容器、网络和目录
ssh campus-jump 'docker rm -f hw11-web hw11-redis; docker network rm hw11-net; rm -rf /home/yifei/homework11-cicd'
ssh campus-jump "sed -i '/ hw11-deploy\$/d' ~/.ssh/authorized_keys"      # 撤销部署公钥

# 本机：删除部署私钥
rm ~/.ssh/hw11_deploy_ed25519 ~/.ssh/hw11_deploy_ed25519.pub
```
