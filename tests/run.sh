#!/bin/bash
# 端到端测试: 全部在“假 Docker.app + 临时家目录”里进行，不会碰真实的 Docker Desktop。
#
# 用法: bash tests/run.sh
# 前置: 需要一份**未汉化的原版**文件 (app.asar / app.asar.unpacked / Info.plist)，通过环境变量指定:
#         DDCN_TEST_ORIG=/path/to/pristine bash tests/run.sh
#       默认取 ~/Library/Application Support/DockerDesktop-CN/backup 里最新的 *-orig-* 备份。
#       下载类用例会真实访问 GitHub，并要求汉化仓库已发布该版本的汉化包。
set -u
INST="$(cd "$(dirname "$0")/.." && pwd)/localize.command"
ORIG="${DDCN_TEST_ORIG:-$(ls -1dr "$HOME/Library/Application Support/DockerDesktop-CN/backup/"*-orig-* 2>/dev/null | head -1)}"
[[ -n "$ORIG" && -f "$ORIG/app.asar" && -f "$ORIG/Info.plist" ]] || { echo "找不到原版文件，请设置 DDCN_TEST_ORIG"; exit 2; }
T="$(mktemp -d "${TMPDIR:-/tmp}/ddcn-test.XXXXXX")"
trap 'chflags -R nouchg "$T" 2>/dev/null; /bin/rm -rf "$T"' EXIT
VER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ORIG/Info.plist")"
echo "原版: $ORIG (Docker Desktop $VER)"
APP="$T/Docker.app"; INNERAPP="$APP/Contents/MacOS/Docker Desktop.app"; F="$INNERAPP/Contents"
PASS=0; FAILN=0
ok()   { echo "  ✔ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ✘ $*"; FAILN=$((FAILN+1)); }
chk()  { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
c()    { sed 's/\x1b\[[0-9;]*m//g' | tr '\r' '\n' | grep -v -E '^ *#|^ *[0-9.]+%'; }

reset_fake() {  # 把假 app 复位成原版
    /bin/rm -rf "$APP"; mkdir -p "$F/Resources" "$F/MacOS"
    cp "$ORIG/Info.plist" "$F/Info.plist"; cp "$ORIG/app.asar" "$F/Resources/"; cp -R "$ORIG/app.asar.unpacked" "$F/Resources/"
    cp /usr/bin/true "$F/MacOS/Docker Desktop"   # 可签名的占位主程序 (CFBundleExecutable)
}
sig_valid() { codesign --verify --deep --strict "$INNERAPP" >/dev/null 2>&1 && codesign -dv "$INNERAPP" 2>&1 | grep -q "^Signature=adhoc"; }
run() {  # run <home> args...  (在指定的“家目录/状态目录”下运行)
    local h=$1; shift
    DDCN_DOCKER_APP="$APP" DDCN_HOME="$h" DDCN_ARCH=apple DDCN_ASSUME_LAUNCHED=1 DDCN_AUTO_DELAY=1 NO_LAUNCH=1 bash "$INST" "$@" 2>&1 | c
}
rc() { DDCN_DOCKER_APP="$APP" DDCN_HOME="$1" DDCN_ARCH=apple DDCN_ASSUME_LAUNCHED=1 DDCN_AUTO_DELAY=1 NO_LAUNCH=1 bash "$INST" "${@:2}" >/dev/null 2>&1; echo $?; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

echo "== 基线: 干净安装"
reset_fake; H1=$T/home1
run $H1 --yes | tail -2
chk "安装后为已汉化" '[[ $(rc $H1 --check) -eq 0 ]]'
chk "安装后已重新签名且签名与内容一致 (重启后系统才不会杀进程)" 'sig_valid'

echo "== H1 路径变了: 状态里的绝对备份路径失效 (换用户名/迁移/恢复备份)"
H1b=$T/home1_moved; cp -R $H1 $H1b            # 模拟迁到新位置
/bin/rm -rf $H1                                # 旧路径不复存在，state.json 里仍是旧的绝对路径
grep -q "home1/backup" $H1b/state.json && ok "state.json 里确实还是旧路径" || bad "前提不成立"
run $H1b --restore | tail -1
chk "仍能定位到备份并还原为原版" 'cmp -s "$F/Resources/app.asar" "$ORIG/app.asar"'
chk "还原后签名与(原版)内容仍一致" 'sig_valid'

echo "== H2 状态文件丢了，但 app 已是汉化版 (认领，不重复安装)"
run $H1b --yes >/dev/null                      # 再汉化一次
/bin/rm -f $H1b/state.json
OUT=$(run $H1b --yes); echo "$OUT" | grep -E "已经是该汉化包|重建" | head -1
chk "识别为已汉化并重建记录" 'echo "$OUT" | grep -q "重建状态记录"'
chk "重建后 --check 为已汉化" '[[ $(rc $H1b --check) -eq 0 ]]'
chk "重建时找回了原版备份" 'grep -q "orig-$VER" $H1b/state.json'
run $H1b --restore | tail -1
chk "认领后仍可还原为原版" 'cmp -s "$F/Resources/app.asar" "$ORIG/app.asar"'

echo "== H3 状态丢了、app 是原版、备份还在 (复用备份，不产生重复备份)"
/bin/rm -f $H1b/state.json
N1=$(ls $H1b/backup | wc -l | tr -d ' ')
OUT=$(run $H1b --yes); echo "$OUT" | grep -E "复用" | head -1
N2=$(ls $H1b/backup | wc -l | tr -d ' ')
chk "按哈希找回并复用已有备份" 'echo "$OUT" | grep -q "复用已有的原版备份"'
chk "没有产生重复备份 ($N1 -> $N2)" '[[ $N1 -eq $N2 ]]'

echo "== H4 全新系统: 没有任何状态/备份，但 app 已是汉化版 (如迁移助手只拷了 app)"
H4=$T/home4
OUT=$(run $H4 --yes)
chk "认领成功且不重装" 'echo "$OUT" | grep -q "重建状态记录"'
chk "提示未找到原版备份" 'echo "$OUT" | grep -q "未找到原版备份"'
chk "之后 --check 为已汉化" '[[ $(rc $H4 --check) -eq 0 ]]'

echo "== H9 写权限预检 (Docker.app 属于其他用户时)"
reset_fake; H9=$T/home9
chmod a-w "$F/Resources/app.asar"
OUT=$(run $H9 --yes); echo "$OUT" | tail -2
chk "安装前就给出 sudo 提示" 'echo "$OUT" | grep -q "sudo bash"'
chk "没有改动任何文件" 'cmp -s "$F/Resources/app.asar" "$ORIG/app.asar"'
chmod u+w "$F/Resources/app.asar"

echo "== H10 写入中途失败自动回滚 (asar 已写入后，替换 unpacked 时失败: 给其中一个文件加不可变标志)"
reset_fake; H10=$T/home10
chflags uchg "$F/Resources/app.asar.unpacked/package.json"
OUT=$(run $H10 --yes); echo "$OUT" | tail -4
chflags nouchg "$F/Resources/app.asar.unpacked/package.json"
chk "确实走到了写入阶段后才失败" 'echo "$OUT" | grep -q "安装汉化"'
chk "报错并触发回滚" 'echo "$OUT" | grep -qE "自动还原"'
chk "asar 已回滚为原版 (之前被替换过)" 'cmp -s "$F/Resources/app.asar" "$ORIG/app.asar"'
chk "unpacked 与原版逐字节一致且没有嵌套目录" 'diff -r "$F/Resources/app.asar.unpacked" "$ORIG/app.asar.unpacked" >/dev/null && [[ ! -d "$F/Resources/app.asar.unpacked/app.asar.unpacked" ]]'
chk "Info.plist 保持原版" 'cmp -s "$F/Info.plist" "$ORIG/Info.plist"'
chk "回滚后状态仍为未汉化" '[[ $(rc $H10 --check) -eq 10 ]]'
chflags -R nouchg "$F" 2>/dev/null

echo "== S1 旧版脚本装的汉化: 内容已写入但没有重新签名 -> --check 报需修复，运行脚本只补签名、不重新下载"
reset_fake; H12=$T/home12
run $H12 --yes >/dev/null
codesign --remove-signature "$INNERAPP/Contents/MacOS/Docker Desktop" 2>/dev/null; codesign --remove-signature "$INNERAPP" 2>/dev/null
chk "签名被移除后，--check 判为需要修复 (退出码 10)" '[[ $(rc $H12 --check) -eq 10 ]]'
SHA_BEFORE=$(sha "$F/Resources/app.asar")
OUT=$(run $H12 --yes); echo "$OUT" | grep -E "修复|下载" | head -2
chk "只修复签名，没有重新下载" 'echo "$OUT" | grep -q "修复签名" && ! echo "$OUT" | grep -q "下载 app-Mac"'
chk "汉化内容未改动" '[[ "$(sha "$F/Resources/app.asar")" == "$SHA_BEFORE" ]]'
chk "修复后签名一致且 --check 为已汉化" 'sig_valid && [[ $(rc $H12 --check) -eq 0 ]]'
chk "修复过的状态再次运行为“无需处理”" 'run $H12 --yes | grep -q "无需处理"'

echo "== S2 重新签名失败 -> 自动回滚到原版 (用桩 codesign 模拟被 App 管理拦截)"
reset_fake; H13=$T/home13; mkdir -p $T/stubs
printf '#!/bin/bash\nfor a in "$@"; do [[ "$a" == "--force" ]] && { echo "stub: Operation not permitted" >&2; exit 1; }; done\nexec /usr/bin/codesign "$@"\n' > $T/stubs/codesign; chmod +x $T/stubs/codesign
OUT=$(PATH="$T/stubs:$PATH"; run $H13 --yes); echo "$OUT" | tail -3
chk "确实走到了重新签名这一步" 'echo "$OUT" | grep -q "重新签名"'
chk "报错并触发回滚" 'echo "$OUT" | grep -qE "自动还原"'
chk "asar / Info.plist / unpacked 全部回到原版" 'cmp -s "$F/Resources/app.asar" "$ORIG/app.asar" && cmp -s "$F/Info.plist" "$ORIG/Info.plist" && diff -r "$F/Resources/app.asar.unpacked" "$ORIG/app.asar.unpacked" >/dev/null'
chk "回滚后状态为未汉化" '[[ $(rc $H13 --check) -eq 10 ]]'

echo "== H11 配置文件: 持久指定汉化仓库 (后台任务拿不到环境变量)"
reset_fake; H11=$T/home11; mkdir -p $H11; echo "DDCN_REPO=nobody/nonexistent-repo-xyz" > $H11/config
OUT=$(run $H11 --yes); echo "$OUT" | grep -E "查找汉化包" | head -1
chk "配置文件里的仓库生效" 'echo "$OUT" | grep -q "nobody/nonexistent-repo-xyz"'
chk "环境变量优先于配置文件" 'DDCN_REPO=asxez/DockerDesktop-CN DDCN_DOCKER_APP="$APP" DDCN_HOME=$H11 DDCN_ARCH=apple DDCN_ASSUME_LAUNCHED=1 NO_LAUNCH=1 bash "$INST" --yes 2>&1 | grep -q "asxez/DockerDesktop-CN @"'
reset_fake

echo "== H6 架构判断"
eval "$(sed -n '/^pick_arch()/,/^}/p' "$INST")"
MACH=$([[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" == "1" ]] && echo apple || echo intel)
chk "arm64 -> apple"  '[[ "$(pick_arch arm64)" == apple ]]'
chk "x86_64 -> intel" '[[ "$(pick_arch x86_64)" == intel ]]'
chk "通用二进制按本机芯片 ($MACH)" '[[ "$(pick_arch "arm64 x86_64")" == "$MACH" ]]'

echo "== H5 Spotlight 兜底定位 Docker"
MD=$(mdfind "kMDItemCFBundleIdentifier == 'com.docker.docker'" 2>/dev/null | head -1)
echo "  mdfind -> ${MD:-<空>}"
chk "mdfind 能按 bundle id 找到真实 Docker.app 且布局合法" '[[ -n "$MD" && -f "$MD/Contents/MacOS/Docker Desktop.app/Contents/Resources/app.asar" ]]'

echo "== H7 sudo 场景的家目录解析"
RH=$(dscl . -read "/Users/$USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
chk "dscl 能解析出真实用户家目录 ($RH)" '[[ "$RH" == "$HOME" ]]'

echo; echo "通过 $PASS  失败 $FAILN"
[[ $FAILN -eq 0 ]]
