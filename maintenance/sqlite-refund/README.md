# SQLite 订阅退款修复分支

仓库：https://github.com/xdujiang/new-api 。维护分支：`sqlite-refund-rc49`。
官方基线：`v1.0.0-rc.49` / `48a6c87f9e7757fdc58e5be9bcb4f8281ad0dfd0`，记录于 `upstream.json`。

修复 `RefundSubscriptionPreConsume` 已开启事务后，又通过全局 DB 开启独立事务的问题。退款金额和退款记录在同一事务里更新，避免 SQLite 写锁互等，也保证记录写入失败时金额一起回滚。保留 WAL、busy_timeout 和现有计费规则，不改数据库结构，不包含 PR #6090。此修复不能消除所有数据库锁，也不自动修正历史账目。

## GitHub 构建

1. 首次 fork 后，在 Actions 页面启用工作流。若推送发生在启用前，可在启用后向此分支推送新提交以触发构建。
2. 此分支代码、构建文件或维护文件发生变化时，`Build patched New API` 自动运行。它测试当前提交里的代码，不再下载和应用另一份补丁。
3. 使用一次性 SQLite 文件、MySQL 8.0、PostgreSQL 17 验证正常退款、重复退款、失败回滚和并发退款，再跑现有订阅回归测试。三数据库必须全部通过。
4. 使用上游 Dockerfile 完整编译前后端，构建 `linux/amd64`，推送 `ghcr.io/xdujiang/new-api-local:build-运行ID-尝试次数`。需要仓库允许 Actions 和 `packages: write`。首次发布后核对 GHCR 包访问权限；私有包需要服务器登录 GHCR。
5. 成功任务保存 `release-bundle` 和测试日志，保留 30 天。包内 `release.json` 含不可变镜像 digest、镜像 ID、源码提交和基线，部署时核对这些信息。请把实际部署过的制品和日志另行归档。

只有 `workflow_dispatch` 的工作流通常需要先存在于仓库默认分支，网页才提供 Run workflow。若需要手动构建或下述部署入口，可把个人 fork 的默认分支设为 `sqlite-refund-rc49`，无需改上游默认分支。已有构建也可以使用 Re-run jobs；更新代码后应触发新的构建而不是重跑旧提交。

## 部署到当前 VPS

构建和生产部署分开。构建成功不代表已经上线。现有容器名 `new-api`，数据 `/root/new-api/data:/data`，端口 `127.0.0.1:28659:3000`，默认 bridge 网络。脚本会核对这些条件和 amd64 架构；配置不同需要先调整脚本。

服务器需要 Docker、Python 3、curl、tar、sha256sum；不需要 Go 或 Bun。私有 GHCR 包先在服务器运行 `docker login ghcr.io -u xdujiang`，在提示处输入有包读取权限的 Token，不把 Token 放进命令、仓库或聊天。

### Actions SSH 部署

将个人 fork 默认分支设为本维护分支；创建 GitHub Environment `production`，配置以下 Secrets：

- `SSH_HOST`：VPS IPv4 地址或域名。
- `SSH_PORT`：SSH 端口，通常为 `22`。
- `SSH_PRIVATE_KEY`：用于 VPS root 登录的专用部署密钥，公钥需预先加入服务器。GitHub 推送密钥与 VPS 部署密钥用途不同。
- `SSH_KNOWN_HOSTS`：通过已信任连接或云控制台核验的服务器主机公钥。非 22 端口用 `[主机]:端口` 格式。

维护窗口暂停客户端和入站流量，再运行 `Deploy patched New API`，输入成功构建的 run ID，首次同版本修复保持 `allow_version_upgrade=false`。部署会校验构建状态和制品来源、按 digest 拉取镜像、核对测试凭据、停容器、备份完整数据目录、保留旧容器再启动新镜像。同版本启动失败会自动切回旧容器；启动日志只保留在 VPS 的备份目录。

GitHub runner 必须能连接 VPS 的 SSH 端口。也可以下载 Actions 的 `release-bundle`，上传并解压至 `/root/new-api-releases/构建ID-部署ID/`（两个 ID 均为数字），在 VPS 执行：

```bash
bash /root/new-api-releases/构建ID-部署ID/kit/ci/remote-deploy.sh /root/new-api-releases/构建ID-部署ID
```

上线后先核对 `/api/status` 版本为 `v1.0.0-rc.49-local-refund1`，验证一次真实请求和失败退款，核对账目、检查 `database is locked` 日志，再恢复流量。HTTP 启动健康检查不能代替真实计费验证。

备份位于 `/root/new-api/backups/时间戳/`。首次同版本修复需要回退时，暂停流量，在所用制品的 kit 目录执行 `bash rollback.sh /root/new-api/backups/时间戳`；旧容器和数据目录应保留。

## 后续维护和更新

保持 `main` 跟踪官方；在维护分支提交自己的小改动。不要把官方 main 直接合入 rc.49 生产分支，也不要跟随 `latest` 自动替换生产镜像。修复和 CI 使用独立提交，便于移植。

更新版本时，先阅读官方更新说明、备份生产数据，新增以上游目标标签为起点的维护分支。检查退款逻辑是否已修复；未修复则 cherry-pick 本分支的修复和测试提交。移植 maintenance 目录和两个 sqlite-refund 工作流，更新 `upstream.json` 的版本、完整 SHA，以及工作流中分支过滤和分支校验。检查上游 Dockerfile 和相关函数变化，解决冲突后执行 `python3 maintenance/sqlite-refund/ci/refresh-checksums.py`，提交并运行完整三数据库测试、前后端构建。上游已等价修复时删除本地生产代码补丁，保留适用的回归测试。

跨版本更新必须先演练迁移：停止客户端，停止旧容器以取得一致备份，然后恢复旧服务；在另一目录解压备份，使用 `--network none`、不发布端口的临时候选容器运行新镜像，检查迁移结果和日志。演练目录绝不能指向生产 `/root/new-api/data`。临时容器应复制所需配置，但禁止外部调用；有外部数据库或外部副作用的配置需要单独隔离。完成迁移与业务验证后安排维护窗口，再使用部署工作流的 `allow_version_upgrade=true`。

跨版本启动失败可能已经修改数据库。脚本会停下候选容器，不自动用旧二进制读取迁移后的数据。暂停流量、停止新容器，保留失败现场，再从该次停服备份恢复完整数据目录，确认恢复后才执行 `bash rollback.sh /root/new-api/backups/时间戳 --data-restored`。首次上线恢复流量后若回退旧备份，会丢失备份之后的写入，必须先核对账目和恢复范围。

本地只能完成 SQLite 回归及工作流静态检查；完整三数据库和 Linux 镜像验证以 Actions 实际结果为准。生产部署需另行配置服务器 Secrets 并手动执行。
