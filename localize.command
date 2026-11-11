#!/bin/bash
# Docker Desktop 汉化一键安装器 (macOS)
#
# 识别本机 Docker Desktop 的版本和架构 -> 到汉化仓库下载对应的汉化包 -> 校验 -> 备份原版 -> 安装汉化。
# 只依赖 macOS 自带工具 (bash / curl / unzip / shasum / PlistBuddy / osascript)，不需要 Python、Node。
#
# 用法:
#   ./localize.command                  汉化 (已汉化则提示无需处理)
#   ./localize.command --check          只检查状态，不修改任何东西 (退出码 0=已汉化 10=未汉化 11=未找到 Docker)
#   ./localize.command --auto           自动模式: 仅当汉化失效(如 Docker 升级后)时下载并重新汉化，全程无交互
#   ./localize.command --restore        还原为原版
#   ./localize.command --force          即使已汉化也重新下载安装
#   ./localize.command --install-agent  安装后台任务: 登录时/每小时/Docker 更新时自动执行 --auto
#   ./localize.command --uninstall-agent
# 选项:
#   --version X.Y.Z   指定汉化包版本 (默认取本机 Docker Desktop 版本)
#   --repo owner/name 指定汉化仓库 (默认 asxez/DockerDesktop-CN，也可用环境变量 DDCN_REPO)
#   --file app.zip    使用本地已下载的汉化包 (离线安装)
#   --yes             所有确认默认选“是”
# 环境变量:
#   DDCN_PROXY_PREFIX  下载加速前缀 (拼在下载地址前面，例如你自己信任的 GitHub 代理)
#   DDCN_DOCKER_APP    Docker.app 不在 /Applications 时手动指定路径
#   NO_LAUNCH=1        安装后不自动启动 Docker
set -Eeuo pipefail

INSTALLER_VERSION="1.0.0"
REPO="${DDCN_REPO:-asxez/DockerDesktop-CN}"
STATE_DIR="${DDCN_HOME:-$HOME/Library/Application Support/DockerDesktop-CN}"
STATE_FILE="$STATE_DIR/state.json"
BACKUP_ROOT="$STATE_DIR/backup"
AGENT_LABEL="com.dockerdesktop-cn.autolocalize"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
AGENT_LOG="$HOME/Library/Logs/DockerDesktop-CN-auto.log"
AGENT_SCRIPT="$STATE_DIR/localize.command"

MODE=install; FORCE=0; AUTO=0; YES=0; VERSION=""; LOCAL_ZIP=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) MODE=check ;;
        --auto) AUTO=1; YES=1 ;;
        --restore) MODE=restore ;;
        --force) FORCE=1 ;;
        --yes|-y) YES=1 ;;
        --install-agent) MODE=install-agent ;;
        --uninstall-agent) MODE=uninstall-agent ;;
        --version) VERSION="${2:?--version 需要参数}"; shift ;;
        --repo) REPO="${2:?--repo 需要参数}"; shift ;;
        --file) LOCAL_ZIP="${2:?--file 需要参数}"; shift ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "未知参数: $1 (使用 --help 查看用法)"; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------- 输出
say()  { printf '\033[1;32m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m提示: %s\033[0m\n' "$*"; }
notify() {
    [[ $AUTO -eq 1 ]] || return 0
    osascript -e "display notification \"$1\" with title \"Docker Desktop 汉化\"" >/dev/null 2>&1 || true
}
die() {
    printf '\033[1;31m错误: %s\033[0m\n' "$*" >&2
    # 写入阶段出错必须回滚，否则会留下“asar 已换、完整性哈希未更新”的半成品，Docker 将无法启动
    if [[ "${IN_WRITE:-0}" -eq 1 && -n "${PRISTINE:-}" && -f "$PRISTINE/app.asar" ]]; then
        printf '\033[1;33m正在自动还原为原版...\033[0m\n' >&2
        IN_WRITE=0
        restore_from "$PRISTINE" || true
    fi
    notify "失败: $*"
    exit 1
}
ask() {  # ask "问题" -> 0=是 1=否 (自动/--yes 模式默认是)
    [[ $YES -eq 1 ]] && return 0
    local a; read -r -p "$1 (y/N) " a || a=n
    [[ "$a" =~ ^[yY] ]]
}

# ---------------------------------------------------------------- 定位 Docker
find_app() {
    local c
    for c in "${DDCN_DOCKER_APP:-}" /Applications/Docker.app "$HOME/Applications/Docker.app"; do
        [[ -n "$c" && -f "$c/Contents/MacOS/Docker Desktop.app/Contents/Resources/app.asar" ]] && { echo "$c"; return 0; }
    done
    return 1
}

[[ "$(uname)" == "Darwin" ]] || die "目前仅支持 macOS (Windows 请直接使用汉化仓库 Release 里的 app-Windows-*.zip)"

plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }
sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
# Electron 的 asar 完整性校验值 = asar 头部 JSON 字符串的 SHA256 (头长度在偏移 12，字符串从偏移 16 开始)
asar_header_hash() {
    local n; n="$(od -An -tu4 -j12 -N4 "$1" | tr -d ' ')"
    head -c "$((16 + n))" "$1" | tail -c +17 | shasum -a 256 | awk '{print $1}'
}

state_get() { sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" "$STATE_FILE" 2>/dev/null | head -1 || true; }
state_write() {  # pristine_dir patched_sha256 version source
    mkdir -p "$STATE_DIR"
    printf '{\n  "pristine_dir": "%s",\n  "patched_sha256": "%s",\n  "version": "%s",\n  "source": "%s"\n}\n' \
        "$1" "$2" "$3" "$4" > "$STATE_FILE"
}

# ---------------------------------------------------------------- 后台任务
if [[ "$MODE" == "uninstall-agent" ]]; then
    launchctl bootout "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1 || true
    rm -f "$AGENT_PLIST"
    say "已卸载自动汉化后台任务"; exit 0
fi
if [[ "$MODE" == "install-agent" ]]; then
    APP="$(find_app)" || die "未找到 Docker Desktop，请先安装"
    mkdir -p "$STATE_DIR" "$(dirname "$AGENT_PLIST")" "$(dirname "$AGENT_LOG")"
    cp -f "$0" "$AGENT_SCRIPT"; chmod +x "$AGENT_SCRIPT"   # 后台任务用固定位置的副本，不依赖你把仓库放在哪
    cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$AGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array><string>/bin/bash</string><string>$AGENT_SCRIPT</string><string>--auto</string></array>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>3600</integer>
    <key>WatchPaths</key><array><string>$APP/Contents/Info.plist</string></array>
    <key>ThrottleInterval</key><integer>300</integer>
    <key>StandardOutPath</key><string>$AGENT_LOG</string>
    <key>StandardErrorPath</key><string>$AGENT_LOG</string>
</dict>
</plist>
PLIST
    plutil -lint "$AGENT_PLIST" >/dev/null || die "生成的 plist 无效: $AGENT_PLIST"
    launchctl bootout "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
    say "已安装后台任务: 登录时、每小时、Docker.app 更新时自动检查，汉化失效就重新汉化"
    info "日志: $AGENT_LOG"
    warn "后台运行同样需要 App 管理权限；日志里出现 Operation not permitted 时，请到"
    warn "系统设置 > 隐私与安全性 > App 管理 中允许 /bin/bash"
    exit 0
fi

# ---------------------------------------------------------------- 基本信息
APP="$(find_app)" || { [[ "$MODE" == "check" ]] && { echo "未找到 Docker Desktop"; exit 11; }; \
    [[ $AUTO -eq 1 ]] && exit 0; die "未找到 Docker Desktop，请先安装并至少启动一次"; }
INNER="$APP/Contents/MacOS/Docker Desktop.app/Contents"
RES="$INNER/Resources"
INFO="$INNER/Info.plist"

INSTALLED_VERSION="$(plist_get "$INFO" CFBundleShortVersionString)"
INSTALLED_BUILD="$(plist_get "$INFO" CFBundleVersion)"
[[ -n "$VERSION" ]] || VERSION="$INSTALLED_VERSION"

case "${DDCN_ARCH:-}" in
    apple|intel) ARCH="$DDCN_ARCH" ;;
    *)
        case "$(lipo -archs "$INNER/MacOS/Docker Desktop" 2>/dev/null || true)" in
            *arm64*) ARCH=apple ;;
            *x86_64*) ARCH=intel ;;
            *) [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" == "1" ]] && ARCH=apple || ARCH=intel ;;
        esac ;;
esac
ASSET="app-Mac-$ARCH.zip"

docker_running() { pgrep -f "$INNER/MacOS/Docker Desktop" >/dev/null 2>&1; }

# 0=已是脚本写入的汉化版 10=未汉化
localized_status() {
    local patched; patched="$(state_get patched_sha256)"
    [[ -n "$patched" && "$patched" == "$(sha256_of "$RES/app.asar")" ]]
}

if [[ "$MODE" == "check" ]]; then
    if localized_status; then
        echo "已汉化: Docker Desktop $INSTALLED_VERSION ($ARCH)"; exit 0
    fi
    echo "未汉化或汉化已失效: Docker Desktop $INSTALLED_VERSION ($ARCH)"; exit 10
fi

# ---------------------------------------------------------------- 签名封印检查
# 输出: intact | plist(仅 Info.plist 被改，汉化后的预期状态) | broken(包内多/少了文件) | unsigned
bundle_state() {
    local out; out="$(codesign --verify --deep --strict -vv "$APP" 2>&1 || true)"
    if grep -qE "not signed at all|bundle format unrecognized" <<<"$out"; then echo unsigned
    elif grep -qE "^file (added|missing)|a sealed resource is missing" <<<"$out"; then echo broken
    elif grep -q "invalid Info.plist" <<<"$out"; then echo plist
    elif grep -q "satisfies its Designated Requirement\|valid on disk" <<<"$out"; then echo intact
    else echo broken; fi
}
seal_extras() { codesign --verify --deep --strict -vv "$APP" 2>&1 | grep -E "^file (added|missing)" || true; }

# ---------------------------------------------------------------- 还原
IN_WRITE=0
restore_from() {  # restore_from <pristine_dir>
    local d="$1"
    cp -f "$d/app.asar" "$RES/app.asar"
    if [[ -d "$d/app.asar.unpacked" ]]; then
        rm -rf "$RES/app.asar.unpacked"; cp -R "$d/app.asar.unpacked" "$RES/app.asar.unpacked"
    fi
    if [[ -f "$d/Info.plist" ]] && ! cmp -s "$d/Info.plist" "$INFO"; then cp -f "$d/Info.plist" "$INFO"; fi
    return 0
}
on_err() {
    local rc=$?
    trap - ERR
    if [[ $IN_WRITE -eq 1 && -n "${PRISTINE:-}" && -f "$PRISTINE/app.asar" ]]; then
        printf '\033[1;31m安装过程中出错 (退出码 %s)，正在自动还原为原版...\033[0m\n' "$rc" >&2
        restore_from "$PRISTINE" || true
    fi
    exit "$rc"
}
trap on_err ERR

if [[ "$MODE" == "restore" ]]; then
    PRISTINE="$(state_get pristine_dir)"
    [[ -n "$PRISTINE" && -f "$PRISTINE/app.asar" ]] || die "没有找到原版备份，无法还原"
    cur="$(sha256_of "$RES/app.asar")"
    if [[ "$cur" != "$(state_get patched_sha256)" && "$cur" != "$(sha256_of "$PRISTINE/app.asar")" ]]; then
        die "当前 Docker Desktop 与备份不是同一版本 (可能已升级)，已取消还原以免覆盖新版本"
    fi
    if docker_running; then
        say "正在退出 Docker Desktop"
        osascript -e 'tell application "Docker" to quit' >/dev/null 2>&1 || true
        for _ in $(seq 1 30); do docker_running || break; sleep 1; done
    fi
    restore_from "$PRISTINE"
    state_write "$PRISTINE" "" "$INSTALLED_VERSION" ""
    say "已还原为原版 ($PRISTINE)"; exit 0
fi

# ---------------------------------------------------------------- 安装前检查
if localized_status && [[ $FORCE -eq 0 ]]; then
    say "已汉化 (Docker Desktop $INSTALLED_VERSION)，无需处理。需要重装请加 --force"; exit 0
fi

say "Docker Desktop $INSTALLED_VERSION (构建 $INSTALLED_BUILD, $ARCH)"
if [[ $AUTO -eq 1 ]]; then
    say "检测到汉化失效 (Docker 可能刚升级)，开始自动汉化"
    LOCK="${TMPDIR:-/tmp}/dockerdesktop-cn-auto.lock"
    mkdir "$LOCK" 2>/dev/null || { echo "已有自动汉化任务在运行，退出"; exit 0; }
    trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
    sleep "${DDCN_AUTO_DELAY:-20}"   # 等 Docker 的升级过程写完文件
fi

# 1) 从未启动过的 Docker.app，系统首次启动时会做完整评估；此时改动内容会被判定为“已损坏”
if [[ -z "${DDCN_ASSUME_LAUNCHED:-}" ]] \
   && [[ ! -d "$HOME/Library/Containers/com.docker.docker" && ! -d "$HOME/Library/Group Containers/group.com.docker" ]]; then
    if [[ $AUTO -eq 1 ]]; then
        notify "Docker 尚未首次启动，请先正常打开一次再汉化"; echo "Docker 从未启动过，跳过"; exit 0
    fi
    warn "这台电脑上 Docker Desktop 还没有正常启动过。对从未启动过的 Docker.app 改动内容，"
    warn "系统首次启动时可能提示“已损坏”。请先在访达中右键 > 打开 Docker，进入界面后退出，再运行本脚本。"
    ask "仍要继续吗？" || { echo "已取消"; exit 1; }
fi

# 2) 当前 .app 必须是“没被改过的原版”（或之前由本脚本汉化过），否则备份到的就不是原版
BSTATE="$(bundle_state)"
case "$BSTATE" in
    broken)
        warn "Docker.app 的签名封印已被破坏，下面这些文件是多出来/缺失的:"
        seal_extras | sed 's/^/    /'
        die "请先删除多余文件，或重新安装 Docker Desktop 后再汉化 (见 docs/troubleshooting.md)" ;;
    plist)
        if [[ -z "$(state_get pristine_dir)" ]]; then
            warn "Docker.app 的 Info.plist 已被改动过 (可能用过其他汉化工具)，现在备份到的将不是纯原版。"
            [[ $AUTO -eq 1 ]] && { notify "检测到被其他工具改过，已跳过自动汉化"; exit 0; }
            ask "建议先重装原版 Docker。仍要继续吗？" || { echo "已取消"; exit 1; }
        fi ;;
esac

# ---------------------------------------------------------------- 获取汉化包
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ddcn.XXXXXX")"
trap 'rm -rf "$WORK"; rmdir "${LOCK:-/nonexistent}" 2>/dev/null || true' EXIT

jxa() { osascript -l JavaScript -e "$1" "${@:2}"; }
ASSET_URL=""; ASSET_SHA=""
if [[ -n "$LOCAL_ZIP" ]]; then
    [[ -f "$LOCAL_ZIP" ]] || die "找不到文件: $LOCAL_ZIP"
    cp "$LOCAL_ZIP" "$WORK/pkg.zip"
    warn "使用本地汉化包，无法校验来源"
else
    say "查找汉化包: $REPO @ $VERSION ($ASSET)"
    JSON=""
    for tag in "$VERSION" "v$VERSION"; do
        if JSON="$(curl -fsS --connect-timeout 10 --max-time 30 -H 'Accept: application/vnd.github+json' \
            "https://api.github.com/repos/$REPO/releases/tags/$tag" 2>/dev/null)"; then break; fi
        JSON=""
    done
    if [[ -n "$JSON" ]]; then
        LINE="$(printf '%s' "$JSON" | jxa '
            ObjC.import("Foundation");
            function run(argv) {
                var d = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
                var j = JSON.parse(ObjC.unwrap($.NSString.alloc.initWithDataEncoding(d, $.NSUTF8StringEncoding)));
                var a = (j.assets || []).filter(function (x) { return x.name === argv[0]; })[0];
                return a ? a.browser_download_url + "\t" + (a.digest || "") : "";
            }' "$ASSET" 2>/dev/null || true)"
        ASSET_URL="${LINE%%$'\t'*}"
        [[ "$LINE" == *$'\t'* ]] && ASSET_SHA="${LINE#*$'\t'}"
        ASSET_SHA="${ASSET_SHA#sha256:}"
    else
        # API 不可用 (限流/网络) 时退回到固定格式的下载地址
        if curl -fsSIL --connect-timeout 10 --max-time 20 -o /dev/null \
            "https://github.com/$REPO/releases/download/$VERSION/$ASSET" 2>/dev/null; then
            ASSET_URL="https://github.com/$REPO/releases/download/$VERSION/$ASSET"
            warn "GitHub API 不可用，无法获取校验值，将不做 SHA256 校验"
        fi
    fi

    if [[ -z "$ASSET_URL" ]]; then
        warn "汉化仓库 $REPO 还没有发布 Docker Desktop $VERSION 对应的汉化包 ($ASSET)。"
        AVAIL="$(curl -fsS --connect-timeout 10 --max-time 30 "https://api.github.com/repos/$REPO/releases?per_page=8" 2>/dev/null \
            | jxa 'ObjC.import("Foundation"); function run(a){var d=$.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
                   var j=JSON.parse(ObjC.unwrap($.NSString.alloc.initWithDataEncoding(d,$.NSUTF8StringEncoding)));
                   return j.map(function(r){return r.tag_name}).join(" ");}' 2>/dev/null || true)"
        [[ -n "$AVAIL" ]] && info "仓库最近发布的版本: $AVAIL"
        info "汉化包通常在 Docker 新版本发布后一两天内出现。不要用其他版本的汉化包 (会导致 Docker 无法启动)。"
        notify "Docker $VERSION 的汉化包还没发布，稍后会自动重试"
        [[ $AUTO -eq 1 ]] && exit 0
        exit 3
    fi

    say "下载 $ASSET"
    DL="$ASSET_URL"; [[ -n "${DDCN_PROXY_PREFIX:-}" ]] && DL="${DDCN_PROXY_PREFIX}${ASSET_URL}"
    curl -fL --retry 3 --connect-timeout 15 --max-time 900 -# -o "$WORK/pkg.zip" "$DL" || die "下载失败: $DL"
    if [[ -n "$ASSET_SHA" ]]; then
        [[ "$(sha256_of "$WORK/pkg.zip")" == "$ASSET_SHA" ]] || die "SHA256 校验失败，下载的文件已损坏或被篡改，已中止"
        info "SHA256 校验通过"
    fi
fi

mkdir "$WORK/pkg"; unzip -q "$WORK/pkg.zip" -d "$WORK/pkg" || die "汉化包解压失败"
PKG="$WORK/pkg"; [[ -f "$PKG/app.asar" ]] || PKG="$(dirname "$(find "$WORK/pkg" -name app.asar -print -quit)")"
[[ -f "$PKG/app.asar" ]] || die "汉化包里没有 app.asar"

# ---------------------------------------------------------------- 校验汉化包与本机版本一致
PKG_VERSION="$(tr -d '[:space:]' < "$PKG/version.txt" 2>/dev/null || true)"
if [[ -n "$PKG_VERSION" && "$PKG_VERSION" != "$INSTALLED_VERSION" && $FORCE -eq 0 ]]; then
    die "汉化包版本 ($PKG_VERSION) 与本机 Docker Desktop ($INSTALLED_VERSION) 不一致，已中止"
fi
if [[ -f "$PKG/Info.plist" ]]; then
    PKG_BUILD="$(plist_get "$PKG/Info.plist" CFBundleVersion)"
    if [[ -n "$PKG_BUILD" && -n "$INSTALLED_BUILD" && "$PKG_BUILD" != "$INSTALLED_BUILD" && $FORCE -eq 0 ]]; then
        die "汉化包构建号 ($PKG_BUILD) 与本机 ($INSTALLED_BUILD) 不一致，版本号相同但不是同一个构建，已中止 (确认无误可加 --force)"
    fi
fi
NEW_HASH="$(asar_header_hash "$PKG/app.asar")"
PKG_PLIST_HASH="$(plist_get "$PKG/Info.plist" ElectronAsarIntegrity:Resources/app.asar:hash)"
if [[ -n "$PKG_PLIST_HASH" && "$PKG_PLIST_HASH" != "$NEW_HASH" ]]; then
    die "汉化包内部不一致 (app.asar 校验值与包内 Info.plist 不符)，已中止"
fi

# ---------------------------------------------------------------- 备份原版并安装
cur_sha="$(sha256_of "$RES/app.asar")"
PRISTINE="$(state_get pristine_dir)"
if [[ -n "$PRISTINE" && -f "$PRISTINE/app.asar" && \
      ( "$cur_sha" == "$(state_get patched_sha256)" || "$cur_sha" == "$(sha256_of "$PRISTINE/app.asar")" ) ]]; then
    info "复用已有的原版备份: $PRISTINE"
else
    PRISTINE="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)-orig-$INSTALLED_VERSION"
    mkdir -p "$PRISTINE"
    cp -f "$RES/app.asar" "$PRISTINE/app.asar"
    [[ -d "$RES/app.asar.unpacked" ]] && cp -R "$RES/app.asar.unpacked" "$PRISTINE/app.asar.unpacked"
    cp -f "$INFO" "$PRISTINE/Info.plist"
    printf '%s\n' "$RES" > "$PRISTINE/install-path.txt"
    printf '%s\n' "$INSTALLED_VERSION" > "$PRISTINE/version.txt"
    info "已备份原版到: $PRISTINE"
    state_write "$PRISTINE" "" "$INSTALLED_VERSION" ""
fi

WAS_RUNNING=0
if docker_running; then
    WAS_RUNNING=1
    say "正在退出 Docker Desktop"
    osascript -e 'tell application "Docker" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do docker_running || break; sleep 1; done
    pkill -f "$INNER/MacOS/Docker Desktop" >/dev/null 2>&1 || true
fi

say "安装汉化"
IN_WRITE=1
if ! cp -f "$PKG/app.asar" "$RES/app.asar" 2>"$WORK/err"; then
    if grep -q "not permitted" "$WORK/err"; then
        die "macOS 拒绝修改 Docker.app (App 管理保护)。请到 系统设置 > 隐私与安全性 > App 管理 中允许当前使用的终端，然后重试"
    fi
    cat "$WORK/err" >&2; false
fi
if [[ -d "$PKG/app.asar.unpacked" ]]; then
    rm -rf "$RES/app.asar.unpacked"
    cp -R "$PKG/app.asar.unpacked" "$RES/app.asar.unpacked"
fi
# 只更新完整性哈希，不整体替换 Info.plist；绝不往 .app 包里放备份等额外文件，否则会破坏签名封印
/usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $NEW_HASH" "$INFO" 2>/dev/null \
    || { /usr/libexec/PlistBuddy -c "Add :ElectronAsarIntegrity:Resources/app.asar dict" \
            -c "Add :ElectronAsarIntegrity:Resources/app.asar:algorithm string SHA256" \
            -c "Add :ElectronAsarIntegrity:Resources/app.asar:hash string $NEW_HASH" "$INFO"; }
rm -f "$INFO.bak"
chmod -R a+rX "$RES/app.asar" "$RES/app.asar.unpacked" 2>/dev/null || true
IN_WRITE=0

# 校验写入结果
[[ "$(asar_header_hash "$RES/app.asar")" == "$(plist_get "$INFO" ElectronAsarIntegrity:Resources/app.asar:hash)" ]] \
    || { IN_WRITE=1; die "写入后完整性校验值不一致"; }
state_write "$PRISTINE" "$(sha256_of "$RES/app.asar")" "$INSTALLED_VERSION" "$REPO@$VERSION ${ASSET_SHA:-local}"
EXTRAS="$(seal_extras)"
if [[ -n "$EXTRAS" ]]; then
    warn "检测到 .app 包内有多余/缺失的文件，启动时可能提示“已损坏”:"; printf '%s\n' "$EXTRAS" | sed 's/^/    /'
fi

say "汉化完成 (Docker Desktop $INSTALLED_VERSION)"
info "还原原版: ./localize.command --restore"
notify "Docker Desktop 已汉化 ($INSTALLED_VERSION)"

if [[ $AUTO -eq 1 ]]; then
    [[ $WAS_RUNNING -eq 1 ]] && open "$APP" || true
elif [[ -z "${NO_LAUNCH:-}" ]]; then
    ask "现在启动 Docker Desktop 吗？" && open "$APP" || true
fi
