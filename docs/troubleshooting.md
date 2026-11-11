# 排障：“已损坏”与 “Operation not permitted”

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
