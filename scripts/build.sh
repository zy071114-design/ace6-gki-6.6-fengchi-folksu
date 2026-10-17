#!/usr/bin/env bash
# =============================================================================
# 一加 Ace 6 (PLQ110 / ossi / SM8750 "sun") GKI 6.6 内核编译脚本
#
#   * 源码基线 : OnePlus 官方开源 android_kernel_common_oneplus_sm8750
#                分支 oneplus/sm8750_b_16.0.0_ace_6  (6.6.118)
#                该分支 gki_defconfig 自带 CONFIG_SLIM_SCHED=y +
#                CONFIG_SCHED_CLASS_EXT=y, 与风驰补丁的基线逐字吻合
#   * 风驰内核 : patches/fengchi.patch
#                (OPlus HMBIRD 调度类: 以 hmbird 取代 AOSP sched_ext,
#                 SCHED_EXT -> SCHED_HMBIRD, CONFIG_SCHED_CLASS_EXT ->
#                 CONFIG_HMBIRD_SCHED, 新增 kernel/sched/hmbird/)
#   * Root     : FinaSU (KernelSU fork, KERNEL_SU_UAPI_VERSION = 6)
#                FinaSU = FolkSU 原仓库 (LyraVoid/FinaSU) 改名后的新版本;
#                并把指定 APK 的签名设为内核侧受信任管理器
#
# 用法:  bash scripts/build.sh        (仓库根目录执行)
# 所有参数都可用环境变量覆盖, 见下面 CONFIG 段
# =============================================================================
set -euo pipefail

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${WORKDIR:-$REPO_ROOT/work}"
mkdir -p "$WORKDIR"

# ------------------------------ CONFIG --------------------------------------
KERNEL_REPO="${KERNEL_REPO:-https://github.com/OnePlusOSS/android_kernel_common_oneplus_sm8750.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-oneplus/sm8750_b_16.0.0_ace_6}"
KERNEL_DIR="${KERNEL_DIR:-common}"

# FinaSU/FolkSU 是同一仓库 (github.com/LyraVoid/FinaSU): FolkSU v0.1.0-beta3 之后
# 项目改名 FinaSU, 并在 v1.0.4 把 KERNEL_SU_UAPI_VERSION 由 5 提到 6。
# 管理器 (FinaSU_v1.0.4_32960) 会拒绝对接 UAPI=5 的内核 (ksud 报 "UAPI version mismatch"),
# 所以必须改用 v1.0.4 的内核侧代码重编, 不能沿用 FolkSU 的驱动。
KSU_REPO="${KSU_REPO:-https://github.com/LyraVoid/FinaSU.git}"
# v1.0.4: 提交数 2960 -> KSU_VERSION = 30000+2960 = 32960 (与 APK versionCode 32960 一致)
KSU_TAG="${KSU_TAG:-v1.0.4}"
KSU_EXPECTED_VERSION="${KSU_EXPECTED_VERSION:-32960}"

APPLY_FENGCHI="${APPLY_FENGCHI:-1}"
APPLY_SUSFS="${APPLY_SUSFS:-0}"
SUSFS_APPLIED="${SUSFS_APPLIED:-0}"   # 由第 5 节置 1, 供后续校验/build-info 使用
# APPLY_KSU=0: 内核里【不】集成 KernelSU。
# 一加 Ace 6 这台机器的 root 是 init_boot ramdisk 里的 kernelsu.ko (LKM 模式,
# ksu_config 里 bundled=1, 由 wrapper init / ksuinit 在开机时 insmod)。
# 内核自带 KSU 时, ksuinit 会走到 "Cannot load kernelsu.ko" 分支 -> init 卡住 -> 卡第一屏。
APPLY_KSU="${APPLY_KSU:-1}"
# ENABLE_BTF=1: 生成 BTF (/sys/kernel/btf/vmlinux)。
# 第三方 sched_ext (scx_rusty / scx_lavd 等 BPF 调度器) 走 CO-RE, 必须要有 BTF;
# 设备出厂内核就是 DEBUG_INFO_BTF=y + DEBUG_INFO_BTF_MODULES=y + MODULE_ALLOW_BTF_MISMATCH=y。
# 需要 CI 里装 pahole (apt 包 dwarves)。
ENABLE_BTF="${ENABLE_BTF:-0}"

# ---- 可选增强 (默认全关, 先确保内核能启动再逐项开) ----
# APPLY_ZRAM=1   : zram 全压缩后端 + writeback + multi-comp (原生符号, 无源码补丁)
# APPLY_NET=1    : BBR 等拥塞控制 + fq/fq_codel 队列调度 + netfilter/ipset 扩展 (原生符号)
#                 不含 BRUTAL / BPF_STREAM_PARSER / LZ4KD —— 那三个必须打源码补丁,
#                 见 repo/patches/ 与 scripts 里的独立开关, 不在这里混进来。
APPLY_ZRAM="${APPLY_ZRAM:-0}"
APPLY_NET="${APPLY_NET:-0}"
# APPLY_BBG=1   : BBG (Baseband-guard) 防格机 LSM, 会往 CONFIG_LSM 追加 baseband_guard
APPLY_BBG="${APPLY_BBG:-0}"
# RELAX_VERMAGIC=1 : 通用 GKI —— 放宽 vendor 模块 vermagic 校验 (只比对主版本号前缀
#                    如 "6.6.118"), 让同一 sun 平台不同机型/固件的模块都能加载。
#                    符号版本索引与 CONFIG_MODVERSIONS 的 CRC 校验保持不变。
RELAX_VERMAGIC="${RELAX_VERMAGIC:-0}"
# APPLY_NET=1 时是否把 BBR 设为默认拥塞控制 (bbr | cubic)
TCP_DEFAULT_CONG="${TCP_DEFAULT_CONG:-cubic}"

# USE_REF_CONFIG=1 : 不再用树的 gki_defconfig, 直接喂一份【已实测能启动】的完整 .config
# (configs/ref-6.6.150.config, 来自参考内核运行时 /proc/config.gz)。这样把"配置"这个
# 变量彻底从对照实验里拿掉: 剩下的差异只有 源码树 / 工具链 / LOCALVERSION 三项。
USE_REF_CONFIG="${USE_REF_CONFIG:-0}"
REF_CONFIG_FILE="${REF_CONFIG_FILE:-$REPO_ROOT/configs/ref-6.6.150.config}"

# 管理器证书的 (长度, SHA-256) —— 取自 v2 签名里第一张 certificate (DER) 的 sha256。
# 实测: FinaSU_v1.0.4_32960-release.apk 的证书 == 旧 FolkSU 管理器的证书 (同一把密钥),
# 所以沿用 0x2cc/2d89b50a… 即可; 只有换别的管理器时才需要重算。
KSU_EXPECTED_SIZE="${KSU_EXPECTED_SIZE:-0x2cc}"
KSU_EXPECTED_HASH="${KSU_EXPECTED_HASH:-2d89b50aaf1db013c2b6738f973f48b62ea21a3a8d7216bfec3521065d448458}"

# 出厂内核版本串 = 6.6.118-android15-8-g9bc34d5b0c79-abogki537459655-4k
#
# 这里逐字对齐 ROM 的内核版本串(含 -g<sha>-abogki<构建ID>-4k), 理由(硬证据):
#   1. system_dlkm 全部 96 个 GKI 模块的 vermagic 就是这串(不是 -o-4k)
#      例: vermagic=6.6.118-android15-8-g9bc34d5b0c79-abogki537459655-4k SMP preempt ...
#   2. 两个"能在这台机器上启动"的内核都带 abogki537459655:
#        出厂   : 6.6.118-android15-8-g9bc34d5b0c79-abogki537459655-4k
#        参考包 : 6.6.150-android15-8-g1826411674e2-abogki537459655-4k (SUBLEVEL/sha 不同也保留了该节)
#   3. cctv18 的配方也是把 ROM 的确切版本串硬编码进去(并 echo 掉 setlocalversion 的 scm 后缀)
# 注: vendor_dlkm 里还有 -o-4k / -o-g1524d9b076be-4k 两种旧串, 内核侧的 same_magic() 在
#     CONFIG_MODVERSIONS 下会忽略版本段, 所以这里取"出厂串"是为了满足 system_dlkm 那一侧。
LOCALVERSION_SUFFIX="${LOCALVERSION_SUFFIX:--android15-8-g9bc34d5b0c79-abogki537459655-4k}"

CLANG_VER="${CLANG_VER:-18}"
# 工具链选择:
#   android = 一加出厂内核/社区可用内核所用的 Android clang r510928 (LLVM=1, 提供 llvm-* 工具)
#   ubuntu  = 发行版 clang-18 (LLVM=-18, 需要 clang-18/llvm-ar-18 等符号链接)
# 依据: 出厂内核与"能在这台机器启动"的参考内核都是 Android clang r510928 编译;
#       cctv18(风驰移植配方)同样下载该预编译包; 两者 CFI/LTO/hardening 配置与本构建完全一致,
#       唯一差别就是编译器实现 => 先用 Android clang 对齐。
TOOLCHAIN="${TOOLCHAIN:-android}"
JOBS="${JOBS:-$(nproc --all)}"
BUILD_TARGET="${BUILD_TARGET:-Image}"
INSTALL_DEPS="${INSTALL_DEPS:-0}"

export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-ace6}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-gki-builder}"
export KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-$(date -u '+%Y-%m-%d %H:%M:%S UTC')}"

# --------------------------- 依赖安装 (可选) ---------------------------------
if [ "$INSTALL_DEPS" = "1" ]; then
  log "安装编译依赖"
  SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"
  $SUDO apt-get update -qq
  $SUDO apt-get install -y --no-install-recommends \
    bc bison flex libelf-dev libssl-dev cpio zip unzip rsync kmod ccache \
    gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu python3 git wget curl xz-utils
  if ! command -v "clang-$CLANG_VER" >/dev/null 2>&1; then
    wget -q https://apt.llvm.org/llvm.sh -O /tmp/llvm.sh
    chmod +x /tmp/llvm.sh
    $SUDO /tmp/llvm.sh "$CLANG_VER" all
  fi
fi

# 工具检查要跟随 TOOLCHAIN:
#   android = Android clang r510928 预编译包, 里面全是【非版本号】名字 (clang / ld.lld),
#             没有 ld.lld-18 -> 之前写死版本名会让 android 模式直接 die
#   ubuntu  = 发行版 clang-18 + 软链出来的 clang / ld.lld
if [ "$TOOLCHAIN" = "android" ]; then
  TOOL_LIST="clang ld.lld llvm-ar llvm-nm aarch64-linux-gnu-ld make bc bison flex git"
else
  TOOL_LIST="clang-$CLANG_VER ld.lld-$CLANG_VER clang ld.lld aarch64-linux-gnu-ld make bc bison flex git"
fi
for t in $TOOL_LIST; do
  command -v "$t" >/dev/null 2>&1 || die "缺少工具: $t  (设 INSTALL_DEPS=1 或手动安装)"
done
echo "    clang: $(command -v clang)"; clang --version | head -1 | sed 's/^/    /'

# --------------------------- 1. 官方 Ace 6 源码 ------------------------------
cd "$WORKDIR"
if [ ! -d "$KERNEL_DIR/.git" ]; then
  log "克隆 OnePlus 官方 Ace 6 内核源码"
  echo "    仓库: $KERNEL_REPO"
  echo "    分支: $KERNEL_BRANCH"
  git clone --depth=1 --branch "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR"
else
  log "复用已存在的 $KERNEL_DIR"
fi
cd "$KERNEL_DIR"

BASE_VERSION="$(make kernelversion 2>/dev/null || echo unknown)"
SRC_HEAD="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
log "基线: Linux $BASE_VERSION  提交 $SRC_HEAD"
git log -1 --pretty='    %s' 2>/dev/null || true

# --------------------------- 2. 风驰内核补丁 ---------------------------------
if [ "$APPLY_FENGCHI" = "1" ]; then
  log "移植风驰内核 (HMBIRD 调度类)"
  # fengchi-ace6.patch = 上游 fengchi.patch 在官方 ace_6 分支上重基后的版本,
  # 19 处基线漂移已逐条解决, 并验证 git apply 0 reject
  PATCH_FILE="$REPO_ROOT/patches/fengchi-ace6.patch"
  [ -f "$PATCH_FILE" ] || PATCH_FILE="$REPO_ROOT/patches/fengchi.patch"
  [ -f "$PATCH_FILE" ] || die "找不到风驰补丁"
  echo "    补丁: $(basename "$PATCH_FILE")"

  # 风驰以 hmbird 取代 AOSP sched_ext, 基线必须是带 SLIM_SCHED/SCHED_CLASS_EXT 的树
  grep -q '^CONFIG_SCHED_CLASS_EXT=y' arch/arm64/configs/gki_defconfig \
    || warn "基线 gki_defconfig 没有 CONFIG_SCHED_CLASS_EXT=y, 补丁可能不匹配"

  APPLIED=0
  if git apply -p1 --whitespace=nowarn "$PATCH_FILE" 2>/dev/null; then
    echo "    已用 git apply -p1 应用"; APPLIED=1
  elif git apply --3way --whitespace=nowarn "$PATCH_FILE" 2>/dev/null; then
    echo "    已用 git apply --3way 应用"; APPLIED=1
  else
    warn "git apply 失败, 回退 patch -p1 -F3"
    if patch -p1 -F3 --no-backup-if-mismatch < "$PATCH_FILE"; then APPLIED=1; fi
    # 统计残留 rej
    REJ="$(find . -name '*.rej' -not -path './.git/*' | wc -l)"
    if [ "$REJ" != "0" ]; then
      echo "    ---- 冲突文件 ----"
      find . -name '*.rej' -not -path './.git/*' | sed 's/^/    /'
      die "风驰补丁有 $REJ 个文件冲突 (.rej), 需要人工处理"
    fi
  fi
  [ "$APPLIED" = "1" ] || die "风驰补丁无法应用"

  # 结构校验: hmbird 实现必须在, AOSP sched_ext 必须已被移除
  [ -f kernel/sched/hmbird/hmbird.c ] || die "缺少 kernel/sched/hmbird/hmbird.c, 风驰补丁不完整"
  [ -f include/linux/sched/sched_ext.h ] || die "缺少 include/linux/sched/sched_ext.h"
  [ -f kernel/sched/ext.c ] && die "AOSP kernel/sched/ext.c 仍在"
  [ -f include/linux/sched/ext.h ] && die "AOSP include/linux/sched/ext.h 仍在"

  # 补丁应把 CONFIG_SCHED_CLASS_EXT 换成 CONFIG_HMBIRD_SCHED
  if grep -q '^CONFIG_HMBIRD_SCHED=y' arch/arm64/configs/gki_defconfig; then
    echo "    CONFIG_HMBIRD_SCHED=y 已就位"
  else
    warn "补丁未写入 CONFIG_HMBIRD_SCHED=y, 手工补上"
    echo 'CONFIG_HMBIRD_SCHED=y' >> arch/arm64/configs/gki_defconfig
  fi
  echo "    hmbird 源文件: $(ls kernel/sched/hmbird/ | wc -l) 个"
else
  warn "APPLY_FENGCHI=0 -> 不打风驰补丁 (将保留 AOSP sched_ext, 无 HMBIRD/风驰)"
fi

# --------------------------- 3. 集成 FinaSU ----------------------------------
if [ "$APPLY_KSU" = "1" ]; then
log "集成 FinaSU 内核侧代码 (tag $KSU_TAG)"
KSU_DIR="$PWD/KernelSU"
if [ ! -d "$KSU_DIR/.git" ]; then
  rm -rf "$KSU_DIR"
  # 需要完整历史: kernel/Kbuild 用 rev-list --count HEAD 计算 KSU_VERSION
  git clone --quiet "$KSU_REPO" "$KSU_DIR"
fi
git -C "$KSU_DIR" fetch --tags --quiet 2>/dev/null || true
git -C "$KSU_DIR" checkout --quiet "$KSU_TAG" 2>/dev/null \
  || warn "无法切到 $KSU_TAG, 使用默认分支"
KSU_COMMITS="$(git -C "$KSU_DIR" rev-list --count HEAD)"
KSU_VERSION="$((30000 + KSU_COMMITS))"

# 不要把嵌套仓库算进内核仓库的改动里
grep -qxF '/KernelSU/' .git/info/exclude 2>/dev/null || echo '/KernelSU/' >> .git/info/exclude
grep -qxF '/drivers/kernelsu' .git/info/exclude 2>/dev/null || echo '/drivers/kernelsu' >> .git/info/exclude

# kernel/include/uapi -> ../../uapi, 在该布局下解析到 KernelSU/uapi
[ -L KernelSU/kernel/include/uapi ] || ln -sfn ../../uapi KernelSU/kernel/include/uapi
[ -f KernelSU/kernel/include/uapi/supercall.h ] || die "FinaSU uapi 布局异常"

# 与 KernelSU 官方 setup.sh 完全相同的接入方式
ln -sfn ../KernelSU/kernel drivers/kernelsu
grep -q 'kernelsu' drivers/Makefile || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig \
  || sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig

KSU_UAPI="$(sed -n 's/.*KERNEL_SU_UAPI_VERSION *= *\([0-9]\+\).*/\1/p' KernelSU/uapi/supercall.h | head -1)"
[ "$KSU_UAPI" = "6" ] || die "FinaSU UAPI=$KSU_UAPI, 与管理器 (FinaSU 1.0.4, uapi: 6) 不匹配"
[ "$KSU_VERSION" = "$KSU_EXPECTED_VERSION" ] \
  || die "KSU_VERSION=$KSU_VERSION != 期望 $KSU_EXPECTED_VERSION (检查 KSU_TAG 是否与管理器 APK 版本对应)"
echo "    KERNEL_SU_UAPI_VERSION = $KSU_UAPI"
echo "    KSU_VERSION = $KSU_VERSION   (管理器 APK 为 $KSU_EXPECTED_VERSION)"
echo "    受信任管理器证书: size=$KSU_EXPECTED_SIZE sha256=${KSU_EXPECTED_HASH:0:16}..."
else
  warn "APPLY_KSU=0 -> 内核不带 KernelSU (配合 init_boot 里的 kernelsu.ko LKM root 使用)"
fi

# --------------------------- 3b. 可选: 套用参考内核配置 ----------------------
# 所有"往配置里写东西"的地方统一写 $CFGFILE, 它要么是树的 defconfig (默认),
# 要么是 out/.config (USE_REF_CONFIG=1)。注意顺序: 必须在第 4 节改 LOCALVERSION 之前
# 把参考配置放进 out/.config, 否则 LOCALVERSION 会被写到没用的地方。
CFGFILE="arch/arm64/configs/gki_defconfig"
if [ "$USE_REF_CONFIG" = "1" ]; then
  [ -f "$REF_CONFIG_FILE" ] || die "USE_REF_CONFIG=1 但找不到 $REF_CONFIG_FILE"
  log "套用参考内核配置(实测可启动): $REF_CONFIG_FILE"
  mkdir -p out
  cp "$REF_CONFIG_FILE" out/.config
  CFGFILE="out/.config"
  # abi_symbollist.raw 不在这棵树里的话, TRIM_UNUSED_KSYMS 会直接编译失败
  if ! find . -maxdepth 4 -name 'abi_symbollist.raw' 2>/dev/null | grep -q .; then
    log "  本树没有 abi_symbollist.raw -> 关掉 TRIM_UNUSED_KSYMS"
    sed -i -e 's/^CONFIG_TRIM_UNUSED_KSYMS=y/# CONFIG_TRIM_UNUSED_KSYMS is not set/' \
           -e '/^CONFIG_UNUSED_KSYMS_WHITELIST=/d' out/.config
  fi
  grep -E '^CONFIG_(OF_DTBO_PATCH_CORE|DEBUG_INFO_BTF=|HMBIRD_SCHED|KSU=|TRIM_UNUSED_KSYMS|PSTORE)' out/.config \
    | sed 's/^/    /' || true
fi

# --------------------------- 4. 锁定内核版本后缀 ------------------------------
log "锁定内核版本后缀: $LOCALVERSION_SUFFIX"
sed -i "s|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION=\"${LOCALVERSION_SUFFIX}\"|" "$CFGFILE"
if grep -q '^CONFIG_LOCALVERSION_AUTO=' "$CFGFILE"; then
  sed -i 's|^CONFIG_LOCALVERSION_AUTO=.*|CONFIG_LOCALVERSION_AUTO=n|' "$CFGFILE"
else
  echo 'CONFIG_LOCALVERSION_AUTO=n' >> "$CFGFILE"
fi
# 去掉 setlocalversion 末尾的 ${scm_version}, 避免 -dirty/+ 污染 vermagic
sed -i 's/\${scm_version}//' scripts/setlocalversion

# --------------------- 4b. 通用 GKI: 放宽 vermagic 校验 (可选) -----------------
# 一加 sun 平台各机型出厂版本串尾部不同 (例如 Ace6/13 = ...-abogki537459655-4k,
# Pad3 = ...-ab15114928-4k), 严格全等比对会让"一个内核通吃全系"无法实现。
if [ "$RELAX_VERMAGIC" = "1" ]; then
  log "通用 GKI: 放宽 vendor 模块 vermagic 校验 (只比对主版本号前缀)"
  python3 "$REPO_ROOT/scripts/relax_vermagic.py" kernel/module/main.c \
    || die "放宽 vermagic 失败 (scripts/relax_vermagic.py)"
  grep -q 'vermagic_compat' kernel/module/main.c || die "放宽 vermagic 未生效"
  log "已放宽: 主版本号一致即允许加载 (符号 CRC 校验保持不变)"
else
  warn "RELAX_VERMAGIC=0 -> 维持严格 vermagic 比对 (只加载版本串完全一致的机型)"
fi

# --------------------------- 5. SuSFS (默认关闭) -----------------------------
# 严格 fail-fast 集成, 逻辑见 scripts/apply_susfs.sh:
#   * 内核侧: susfs4ksu 官方 gki-android15-6.6 补丁 (要求零 fuzz, 否则直接失败)
#   * KSU 侧 : 自包含适配层 kernel/feature/susfs_adapter.c
#              (上游 10_enable_susfs_for_ksu.patch 是给老版 KernelSU 写的,
#               与 FolkSU/FinaSU 当前结构代差过大, 不用)
# 旧实现用 patch -F3 + warn "冲突" 后继续, 会产出"看着有 SUSFS 实际没编进去"的包,
# 这里改为任何异常即 die。
if [ "$APPLY_SUSFS" = "1" ]; then
  log "5. 集成 SuSFS (标准全套, 严格校验)"
  SUSFS_DIR="$WORKDIR/susfs4ksu"
  [ -d "$SUSFS_DIR/kernel_patches" ] || {
    rm -rf "$SUSFS_DIR"
    git clone --depth=1 --branch gki-android15-6.6 \
      https://github.com/ShirkNeko/susfs4ksu.git "$SUSFS_DIR" \
      || die "克隆 susfs4ksu 失败"
  }
  [ -f "$SUSFS_DIR/kernel_patches/50_add_susfs_in_gki-android15-6.6.patch" ] \
    || die "susfs4ksu 缺少 6.6 内核补丁"
  bash "$REPO_ROOT/scripts/apply_susfs.sh" "$SUSFS_DIR" "$CFGFILE" \
    || die "SUSFS 集成失败 (见上方 [susfs] 输出)"
  SUSFS_APPLIED=1
else
  warn "APPLY_SUSFS=0 -> 不集成 SuSFS"
  SUSFS_APPLIED=0
fi

# ---- BBG (Baseband-guard) 防格机 ----
# 集成方式 (来自上游 setup.sh 的实际逻辑, 已核对):
#   * setup.sh 以 pwd 为 GKI_ROOT 定位内核根目录, 必须在 KERNEL_DIR 下执行
#   * 它自己管 clone: 目录已存在就 fetch + checkout main
#   * 6.6 有现代 LSM (include/linux/lsm_hooks.h 里的 DEFINE_LSM(lsm)),
#     所以走"标准 LSM blob 管理"分支, 不会去改 selinux (老内核才需要 sepatch.txt)
#   * 它只挂源码 (security/baseband-guard 符号链接 + security/{Makefile,Kconfig}),
#     CONFIG_BBG 和 LSM 列表要我们自己加 -> 见 defconfig 之后的 .config 改造
if [ "$APPLY_BBG" = "1" ]; then
  log "应用 BBG (Baseband-guard) 防格机补丁"
  # 第 142 行已把 cwd 切到源码根 (KERNEL_DIR), 这里必须全部用相对路径:
  # 写成 "$KERNEL_DIR/Baseband-guard" 会在 common/ 里再套一层, 变成 common/common/Baseband-guard,
  # 而 setup.sh 以 pwd 为 GKI_ROOT, 于是报 "security/ not found" / "cannot open setup.sh"
  [ -d Baseband-guard/.git ] || git clone --depth=1 https://github.com/vc-teahouse/Baseband-guard.git Baseband-guard
  sh Baseband-guard/setup.sh || die "BBG setup.sh 执行失败"
  # setup.sh 实际追加的是 "obj-$(CONFIG_BBG) += baseband-guard/"
  # (不是 "baseband-guard/baseband_guard.o" —— 那是 setup.sh 自己的幂等判断字符串)
  grep -q 'baseband-guard/' security/Makefile \
    || die "BBG: security/Makefile 没被更新"
  echo "    已挂载 security/baseband-guard, security/{Makefile,Kconfig} 已更新"
fi

# --------------------------- 6. 追加 defconfig -------------------------------
log "追加 defconfig 配置项"

# ---- zram 压缩算法加强 (仅原生符号, 不打任何源码补丁) ----
# 出厂内核现状: ZRAM=m, 默认 lzo-rle, 只有 LZO/ZSTD/LZ4。
# 这里把 LZ4/LZ4HC/LZO/842/ZSTD 五种后端全开(lz4/lz4hc 在同一条 choice 里只能选一个做默认,
# 所以默认给 lz4 —— 比 lzo-rle 快), 并开 WRITEBAOK + MULTI_COMP + ACTIME(ACTIME 是
# MULTI_COMP 重压缩与 idle writeback 的前提)。运行时可切: cat /sys/block/zram0/comp_algorithm。
if [ "$APPLY_ZRAM" = "1" ]; then
  log "zram 算法加强 (全后端 + writeback + multi-comp)"
  cat >> "$CFGFILE" <<'EOF'
CONFIG_CRYPTO_LZ4=y
CONFIG_CRYPTO_LZ4HC=y
CONFIG_CRYPTO_LZO=y
CONFIG_CRYPTO_842=y
CONFIG_CRYPTO_ZSTD=y
CONFIG_ZRAM_DEF_COMP_LZ4=y
CONFIG_ZRAM_WRITEBACK=y
CONFIG_ZRAM_TRACK_ENTRY_ACTIME=y
CONFIG_ZRAM_MULTI_COMP=y
CONFIG_ZSMALLOC=y
EOF
  log "  运行时可在 /sys/block/zram0/comp_algorithm 切换 lz4/lz4hc/zstd/lzo/842"
fi

# ---- 网络/TCP 增强 (仅原生符号) ----
# 出厂内核: DEFAULT_TCP_CONG="cubic", 只有 CUBIC/BBR, NETFILTER_XT_MATCH_ADDRTYPE=n。
# 这里: 补齐 6 种原生拥塞控制(BBR/Cubic/Vegas/NewVegas/Westwood/HTCP, 全部实测存在
# 于 net/ipv4/Kconfig), 把 FQ/FQ_CODEL(与 BBR 配套)/CAKE/HTB 队列调度打开,
# 再加 netfilter 的 ipset 框架与常用 xt match(均实测存在于本树)。
if [ "$APPLY_NET" = "1" ]; then
  log "网络/TCP 增强 (BBR+多拥塞控制 + fq 队列 + ipset/xtables 扩展)"
  cat >> "$CFGFILE" <<'EOF'
# 拥塞控制 (6.6 原生)
CONFIG_TCP_CONG_ADVANCED=y
CONFIG_TCP_CONG_BBR=y
CONFIG_TCP_CONG_CUBIC=y
CONFIG_TCP_CONG_VEGAS=y
CONFIG_TCP_CONG_NV=y
CONFIG_TCP_CONG_WESTWOOD=y
CONFIG_TCP_CONG_HTCP=y
# 队列调度 (BBR 需要 fq 才完整生效)
CONFIG_NET_SCH_FQ=y
CONFIG_NET_SCH_FQ_CODEL=y
CONFIG_NET_SCH_CAKE=y
CONFIG_NET_SCH_HTB=y
# netfilter: ipset 框架 + 常用 xt match
CONFIG_IP_SET=y
CONFIG_IP_SET_BITMAP_IP=y
CONFIG_IP_SET_HASH_IP=y
CONFIG_IP_SET_HASH_NET=y
CONFIG_IP_SET_HASH_NETPORT=y
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_NETFILTER_XT_SET=y
CONFIG_NETFILTER_XT_TARGET_LOG=y
CONFIG_NETFILTER_XT_MATCH_RECENT=y
EOF
  if [ "$TCP_DEFAULT_CONG" != "cubic" ]; then
    echo "CONFIG_DEFAULT_TCP_CONG=$TCP_DEFAULT_CONG" >> "$CFGFILE"
    log "  默认拥塞控制: $TCP_DEFAULT_CONG (BBR 会增加耗电/发热, 移动网络可能速率波动)"
  else
    log "  默认拥塞控制保持 cubic (只是把 bbr 等编译进去, 运行时可切)"
  fi
fi
cat >> "$CFGFILE" <<'EOF'
CONFIG_TMPFS_XATTR=y
CONFIG_TMPFS_POSIX_ACL=y
CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y
EOF
if [ "$APPLY_KSU" = "1" ]; then
  echo 'CONFIG_KSU=y' >> "$CFGFILE"
fi
# SUSFS 未集成时显式关闭 (集成时 apply_susfs.sh 已写入全套 =y)
if [ "$SUSFS_APPLIED" != "1" ] && [ "$APPLY_KSU" = "1" ] \
   && ! grep -q '^CONFIG_KSU_SUSFS=' "$CFGFILE"; then
  echo 'CONFIG_KSU_SUSFS=n' >> "$CFGFILE"
fi
if [ "$ENABLE_BTF" = "1" ]; then
  log "启用 BTF (给第三方 scx 调度器用)"
  command -v pahole >/dev/null 2>&1 || die "ENABLE_BTF=1 但没有 pahole (apt install dwarves)"
  cat >> "$CFGFILE" <<'EOF'
CONFIG_DEBUG_INFO_BTF=y
CONFIG_DEBUG_INFO_BTF_MODULES=y
CONFIG_MODULE_ALLOW_BTF_MISMATCH=y
EOF
  pahole --version | sed 's/^/    pahole /'
else
  # 完整厂商树(v_*)的 gki_defconfig 自带 CONFIG_DEBUG_INFO_BTF=y, 而 ubuntu-22.04 的
  # apt pahole (dwarves 1.22) 读不了 clang 18 生成的 BTF, 会死在最后一步:
  #     libbpf: BTF header not found
  #     pahole: .tmp_vmlinux.btf: Invalid argument
  #     FAILED: load BTF from vmlinux: Invalid argument
  # 风驰 HMBIRD 是内置的, 不依赖 BTF; BTF 只在装第三方 scx (CO-RE) 调度器时才需要,
  # 所以 ENABLE_BTF=0 时必须【显式关掉】, 否则不管用什么工具链都会在链接阶段失败。
  log "不启用 BTF: 强制关闭厂商树自带的 DEBUG_INFO_BTF"
  sed -i \
    -e 's/^CONFIG_DEBUG_INFO_BTF=y/# CONFIG_DEBUG_INFO_BTF is not set/' \
    -e 's/^CONFIG_DEBUG_INFO_BTF_MODULES=y/# CONFIG_DEBUG_INFO_BTF_MODULES is not set/' \
    -e 's/^CONFIG_MODULE_ALLOW_BTF_MISMATCH=y/# CONFIG_MODULE_ALLOW_BTF_MISMATCH is not set/' \
    -e 's/^CONFIG_PAHOLE_VERSION=.*/CONFIG_PAHOLE_VERSION=0/' \
    "$CFGFILE"
  grep -E '^(# CONFIG_DEBUG_INFO_BTF|# CONFIG_MODULE_ALLOW_BTF_MISMATCH)' "$CFGFILE" \
    | sed 's/^/    /' | sort -u
fi

# --------------------------- 7. 编译 -----------------------------------------
log "开始编译 (jobs=$JOBS, toolchain=$TOOLCHAIN, target=$BUILD_TARGET)"
MAKE_ARGS=(
  -j"$JOBS"
  ARCH=arm64
  CROSS_COMPILE=aarch64-linux-gnu-
  CC=clang
  LD=ld.lld
  HOSTCC=clang
  HOSTLD=ld.lld
  O=out
  KCFLAGS="-O2 -Wno-error"
  KSU_EXPECTED_SIZE="$KSU_EXPECTED_SIZE"
  KSU_EXPECTED_HASH="$KSU_EXPECTED_HASH"
)
if [ "$TOOLCHAIN" = "android" ]; then
  # Android clang 预编译包: LLVM=1 让它用包内非版本化的 llvm-* 工具(与 cctv18 配方一致)
  MAKE_ARGS+=( LLVM=1 )
  log "工具链: Android clang ($(command -v clang))"
  clang --version | head -1 | sed 's/^/    /'
  ld.lld --version 2>/dev/null | head -1 | sed 's/^/    /'
else
  MAKE_ARGS+=( "LLVM=-$CLANG_VER" CROSS_COMPILE_ARM32=arm-linux-gnueabihf- )
  log "工具链: 发行版 clang-$CLANG_VER"
fi

if [ "$USE_REF_CONFIG" = "1" ]; then
  log "==> make olddefconfig (基于参考内核完整 .config)"
  make "${MAKE_ARGS[@]}" olddefconfig
else
  make "${MAKE_ARGS[@]}" gki_defconfig
fi

# BBG 的 CONFIG_BBG + LSM 列表必须在 defconfig 之后用 scripts/config 改:
# CONFIG_LSM 是字符串选项, 只能"追加"不能覆盖 —— 覆盖会顺手关掉 landlock/lockdown/
# integrity/bpf 等已有的 LSM, 属于静默破坏。
if [ "$APPLY_BBG" = "1" ]; then
  log "配置 BBG (CONFIG_BBG=y + LSM 追加 baseband_guard)"
  scripts/config --file out/.config --enable BBG
  LSM_NOW="$(sed -n 's/^CONFIG_LSM="\(.*\)"$/\1/p' out/.config | head -1)"
  if [ -z "$LSM_NOW" ]; then
    scripts/config --file out/.config --set-str LSM baseband_guard
    echo "    CONFIG_LSM 原本为空 -> 仅 baseband_guard (注意: 会没有其他 LSM)"
  elif [ "${LSM_NOW#*,baseband_guard}" != "$LSM_NOW" ] || [ "${LSM_NOW%,baseband_guard}" != "$LSM_NOW" ] || [ "$LSM_NOW" = "baseband_guard" ]; then
    echo "    CONFIG_LSM 已含 baseband_guard, 跳过追加"
  else
    scripts/config --file out/.config --set-str LSM "${LSM_NOW},baseband_guard"
    echo "    CONFIG_LSM: $LSM_NOW -> ${LSM_NOW},baseband_guard"
  fi
  grep -E '^(CONFIG_BBG|CONFIG_LSM)=' out/.config | sed 's/^/    /'
  grep -q '^CONFIG_BBG=y' out/.config || die "CONFIG_BBG 没被打开 (检查 security/baseband-guard/Kconfig)"
fi

# 关键配置校验 (调度的判断要"树无关":
#   公开 b_* 分支是 CONFIG_SCHED_CLASS_EXT, 完整 v_* 厂商树是原装 CONFIG_HMBIRD_SCHED)
if grep -q '^CONFIG_HMBIRD_SCHED=y' out/.config; then
  SCHED_CFG=CONFIG_HMBIRD_SCHED
elif grep -q '^CONFIG_SCHED_CLASS_EXT=y' out/.config; then
  SCHED_CFG=CONFIG_SCHED_CLASS_EXT
else
  die "既没有 CONFIG_HMBIRD_SCHED 也没有 CONFIG_SCHED_CLASS_EXT (调度配置异常)"
fi
echo "    调度类 = $SCHED_CFG $( [ "$SCHED_CFG" = CONFIG_HMBIRD_SCHED ] && echo '(风驰 HMBIRD)' || echo '(AOSP sched_ext)' )"
CHECKS="CONFIG_KPROBES CONFIG_EXT4_FS"
[ "$APPLY_KSU" = "1" ] && CHECKS="CONFIG_KSU $CHECKS"
[ "$ENABLE_BTF" = "1" ] && CHECKS="$CHECKS CONFIG_DEBUG_INFO_BTF"
for c in $CHECKS; do
  grep -q "^${c}=y" out/.config || die "$c 未启用 (内核配置异常)"
  echo "    $c = y"
done
grep -m1 '^CONFIG_LOCALVERSION=' out/.config | sed 's/^/    /'

make "${MAKE_ARGS[@]}" "$BUILD_TARGET"

IMAGE="$PWD/out/arch/arm64/boot/Image"
[ -f "$IMAGE" ] || die "编译失败: 找不到 $IMAGE"

# --------------------------- 8. 校验 + 输出 ----------------------------------
log "校验产物"
UTS="$(strings -a "$IMAGE" | grep -m1 '^Linux version' || true)"
echo "    $UTS"
# 注意: 后缀以 '-' 开头, 必须用 -- 终止选项解析, 否则 grep 把它当参数而报错(误报)
[ -n "$UTS" ] && { echo "$UTS" | grep -q -- "$LOCALVERSION_SUFFIX" \
  || warn "UTS_RELEASE 未包含 $LOCALVERSION_SUFFIX"; }
for m in hmbird hmbird_sched KernelSU; do
  printf '    标记 %-14s %s 次\n' "$m" "$(grep -a -o "$m" "$IMAGE" | wc -l)"
done
[ "$SCHED_CFG" = "CONFIG_HMBIRD_SCHED" ] && { grep -aq 'hmbird_sched' "$IMAGE" \
  || die "配置里 CONFIG_HMBIRD_SCHED=y 但镜像里找不到 hmbird_sched, 风驰没编进去"; \
  grep -aq 'hmbird_sched' "$IMAGE" && echo "    ✅ 风驰(HMBIRD) 符号确认存在"; }

mkdir -p "$WORKDIR/out"
cp "$IMAGE" "$WORKDIR/out/Image"
{
  # 注意: 内核是带 O=out 编的, kernel.release 在 out/include/config/ 下
  echo "UTS_RELEASE=$(cat out/include/config/kernel.release 2>/dev/null || cat include/config/kernel.release 2>/dev/null || echo unknown)"
  echo "KERNEL_REPO=$KERNEL_REPO"
  echo "KERNEL_BRANCH=$KERNEL_BRANCH"
  echo "KERNEL_SOURCE_HEAD=$SRC_HEAD"
  echo "FINASU_REPO=$KSU_REPO"
  echo "FINASU_TAG=$KSU_TAG"
  echo "KSU_VERSION=${KSU_VERSION:-N/A (未集成 KernelSU)}"
  echo "KSU_UAPI=${KSU_UAPI:-N/A (未集成 KernelSU)}"
  echo "KSU_EXPECTED_SIZE=$KSU_EXPECTED_SIZE"
  echo "KSU_EXPECTED_HASH=$KSU_EXPECTED_HASH"
  echo "FENGCHI=$APPLY_FENGCHI"
  echo "SUSFS=$SUSFS_APPLIED"
  echo "BUILT_AT=$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
} | tee "$WORKDIR/out/build-info.txt"

log "编译完成 -> $WORKDIR/out/Image"
