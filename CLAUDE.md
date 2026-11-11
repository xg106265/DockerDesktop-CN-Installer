# CLAUDE.md

macOS 上 Docker Desktop 汉化一键安装器。单文件 bash 脚本 `localize.command`：识别本机 Docker 版本/构建号/架构 → 从汉化仓库（默认 `asxez/DockerDesktop-CN`）的 Release 下载匹配的 `app-Mac-{apple,intel}.zip` → 校验 → 备份原版 → 替换 `app.asar` 与 `app.asar.unpacked` 并改写 `Info.plist` 里的完整性哈希。本仓库**不构建、不分发**汉化包。

## 命令

```bash
bash tests/run.sh                 # 全部端到端测试 (约 1 分钟，会真实访问 GitHub 下载汉化包)
bash -n localize.command          # 语法检查，改完脚本必跑
./localize.command --check        # 只读: 退出码 0=已汉化 10=未汉化 11=未找到 Docker
```

`tests/run.sh` 需要一份**未汉化**的原版文件，用 `DDCN_TEST_ORIG=/path` 指定，默认取 `~/Library/Application Support/DockerDesktop-CN/backup/` 里最新的 `*-orig-*`。没有 lint/构建步骤。

## 结构

- `localize.command` 自上而下依次是：参数解析 → 工具函数 → 后台任务(launchd) → 定位 Docker → `--check`/`--restore` → 安装前检查 → 获取并校验汉化包 → 备份 → 写入 → 校验 → 记录状态。
- 状态在 `~/Library/Application Support/DockerDesktop-CN/`：`state.json`（原版备份位置、汉化版 `app.asar` 哈希、版本、来源）、`backup/<时间>-orig-<版本>/`、`config`（持久化的 `DDCN_*` 设置）。
- `state.json` 的键名（`pristine_dir` / `patched_sha256` / `version`）与汉化原仓库的 Python 工具兼容，**不要改名**。
- "已汉化"的判据是：当前 `app.asar` 的 SHA256 == `state.json` 的 `patched_sha256`。Docker 升级会覆盖文件，该判据随之失效，`--auto` 据此重装。

## 必须遵守（都是踩过的坑）

- **绝不往 `.app` 包里写除 `app.asar`、`app.asar.unpacked`、`Info.plist` 中完整性哈希之外的任何东西**（包括 `.bak`）。包内多出任何文件会破坏签名封印，系统提示“已损坏”。备份只放在 `backup/`。
- **写入阶段的失败必须回滚。** 所有会修改 `.app` 的步骤都放在 `IN_WRITE=1` 窗口内；出错一律走 `die()`（它会先 `restore_from`），不要裸 `exit`——`exit` 不会触发 ERR trap。
- **目录替换用 `replace_dir`**，不要 `rm -rf` 后直接 `cp -R A B`：删除失败时 B 仍存在，会变成 `B/A` 嵌套。
- **asar 完整性哈希** = asar 头部 JSON 字符串的 SHA256：头长度在文件偏移 12（uint32），字符串从偏移 16 开始，见 `asar_header_hash`。不要用别的算法或整文件哈希。
- **不改动从未启动过的 Docker.app**（首次启动评估会判为“已损坏”）：以 `~/Library/Containers/com.docker.docker` 是否存在判断。
- 版本必须与汉化包严格匹配（版本号 + 构建号 `CFBundleVersion`），**不要用相近版本的包凑合**，会导致 Docker 无法启动。
- 不依赖固定路径：Docker 位置走 `find_app`（`/Applications` → `~/Applications` → Spotlight），备份路径走 `resolve_pristine`/`scan_backup_for`，`$HOME` 在 `sudo` 下要取真实用户的。

## 代码约定

- **兼容 macOS 自带的 bash 3.2**：不用关联数组、`mapfile`、`${var,,}`、`source <(...)`（会**静默不执行**，不报错；`while read ... done < <(...)` 可以）。只用系统自带工具，不引入 Python/Node/jq；解析 JSON 用 `osascript -l JavaScript`。
- 脚本使用 `set -Eeuo pipefail`。管道里下游提前退出会触发 SIGPIPE 导致整条失败，参见 `asar_header_hash` 用 `head -c` 在前、`tail -c +` 在后的写法。
- 面向用户的输出用中文，通过 `say`/`info`/`warn`/`die`；自动模式（`--auto`）全程无交互，结果用 `notify` 弹系统通知。
- 改动了行为就同步更新 `README.md`（保持简洁）和 `docs/troubleshooting.md`。提交信息用中文并带 `feat:`/`fix:`/`docs:` 前缀。

## 测试

- **永远不要拿真实的 `/Applications/Docker.app` 做破坏性测试，也不要在测试里退出用户正在运行的 Docker。** 测试用“假 Docker.app + 临时家目录”，通过环境变量隔离：`DDCN_DOCKER_APP`（指向假 app）、`DDCN_HOME`（状态/备份目录）。`docker_running` 的 `pgrep` 是按 app 路径匹配的，所以不会误杀真实 Docker。
- 仅供测试的环境变量：`DDCN_ARCH=apple|intel`（绕过 `lipo`）、`DDCN_ASSUME_LAUNCHED=1`（跳过“是否启动过”检查）、`DDCN_AUTO_DELAY=1`（缩短自动模式等待）、`NO_LAUNCH=1`（不启动 Docker）。
- 新增/修改写入逻辑时，要在 `tests/run.sh` 里补用例，并**确认失败注入真的走到了你要测的代码**：用 `chflags uchg` 锁一个文件可以制造“权限位可写但实际写不进去”的失败（等价于 App Management 拦截），但锁 `Info.plist` 会先被写权限预检拦下，要测回滚应锁 `app.asar.unpacked` 里的文件。
- 开发用 shell 里 `rm` 可能被别名为 `trash`（目标不存在时报错并中断 `&&` 链），脚本和测试里用 `/bin/rm`。

## 范围与权限

- 仅 macOS。Windows/Linux 请直接用汉化仓库 Release 里自带的安装脚本。
- `--install-agent` 会注册常驻的 launchd 任务，属于用户的持久配置：开发/测试时不要在真实环境里执行（测试里用 `launchctl` 桩）。
- 未经用户明确同意，不要创建 Release、推送或改动 GitHub 仓库设置。
