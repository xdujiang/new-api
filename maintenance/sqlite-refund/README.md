# SQLite 订阅退款修复分支

仓库：https://github.com/xdujiang/new-api 。维护分支：`sqlite-refund-rc51`。
官方基线：`v1.0.0-rc.51` / `c9c6da2786b6a0912215127e78e28fbc6650c85f`，记录于 `upstream.json`。

修复 `RefundSubscriptionPreConsume` 已开启事务后，又通过全局 DB 开启独立事务的问题。退款金额和退款记录在同一事务里更新，避免 SQLite 写锁互等，也保证记录写入失败时金额一起回滚。保留 WAL、busy_timeout 和现有计费规则，不改数据库结构，不包含 PR #6090。此修复不能消除所有数据库锁，也不自动修正历史账目。

## 从 rc.49 升级到 rc.51

旧的 `sqlite-refund-rc49` 分支与镜像保留。本分支以上游正式发布的 rc.51 为基线，不跟踪未发布 main。上游 rc.51 仍存在独立退款事务，因此继续保留本地事务修复和三数据库回归测试。

这是跨版本更新，不能直接按同版本回退处理。先用一致备份演练隔离迁移，再安排停服备份和上线；Actions 部署需在完成演练后勾选 `allow_version_upgrade`。部署失败时不得直接让旧版本读取可能已经迁移的数据，按文末跨版本恢复流程操作。

上游发布说明：https://github.com/QuantumNous/new-api/releases/tag/v1.0.0-rc.51 。重点核对：

- rc.50 引入提供商插件、请求处理插件和插件市场；rc.51 修复部分无 AVX 的 x86-64 CPU 请求时崩溃的问题。
- 首次启动把旧敏感词设置迁移为 Request filter，并删除旧设置；降级后需要恢复配置或还原备份。
- 已完成的系统任务默认仅保留 30 天；需要保留更久时先核对日志维护设置。
- 使用 Vertex AI 视频时，核对渠道部署区域是否支持所用视频模型。

## GitHub 构建

1. 首次 fork 后，在 Actions 页面启用工作流。若推送发生在启用前，可在启用后向此分支推送新提交以触发构建。
2. 此分支代码、构建文件或维护文件发生变化时，`Build patched New API` 自动运行。它测试当前提交里的代码，不再下载和应用另一份补丁。
3. 使用一次性 SQLite 文件、MySQL 8.0、PostgreSQL 17 验证正常退款、重复退款、失败回滚和并发退款，再跑现有订阅回归测试。三数据库必须全部通过。
4. 使用上游 Dockerfile 完整编译前后端，构建 `linux/amd64`，推送 `ghcr.io/xdujiang/new-api-local:build-运行ID-尝试次数`。部署包保存成功后，同一已测试镜像另发布为 `ghcr.io/xdujiang/new-api-local:latest`；分支已有更新提交时，旧提交的构建不更新 latest。需要仓库允许 Actions 和 `packages: write`。当前 GHCR 包已公开，可匿名拉取。
5. 成功任务保存 `release-bundle` 和测试日志，保留 30 天。包内 `release.json` 含不可变镜像 digest、镜像 ID、源码提交和基线，部署时核对这些信息。请把实际部署过的制品和日志另行归档。

获取当前维护版本可以运行 `docker pull ghcr.io/xdujiang/new-api-local:latest`。latest 是可移动标签，拉取不会自动更新已有容器；生产升级仍需备份、重新创建容器并验证。需要重现或回退时使用对应构建编号标签或 digest。一键部署继续使用部署包内的固定 digest。迁移到后续版本维护分支时，应停止旧维护分支发布 latest，避免旧版本覆盖新版本。

只有 `workflow_dispatch` 的工作流通常需要先存在于仓库默认分支，网页才提供 Run workflow。若需要手动构建或下述部署入口，可把个人 fork 的默认分支设为 `sqlite-refund-rc51`，无需改上游默认分支。已有构建也可以使用 Re-run jobs；更新代码后应触发新的构建而不是重跑旧提交。

## 部署到当前 VPS

构建和生产部署分开。构建成功不代表已经上线。现有容器名 `new-api`，数据 `/root/new-api/data:/data`，端口 `127.0.0.1:28659:3000`，默认 bridge 网络。脚本会核对这些条件和 amd64 架构；配置不同需要先调整脚本。

服务器需要 Bash、Docker、jq、curl、tar、sha256sum 和 flock（通常由 util-linux 提供）；不需要 Python、Go 或 Bun。私有 GHCR 包先在服务器运行 `docker login ghcr.io -u xdujiang`，在提示处输入有包读取权限的 Token，不把 Token 放进命令、仓库或聊天。

### VPS 一条命令更新公开 latest

当前镜像已公开，不需要 GHCR 登录、GitHub Token 或手动下载上传部署包。更新入口、实际部署和回退均为 Bash，JSON 由 jq 解析，VPS 无需 Python。Debian/Ubuntu 首次缺少依赖时先执行 `apt-get update` 和 `apt-get install -y jq curl util-linux`，然后服务器 root 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/xdujiang/new-api/sqlite-refund-rc51/maintenance/sqlite-refund/update.sh -o /root/new-api-update.sh && bash /root/new-api-update.sh
```

更新器先加互斥锁，拉取 latest，校验镜像来源、架构、补丁标记与不可变 digest，并查询公开 GitHub API 确认该源码提交有成功的构建。然后从镜像标注的固定源码提交下载并校验部署脚本、核对上游基线，才签发本地部署凭据并调用 deploy.sh。不是从移动分支下载另一版部署脚本来搭配旧镜像。已运行同一镜像时直接结束；任何前置验证失败都不会停服。若 latest 尚未包含 Bash 部署脚本，更新器会停止并提示等待 shell 版本构建完成，不会调用旧的 Python 运行时。拉取镜像和公开 API 请求仍需要服务器能访问 GHCR、GitHub API 和 raw.githubusercontent.com。

后续在同一维护分支内，直接运行 `bash /root/new-api-update.sh` 即可再次更新。脚本会沿用原端口、数据目录和环境变量，停服备份、保留旧容器后切换，健康检查失败时按现有规则恢复。生产配置若超出原部署参数，deploy.sh 会停止并要求人工处理。维护窗口暂停请求，更新后仍须核对真实请求和账目。公开 GitHub API 有匿名访问额度；网络不可达、访问限流或构建尚未完成时需稍后重试。

从 rc.49 升到 rc.51 属于跨版本。完成本文迁移演练后，显式执行 `bash /root/new-api-update.sh --upgrade`；默认命令会拒绝跨版本切换。`--upgrade` 不代表跳过备份，也不会在失败后自动让旧二进制读取可能已经迁移的数据。脚本输出部署文件目录、备份目录和回退命令，请保留。迁移到其他维护分支时，重新下载该分支的更新器并阅读对应升级说明。

### Actions SSH 部署

将个人 fork 默认分支设为本维护分支；创建 GitHub Environment `production`，配置以下 Secrets：

- `SSH_HOST`：VPS IPv4 地址或域名。
- `SSH_PORT`：SSH 端口，通常为 `22`。
- `SSH_PRIVATE_KEY`：用于 VPS root 登录的专用部署密钥，公钥需预先加入服务器。GitHub 推送密钥与 VPS 部署密钥用途不同。
- `SSH_KNOWN_HOSTS`：通过已信任连接或云控制台核验的服务器主机公钥。非 22 端口用 `[主机]:端口` 格式。

完成这些一次性配置后，日常部署只需打开 Actions → `Deploy patched New API` → Run workflow，选择 `sqlite-refund-rc51` 分支，保持 `build_run_id` 为空、`allow_version_upgrade=false`，点击运行。工作流自动选择本分支最近一次成功构建、下载部署包、上传 VPS 并部署，无需手动下载上传，也不必手动填写构建 ID。若需部署某次指定构建，可以填写它的 run ID；不接受其他分支的构建。没有成功构建或制品已过期时会停止，需先运行新构建。

部署会短暂中断服务，请选择维护窗口并暂停客户端和入站流量。工作流校验构建状态和制品来源、按 digest 拉取镜像、核对测试凭据、停容器、备份完整数据目录、保留旧容器再启动新镜像。同版本启动失败会自动切回旧容器；启动日志只保留在 VPS 的备份目录。源码 push 只自动构建，不会自动部署生产。跨版本升级完成迁移演练后才启用 `allow_version_upgrade`。

GitHub runner 必须能连接 VPS 的 SSH 端口。也可以下载 Actions 的 `release-bundle`，上传并解压至 `/root/new-api-releases/构建ID-部署ID/`（两个 ID 均为数字），在 VPS 执行：

```bash
bash /root/new-api-releases/构建ID-部署ID/kit/ci/remote-deploy.sh /root/new-api-releases/构建ID-部署ID
```

上线后先核对 `/api/status` 版本为 `v1.0.0-rc.51-local-refund1`，验证一次真实请求和失败退款，核对账目、检查 `database is locked` 日志，再恢复流量。HTTP 启动健康检查不能代替真实计费验证。

备份位于 `/root/new-api/backups/时间戳/`。首次同版本修复需要回退时，暂停流量，在所用制品的 kit 目录执行 `bash rollback.sh /root/new-api/backups/时间戳`；旧容器和数据目录应保留。

## 后续维护和更新

保持 `main` 跟踪官方；在维护分支提交自己的小改动。不要把官方 main 直接合入固定发布版的生产分支，也不要跟随 `latest` 自动替换生产镜像。修复和 CI 使用独立提交，便于移植。

更新版本时，先阅读官方更新说明、备份生产数据，新增以上游目标标签为起点的维护分支。检查退款逻辑是否已修复；未修复则 cherry-pick 本分支的修复和测试提交。移植 maintenance 目录和两个 sqlite-refund 工作流，更新 `upstream.json` 的版本、完整 SHA，以及工作流中分支过滤和分支校验。检查上游 Dockerfile 和相关函数变化，解决冲突后执行 `python3 maintenance/sqlite-refund/ci/refresh-checksums.py`，提交并运行完整三数据库测试、前后端构建。上游已等价修复时删除本地生产代码补丁，保留适用的回归测试。

跨版本更新必须先演练迁移：停止客户端，停止旧容器以取得一致备份，然后恢复旧服务；在另一目录解压备份，使用 `--network none`、不发布端口的临时候选容器运行新镜像，检查迁移结果和日志。演练目录绝不能指向生产 `/root/new-api/data`。临时容器应复制所需配置，但禁止外部调用；有外部数据库或外部副作用的配置需要单独隔离。完成迁移与业务验证后安排维护窗口，再使用部署工作流的 `allow_version_upgrade=true`。

跨版本启动失败可能已经修改数据库。脚本会停下候选容器，不自动用旧二进制读取迁移后的数据。暂停流量、停止新容器，保留失败现场，再从该次停服备份恢复完整数据目录，确认恢复后才执行 `bash rollback.sh /root/new-api/backups/时间戳 --data-restored`。首次上线恢复流量后若回退旧备份，会丢失备份之后的写入，必须先核对账目和恢复范围。

本地只能完成 SQLite 回归及工作流静态检查；完整三数据库和 Linux 镜像验证以 Actions 实际结果为准。生产部署需另行配置服务器 Secrets 并手动执行。
