# DockerDesktop-CN-Installer

macOS 上 Docker Desktop 汉化一键安装器：自动识别版本与架构，下载匹配的汉化包，校验后安装，失败自动回滚。

只依赖 macOS 自带工具（bash、curl、unzip、shasum、PlistBuddy），无需 Python / Node。汉化包来自 [asxez/DockerDesktop-CN](https://github.com/asxez/DockerDesktop-CN) 的 Release，本仓库不分发汉化包。

## 快速开始

先**正常启动一次 Docker Desktop 并退出**（原因见[注意事项](#注意事项)），然后：

```bash
curl -fsSLO https://raw.githubusercontent.com/xg106265/DockerDesktop-CN-Installer/main/localize.command
bash localize.command
```

## 命令

| 命令 | 说明 |
|---|---|
| `./localize.command` | 汉化；已汉化则无操作 |
| `--check` | 仅检查状态，退出码 `0` 已汉化 / `10` 未汉化 / `11` 未找到 Docker |
| `--restore` | 还原为原版 |
| `--force` | 已汉化时强制重新安装 |
| `--auto` | 无交互：仅在汉化失效时下载并重装 |
| `--install-agent` / `--uninstall-agent` | 安装 / 卸载后台任务（登录、每小时、Docker 更新时执行 `--auto`） |
| `--version X.Y.Z` `--repo owner/name` `--file app.zip` `--yes` | 指定版本 / 汉化仓库 / 离线包 / 默认确认 |

环境变量：`DDCN_REPO` 汉化仓库，`DDCN_PROXY_PREFIX` 下载加速前缀，`DDCN_DOCKER_APP` Docker.app 路径，`NO_LAUNCH=1` 安装后不启动 Docker。

后台任务读不到终端里的环境变量，需要持久生效的设置请写入 `~/Library/Application Support/DockerDesktop-CN/config`（每行 `KEY=VALUE`，支持前三项）；执行 `--install-agent` 时会自动把当前生效的非默认设置写进去。

## Docker 升级后

升级会覆盖汉化。手动再运行一次脚本，或执行一次 `--install-agent` 让它自动完成。汉化包通常在 Docker 新版本发布后一两天内出现；在此之前脚本只提示“尚未发布”，不会改动任何文件，也不会用其他版本的包代替（版本不符会导致 Docker 无法启动）。

## 工作流程

1. 读取 `Info.plist` 的版本号（即汉化仓库 Release 的 tag）、构建号，用 `lipo` 判断架构。
2. 经 GitHub API 取得 `app-Mac-{apple,intel}.zip` 的地址与 SHA256，下载并校验。
3. 校验汉化包版本、构建号与本机一致，`app.asar` 头部哈希与包内记录一致。
4. 备份原版；替换 `app.asar` 与 `app.asar.unpacked`；将 asar 头部 SHA256 写入 `Info.plist` 的 `ElectronAsarIntegrity`。
5. 复核写入结果；任一步失败即从备份回滚。

备份位于 `~/Library/Application Support/DockerDesktop-CN/backup/`，状态文件为同目录下的 `state.json`，后台任务日志在 `~/Library/Logs/DockerDesktop-CN-auto.log`。

## 注意事项

- **先启动一次再汉化。** 从未启动过的 Docker.app 首次启动时系统会做完整评估，此时内容已被改动会被判为“已损坏”。脚本检测到会提醒。
- **需要 App 管理权限。** 在 系统设置 › 隐私与安全性 › App 管理 中允许所用终端（后台任务需允许 `/bin/bash`），否则写入报 `Operation not permitted`。
- **`codesign` 提示 `invalid Info.plist` 属预期**，脚本只改动该文件的完整性哈希，绝不向 `.app` 内写入其他文件（多出任何文件都会触发“已损坏”）。
- **信任第三方汉化包。** 它会替换 Docker Desktop 的前端代码；SHA256 只防下载损坏，不能证明来源可信。请确认你信任 `--repo` 指定的仓库。
- **重装系统 / 迁移 / 换用户名**：脚本不依赖固定路径。Docker 位置按 `/Applications`、`~/Applications`、Spotlight（bundle id）依次查找；状态文件里的备份路径失效时会自动到备份目录重新定位，状态丢失时按哈希找回备份，已是汉化版的 app 会被直接认领。全新系统上只需：安装 Docker → 启动一次并退出 → 运行脚本。
- Docker.app 属于 root 或其他用户时，用 `sudo bash localize.command`；状态和备份仍记在你自己的家目录下。
- 仅支持 macOS；Windows 请使用汉化仓库 Release 中的 `app-Windows-*.zip`。

遇到“已损坏”等问题见 [docs/troubleshooting.md](docs/troubleshooting.md)。

## 许可

脚本以 [MIT](LICENSE) 发布。汉化内容归 [asxez/DockerDesktop-CN](https://github.com/asxez/DockerDesktop-CN) 所有。Docker 是 Docker, Inc. 的商标，本项目与其无关联。
