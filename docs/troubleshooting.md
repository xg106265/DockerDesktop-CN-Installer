# 排障

## Docker 打不开（重启 Mac 后尤其常见）

**现象：** 后台引擎和容器仍在运行，但点图标没有界面；终端直接运行界面程序，退出码 `137`（被系统杀掉），`log show` 里有 `amfid ... The signature on the file is invalid`。

**根因：** 汉化改了 `Info.plist` 里的 asar 完整性哈希，界面程序的官方签名随之失效。系统在重启后重新校验时拒绝运行它（重启前靠缓存碰巧能用）。清除隔离标记（`xattr`）**不能**解决。

**处理：** 升级到 1.2.0+ 后重新运行脚本即可，它会检测到“汉化已写入但签名未修复”，只补一次重新签名，不重新下载：

```bash
bash localize.command          # 或: ./localize.command --check 先看状态 (退出码 10 即需修复)
```

确认签名状态：

```bash
codesign -dv "/Applications/Docker.app/Contents/MacOS/Docker Desktop.app" 2>&1 | grep Signature   # 应为 Signature=adhoc
codesign --verify --deep --strict "/Applications/Docker.app/Contents/MacOS/Docker Desktop.app" && echo 签名一致
```

重新签名要求不带 hardened runtime（ad-hoc 加 runtime 会因库校验失败，报 `Library not loaded ... different Team IDs`），脚本已按此处理，不要手动加 `--options runtime`。

## “Docker.app 已损坏，无法打开”

根因有三类，常常叠加：

| # | 根因 | 处理 |
|---|------|------|
| 1 | **`.app` 包里多了文件**（如 `Info.plist.bak`）。已签名的包多出任何文件都会破坏签名封印。 | 删除多余文件；本脚本不会往包里写任何额外文件。 |
| 2 | **对从未启动过的 Docker.app 改了内容。** 刚安装、带隔离标记的 app 首次启动要做完整评估，内容已被改动则评估失败，并留下难以清理的系统状态（之后连还原后的原版也会被拦）。 | 从 Docker.dmg 重新安装，**先正常打开一次并进入界面、退出**，再汉化。 |
| 3 | 之前用过别的汉化工具，包被改动得不干净。 | 重新安装原版后再汉化。 |

确认是不是第 1 类：

```bash
codesign --verify --deep --strict -vvv /Applications/Docker.app 2>&1 | grep -E "file (added|missing)"
```

对比安装包里的原版与已安装版本（只比较、不修改）：

```bash
rsync -rlcn --itemize-changes --delete "/Volumes/Docker/Docker.app/" /Applications/Docker.app/
```

## “Operation not permitted”

macOS 的 App 管理保护。到 系统设置 > 隐私与安全性 > App 管理，允许你使用的终端（后台任务则允许 `/bin/bash`），重开终端后重试。

## 其他

- 进程卡在 `_dyld_start`、没有任何输出：多半是系统的“已损坏”弹窗还没弹出或没被处理，不是 Docker 本身挂了。
- 提示“尚未发布汉化包”：汉化仓库还没出这个版本的包，稍后再试；不要用其他版本的包。
- 想彻底回到原版：`./localize.command --restore`；或把 Docker.app 移到废纸篓，从 Docker.dmg 重新安装。

## 重装系统 / 迁移 / 换用户名之后

| 情况 | 脚本的处理 |
|---|---|
| 全新系统，只装了 Docker | 提示先启动一次再汉化；之后一次运行即可，不需要任何旧状态 |
| 迁移后用户名/家目录变了，`state.json` 里的备份路径失效 | 自动到当前备份目录按目录名重新定位 |
| `state.json` 丢了，app 仍是原版，备份还在 | 按 `app.asar` 哈希找回已有备份并复用，不产生重复备份 |
| `state.json` 丢了，但 app 已是汉化版（如迁移助手只拷了 app） | 下载包后发现与本机 `app.asar` 完全一致，直接认领并重建记录，不重复安装 |
| 以上且没有任何备份 | 同样认领；此时无法 `--restore`，想还原请重新安装 Docker Desktop |
| Docker 装在非默认位置 | Spotlight 按 bundle id 查找；仍找不到则设置 `DDCN_DOCKER_APP` |
| 后台任务在换用户名后 | 任务命令用 `$HOME` 动态展开，仍有效；若日志提示找不到脚本，重新执行一次 `--install-agent` |
