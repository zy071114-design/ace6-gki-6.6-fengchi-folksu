#!/usr/bin/env bash
# 用 AnyKernel3 把编译好的 Image 打成可直接在 TWRP / 橙狐 / KernelSU 管理器里刷入的 zip
# 用法: bash scripts/make_ak3.sh <Image路径> <输出目录> [zip名称]
set -euo pipefail

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${1:?需要 Image 路径}"
OUTDIR="${2:?需要输出目录}"
ZIPNAME="${3:-Ace6-GKI-6.6-fengchi-FolkSU.zip}"
# 第 4 个参数: 用哪个 anykernel.sh (默认 ak3/anykernel.sh;
# 给社区参考内核打包时用 ak3/anykernel-ref.sh, 它会如实写明 root 是内置 SukiSU)
AK3_SCRIPT="${4:-anykernel.sh}"

[ -f "$IMAGE" ] || die "找不到 Image: $IMAGE"

# 关键 (这就是 run #7 打包步骤 exit 15 的真正原因):
# 本脚本后面会 `cd "$WORK"`, 所以 $IMAGE / $OUTDIR 只要还是相对路径, 就会在 cd 之后
# 被解析到 $WORK 下面。OUTDIR=dist -> $WORK/dist 不存在 -> zip 无法创建输出文件,
# 直接退 15 (且不打印任何错误); 换成 Node 写同样会 ENOENT 退 1。
# 所以这里先把两者都固化成绝对路径。
IMAGE="$(cd "$(dirname "$IMAGE")" && pwd)/$(basename "$IMAGE")"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"
[ -f "$IMAGE" ] || die "找不到 Image: $IMAGE"

WORK="$REPO_ROOT/work/ak3"
rm -rf "$WORK"

# AnyKernel3 骨架: osm0sis 原版优先, 失败回退 cctv18 的 fork (两者 globals 均兼容)
log "拉取 AnyKernel3 骨架"
AK3_OK=0
for R in https://github.com/osm0sis/AnyKernel3.git \
         https://github.com/cctv18/AnyKernel3.git; do
  echo "    尝试 $R"
  if git clone --depth=1 "$R" "$WORK" 2>/dev/null; then
    # 骨架必须自带这些核心文件, 否则脚本里的 globals 不会生效
    if [ -f "$WORK/tools/ak3-core.sh" ] && [ -f "$WORK/tools/magiskboot" ]; then
      AK3_OK=1; echo "    使用 $R"; break
    fi
    warn "骨架缺少 tools/(ak3-core.sh|magiskboot), 换下一个源"
    rm -rf "$WORK"
  fi
done
[ "$AK3_OK" = "1" ] || die "无法获取可用的 AnyKernel3 骨架"

log "写入机型专用 anykernel.sh"
cp "$REPO_ROOT/ak3/anykernel.sh" "$WORK/anykernel.sh"
# 按机型替换占位符 (sed 用 | 作分隔符 —— DEV_IDS 里含 '/' 不会破坏替换)
sed -i "s|@DEV_NAME@|${DEV_NAME:-一加 Ace 6}|g; s|@DEV_IDS@|${DEV_IDS:-PLQ110/ossi/SM8750}|g" "$WORK/anykernel.sh"
# 标题行也按机型来, 否则会印着别的机型的内核名
sed -i "s|^kernel.string=.*|kernel.string=${DEV_NAME:-Ace6 GKI 6.6}|" "$WORK/anykernel.sh"
chmod 755 "$WORK/anykernel.sh"

log "放入内核镜像"
cp "$IMAGE" "$WORK/Image"

# 功能清单按构建实际内容生成 (别再写死: 之前把没编进去的 BBG/BTF 也写上了)
_BI="$REPO_ROOT/work/out/build-info.txt"
_bi_get() { [ -f "$_BI" ] && sed -n "s/^$1=//p" "$_BI" | head -1; }
_KVER="$(_bi_get KSU_VERSION)"
_FEAT=""
[ "$(_bi_get FENGCHI)" = "1" ] && _FEAT="风驰(HMBIRD)调度"
[ "$(_bi_get SUSFS)" = "1" ] && _FEAT="${_FEAT:-}${_FEAT:+ / }SUSFS 隐藏"
[ -n "${_KVER:-}" ] && _FEAT="${_FEAT:-}${_FEAT:+ / }内置 FinaSU root (${_KVER}, UAPI $(_bi_get KSU_UAPI))"
[ -z "${_FEAT:-}" ] && _FEAT="GKI 6.6 官方源码"

log "写入适用机型说明 (防止刷错机)"
cat > "$WORK/README-刷机须知.txt" <<EOF
【${DEV_NAME:-一加 Ace 6} 专用内核 (${DEV_IDS:-PLQ110/ossi/SM8750})】
* 本包仅适用于 ${DEV_NAME:-一加 Ace 6} (${DEV_IDS:-PLQ110/ossi/SM8750})。
* 其他 6.6 设备/机型严禁刷入: 电源/充电/温控/显示驱动不匹配, 刷入后必现随机重启。
* 本包实际内容: ${_FEAT}。
* 内核版本: $(_bi_get UTS_RELEASE)  源码分支: $(_bi_get KERNEL_BRANCH)
* 刷入前务必备份当前 boot_a 分区, 以便随时回滚。
EOF

# 构建信息只作为独立文件放进 zip (绝不能 append 到 anykernel.sh:
# 里面的 "BUILT_AT=2026-10-10 15:21:39 UTC" 不是合法 shell 赋值, 会让安装器报错)
if [ -f "$REPO_ROOT/work/out/build-info.txt" ]; then
  cp "$REPO_ROOT/work/out/build-info.txt" "$WORK/build-info.txt"
fi

cd "$WORK"
rm -rf .git
# 加固: 统一工具权限, 规避 I/O 延迟导致的二进制执行异常
chmod -R 755 tools 2>/dev/null || true

rm -f "$OUTDIR/$ZIPNAME"
# 原生 zip 优先 (已验证在 ubuntu-22.04 runner 上工作正常);
# 只有在没有 zip 命令时才回退到 Node 实现, 避免依赖缺失导致打包失败。
if command -v zip >/dev/null 2>&1; then
  zip -r9 "$OUTDIR/$ZIPNAME" . -x '.git/*' >/dev/null
else
  warn "系统里没有 zip 命令, 回退用 scripts/mkzip.js (Node) 打包"
  node "$REPO_ROOT/scripts/mkzip.js" "$WORK" "$OUTDIR/$ZIPNAME"
fi
[ -f "$OUTDIR/$ZIPNAME" ] || die "打包失败: 没有生成 $OUTDIR/$ZIPNAME"
log "已生成: $OUTDIR/$ZIPNAME ($(du -h "$OUTDIR/$ZIPNAME" | cut -f1))"
echo "    zip 内容:"
if command -v unzip >/dev/null 2>&1; then
  unzip -l "$OUTDIR/$ZIPNAME" | sed 's/^/      /' | head -25
  unzip -t "$OUTDIR/$ZIPNAME" | tail -2 | sed 's/^/      /'
else
  node "$REPO_ROOT/scripts/mkzip.js" --list "$OUTDIR/$ZIPNAME" 2>/dev/null || ls -l "$OUTDIR/$ZIPNAME"
fi
