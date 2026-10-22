#!/bin/bash
# ============================================================================
# SUSFS 标准全套 —— 一加 Ace 6 + FinaSU(FolkSU)
#
# 设计:
#   * 内核侧 = susfs4ksu 官方 gki-android15-6.6 补丁
#     (已实测: 对 OnePlus ace_6 树 25 个文件零 fuzz 干净套用)
#   * KSU 侧 = 本脚本写的自包含适配层 feature/susfs_adapter.c
#     上游 10_enable_susfs_for_ksu.patch 是给老版 KernelSU 写的, 与 FinaSU
#     当前目录结构代差过大(9 hunk 冲突 + ksu_late_loaded 等 8 处悬空引用),
#     故不使用; 改为只补齐内核侧补丁真正引用的 KSU 符号。
#   * 全流程 fail-fast: 任一校验不过即 die, 绝不产出"假 SUSFS"包。
#
# 在 KERNEL_DIR(内核源码根, 即 common/) 下执行:
#   bash apply_susfs.sh <susfs4ksu目录> [CFGFILE]
# ============================================================================
set -euo pipefail

SUSFS_DIR="${1:?用法: apply_susfs.sh <susfs4ksu目录> [CFGFILE]}"
CFGFILE="${2:-arch/arm64/configs/gki_defconfig}"
KROOT="$(pwd)"
# 本脚本所在目录 (用它引用同目录的辅助脚本)。
# 用 $0 而非 BASH_SOURCE: Android 的 sh(mksh) 没有 BASH_SOURCE 数组,
# 而本脚本在手机本地与 CI(gawk/bash) 下都要能跑。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 放中间产物(精简后的补丁)的临时目录
WORKDIR_TMP="$(mktemp -d 2>/dev/null || echo /tmp/susfs_apply.$$)"
mkdir -p "$WORKDIR_TMP"

log() { echo "    [susfs] $*"; }
die() { echo "!!! [susfs] 致命: $*" >&2; exit 1; }

# 确保某个 C 文件能拿到 static_key API (DEFINE_STATIC_KEY_*/static_branch_*)
# 只在第一次出现 #include 的行前插入一次 (用 awk, 避免 sed 地址区间重复命中)
include_static_key() {
  local f="$1"
  grep -qE '#include <linux/(static_key|jump_label)\.h>' "$f" && return 0
  awk 'BEGIN{done=0} { if (!done && /^#include/) { print "#include <linux/static_key.h>"; done=1 } print }' \
      "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  grep -qE '#include <linux/(static_key|jump_label)\.h>' "$f" \
    || die "$f: 无法插入 <linux/static_key.h>"
  [ "$(grep -c '#include <linux/static_key.h>' "$f")" = "1" ] \
    || die "$f: static_key.h 插入次数异常"
}

log "源码根 : $KROOT"
log "susfs源: $SUSFS_DIR"
log "配置   : $CFGFILE"

[ -d "$SUSFS_DIR/kernel_patches" ] || die "找不到 $SUSFS_DIR/kernel_patches"
KP="$SUSFS_DIR/kernel_patches"
P50="$KP/50_add_susfs_in_gki-android15-6.6.patch"
[ -f "$P50" ] || die "找不到内核补丁 $P50"

# ---------------------------------------------------------------- 1. 内核实现
log "1/6 放入 SUSFS 内核实现 (fs/susfs.c + include/linux/susfs{,_def}.h)"
cp "$KP/fs/susfs.c"                fs/susfs.c                || die "拷贝 fs/susfs.c 失败"
cp "$KP/include/linux/susfs.h"     include/linux/susfs.h     || die "拷贝 susfs.h 失败"
cp "$KP/include/linux/susfs_def.h" include/linux/susfs_def.h || die "拷贝 susfs_def.h 失败"
[ -s fs/susfs.c ] || die "fs/susfs.c 为空"

# ------------------------------------------------------------ 2. 内核侧补丁
log "2/6 应用内核侧补丁"

# 关键: 先摘掉 SUSFS 对 security/selinux/{avc,hooks,selinuxfs}.c 的改动。
# FinaSU 自己已经用另一套机制实现了同样的 SELinux 隐藏:
#   selinux_hide.c 运行时 patch sel_handle_status_ops->open + LSM hook setprocattr
#   avc_spoof.c    kprobe 拦 slow_avc_audit
# SUSFS 又在源码层改同一批函数 -> 两层叠加, SELinux 对外行为与原包不同,
# 会被"春秋检测"之类工具判为可疑 SELinux (实测: 不带 SUSFS 的原包不报, 带则报)。
# 摘除后 SELinux 行为回到与 FinaSU 原包一致, SUSFS 其余功能全部保留。
P50_USE="$P50"
P50_STRIPPED="$WORKDIR_TMP/50_susfs_no_selinux.patch"
mkdir -p "$WORKDIR_TMP"
node "$SCRIPT_DIR/strip_selinux_hunks.js" "$P50" "$P50_STRIPPED" || die "摘除 SELinux 改动失败"
P50_USE="$P50_STRIPPED"

# 已知基线差异 (v_15 / 6.6.66 实测): fs/proc/base.c 里没有 <linux/dma-buf.h>,
# 而补丁正是拿它当锚点插入 susfs_def.h 的 include -> hunk#1 必然失败。
# 这里先按同样的位置补上这一行, 让上下文对上 (补的是标准 include, 无副作用)。
if [ -f fs/proc/base.c ] && ! grep -q '<linux/dma-buf.h>' fs/proc/base.c; then
  awk '{print} /#include <linux\/cpufreq_times.h>$/{print "#include <linux/dma-buf.h>"}' \
    fs/proc/base.c > "$WORKDIR_TMP/base.c.new" \
    && mv "$WORKDIR_TMP/base.c.new" fs/proc/base.c || die "预修 fs/proc/base.c 失败"
  grep -q '<linux/dma-buf.h>' fs/proc/base.c \
    && echo "    预修: fs/proc/base.c 补入 <linux/dma-buf.h> (该基线缺这一行)" \
    || die "预修 fs/proc/base.c 未生效"
fi

# 两个坑 (都是实测踩到的):
#   1) toybox patch 的 --dry-run **仍会改文件**, 所以不能拿它当"纯预检";
#   2) 风驰补丁已给树带来 +3 行左右的漂移, 用 -F0 会误判, 必须留 fuzz。
# 因此: 直接以 -F3 正式应用, 然后靠 "FAILED / .rej / 关键产物" 三重校验兜底。
PATCH_OUT="$(patch -p1 -F3 --no-backup-if-mismatch -i "$P50_USE" 2>&1)" || true
echo "$PATCH_OUT" | grep -iE 'succeeded at .*offset' | sed 's/^/    /' || true
if echo "$PATCH_OUT" | grep -qiE 'FAILED'; then
  echo "$PATCH_OUT" | grep -iE 'FAILED' | sed 's/^/    /'
  die "内核侧补丁有 hunk 失败, 需重基"
fi
REJ="$(find . -name '*.rej' -not -path './.git/*' | wc -l)"
[ "$REJ" = "0" ] || { find . -name '*.rej' | sed 's/^/    /'; die "有 $REJ 个 .rej"; }
# 关键产物校验: 确认补丁真的落到了它应该落的地方。
# 注意: C 代码里写的是 <linux/susfs_def.h>, 点号在 '>' 之前,
# 所以子串必须写成 "susfs_def.h>" —— 写成 "susfs_def.h" 永远匹配不到。
grep -q 'susfs.o' fs/Makefile                    || die "fs/Makefile 未挂入 susfs.o (补丁没生效?)"
grep -q 'ksu_is_input_hook_enabled' drivers/input/input.c || die "drivers/input/input.c 未打上输入钩子"
grep -q 'ksu_handle_sys_reboot' kernel/reboot.c  || die "kernel/reboot.c 未打上 SUSFS 分派"
# 反向确认: 三个 SELinux 文件必须**没有**被 SUSFS 改动 (否则又会和 FinaSU 打架)
for f in security/selinux/avc.c security/selinux/hooks.c security/selinux/selinuxfs.c; do
  grep -q 'CONFIG_KSU_SUSFS' "$f" && die "$f 仍被 SUSFS 改动 (会与 FinaSU 的 SELinux 隐藏冲突)"
done
log "    已应用, 0 reject; SELinux 三个文件保持原样 (交给 FinaSU 自己的机制)"

# ------------------------------------------------------- 3. FinaSU 侧改动
log "3/6 FinaSU 侧适配改动"

# 定位 KernelSU 源码根。
# CI 里 KernelSU clone 在源码根的 KernelSU/, 真正的模块源码在 KernelSU/kernel/,
# 并由 drivers/kernelsu -> ../KernelSU/kernel 软链参与编译。这里统一解析出前缀。
KS=""
for c in KernelSU/kernel drivers/kernelsu kernel; do
  if [ -f "$c/feature/sucompat.c" ] && [ -f "$c/Kbuild" ]; then KS="$c"; break; fi
done
[ -n "$KS" ] || die "找不到 KernelSU 源码根 (期望 KernelSU/kernel 或 drivers/kernelsu)"
log "    KernelSU 源根: $KS"

# 3a. selinux_hide.c 去 static —— 内核侧 security/selinux/{hooks,selinuxfs}.c
#     以 extern 引用这些符号, 必须从 static 变全局。
SH="$KS/feature/selinux_hide.c"
[ -f "$SH" ] || die "找不到 $SH"
for sym in ksu_selinux_hide_enabled ksu_selinux_hide_running; do
  grep -q "static bool $sym" "$SH" || die "$SH: 未找到 'static bool $sym'"
  sed -i "s/^static bool $sym/bool $sym/" "$SH"
done
sed -i 's/^static DEFINE_STATIC_KEY_FALSE(fake_status_initialize_key)/DEFINE_STATIC_KEY_FALSE(fake_status_initialize_key)/' "$SH"
sed -i 's/^static struct page \*fake_status = NULL/struct page *fake_status = NULL/' "$SH"
sed -i 's/^static void initialize_fake_status(/void initialize_fake_status(/' "$SH"
grep -qE '^DEFINE_STATIC_KEY_FALSE\(fake_status_initialize_key\)' "$SH" || die "$SH: fake_status_initialize_key 去 static 失败"
grep -qE '^struct page \*fake_status' "$SH"                            || die "$SH: fake_status 去 static 失败"
grep -qE '^void initialize_fake_status\(' "$SH"                        || die "$SH: initialize_fake_status 去 static 失败"
grep -qE '^bool ksu_selinux_hide_running' "$SH"                         || die "$SH: ksu_selinux_hide_running 去 static 失败"
# 内核侧 security/selinux/{hooks,selinuxfs}.c 还要用这三个 with_policy 函数
# (内核内部策略 API 的薄包装), 也必须去 static。
# 注意 selinux_hide.c 里每处都有"前置声明 + 实际定义"两份, 共 6 个位置;
# 其中 compute_av_user 的定义带 __nocfi 属性。
for pat in security_context_to_sid_with_policy security_sid_to_context_with_policy; do
  sed -i "s/^static int $pat/int $pat/" "$SH"
done
sed -i 's/^static void security_compute_av_user_with_policy/void security_compute_av_user_with_policy/' "$SH"
sed -i 's/^static void __nocfi security_compute_av_user_with_policy/void __nocfi security_compute_av_user_with_policy/' "$SH"
n_left="$(grep -cE '^static (int|void) (__nocfi )?security_(context_to_sid|sid_to_context|compute_av_user)_with_policy' "$SH" || true)"
[ "$n_left" = "0" ] || die "$SH: 仍有 $n_left 处 security_*_with_policy 未去 static"
for f in security_context_to_sid_with_policy security_sid_to_context_with_policy security_compute_av_user_with_policy; do
  grep -qE "^(int|void) (__nocfi )?$f\(" "$SH" || die "$SH: $f 去 static 后未找到定义"
done
log "    selinux_hide.c 去 static 完成 (含 3 个 security_*_with_policy)"

# 3b. ksu_su_compat_enabled: bool -> static_key_true
#     内核侧 fs/exec.c 用 static_branch_likely, 必须是静态键。
#     注意: 静态键不能被赋值 (原代码 su_compat_feature_set 里 `= enable`),
#     必须改成 static_branch_enable/disable, 否则编译报错。
SC="$KS/feature/sucompat.c"; SCH="$KS/feature/sucompat.h"
[ -f "$SC" ] || die "找不到 $SC"
grep -q 'bool ksu_su_compat_enabled' "$SC" || die "$SC: 未找到 bool ksu_su_compat_enabled"
sed -i 's/^bool ksu_su_compat_enabled __read_mostly = true;/DEFINE_STATIC_KEY_TRUE(ksu_su_compat_enabled);/' "$SC"
grep -q 'DEFINE_STATIC_KEY_TRUE(ksu_su_compat_enabled)' "$SC" || die "$SC: 静态键定义失败"
sed -i 's/^extern bool ksu_su_compat_enabled;/extern struct static_key_true ksu_su_compat_enabled;/' "$SCH"
grep -q 'extern struct static_key_true ksu_su_compat_enabled;' "$SCH" || die "$SCH: extern 改型失败"
# 把运行时赋值改成静态键开关
sed -i 's/^\( *\)ksu_su_compat_enabled = enable;/\1if (enable)\n\1\tstatic_branch_enable(\&ksu_su_compat_enabled);\n\1else\n\1\tstatic_branch_disable(\&ksu_su_compat_enabled);/' "$SC"
if grep -qE '^[[:space:]]*ksu_su_compat_enabled[[:space:]]*=' "$SC"; then
  die "$SC: 仍有对静态键的直接赋值 (静态键不可赋值)"
fi
grep -q 'static_branch_enable(&ksu_su_compat_enabled)' "$SC" || die "$SC: 未找到 static_branch_enable"

# 关键: 静态键是 struct static_key_true (内部是 ->enabled), **不能**直接当布尔表达式用,
# 否则 clang 报 "used type 'struct static_key_true' where arithmetic or pointer
# type is required"。所有"读取"处必须换成 static_branch_likely()/unlikely()。
sed -i 's/ksu_su_compat_enabled ? 1 : 0/static_branch_likely(\&ksu_su_compat_enabled) ? 1 : 0/' "$SC"
include_static_key "$SC"

# syscall_event_bridge.c 也用布尔方式引用它 (该文件已不被编译, 但一并改掉以免后患)
if [ -f "$KS/hook/syscall_event_bridge.c" ]; then
  SB="$KS/hook/syscall_event_bridge.c"
  sed -i 's/!ksu_su_compat_enabled/!static_branch_likely(\&ksu_su_compat_enabled)/g' "$SB"
  sed -i 's/} else if (ksu_su_compat_enabled)/} else if (static_branch_likely(\&ksu_su_compat_enabled))/' "$SB"
  include_static_key "$SB"
fi

# 全树兜底检查: 凡把该静态键当布尔裸用(非 static_branch_*)的地方都要拦下来。
# 合法形式只有: static_branch_*() 读取 / DEFINE_STATIC_KEY_* 定义 /
#               extern struct static_key_true 声明。
BADKEY="$(grep -rnE '(^|[^_a-zA-Z])ksu_su_compat_enabled' "$KS" --include=*.c --include=*.h 2>/dev/null \
  | grep -vE 'static_branch_(likely|unlikely|enable|disable)|DEFINE_STATIC_KEY|extern struct static_key_true' || true)"
if [ -n "$BADKEY" ]; then
  echo "$BADKEY" | sed 's/^/    /'
  die "$KS: 仍有把静态键当布尔裸用的地方 (会编译失败)"
fi
log "    ksu_su_compat_enabled -> static_key_true (赋值/读取均已改写)"

# 3c. ksu_handle_setresuid: 补第 3 个参数 (内核侧 kernel/sys.c 按 3 参调用)
#
# 关键: 只"追加"参数, 不改参数名。函数体里有 5 处 old_uid/new_uid 引用,
# 若改名会漏改 -> 编译报 undeclared identifier (run #43 就栽在这里)。
# 经核对: old_uid 实际只用于一行日志, 且传给 ksu_handle_umount 后其函数体
# 根本没用它; 真正决定行为的是 new_uid。而在 __sys_setresuid 开头调用时
# zygote 是三参相同 (setresuid(uid,uid,uid)), 故 new_uid 取到的一定是新 uid,
# 语义正确 —— 因此保留原名、仅加第 3 参是最小且安全的做法。
SHOOK="$KS/hook/setuid_hook.c"; SHOOKH="$KS/hook/setuid_hook.h"
[ -f "$SHOOK" ] || die "找不到 $SHOOK"
sed -i 's/^int ksu_handle_setresuid(uid_t old_uid, uid_t new_uid)$/int ksu_handle_setresuid(uid_t old_uid, uid_t new_uid, uid_t suid)/' "$SHOOK"
grep -q '^int ksu_handle_setresuid(uid_t old_uid, uid_t new_uid, uid_t suid)$' "$SHOOK" \
  || die "$SHOOK: 追加第 3 参失败"
sed -i 's/^int ksu_handle_setresuid(uid_t old_uid, uid_t new_uid);$/int ksu_handle_setresuid(uid_t old_uid, uid_t new_uid, uid_t suid);/' "$SHOOKH"
grep -q 'int ksu_handle_setresuid(uid_t old_uid, uid_t new_uid, uid_t suid);' "$SHOOKH" \
  || die "$SHOOKH: 头文件改签名失败"
# 确保函数体里没有残留的未定义名字 (改名方案已弃用, 这里只做完整性确认)
# 注意: Android 的 toybox grep 不认 \b, 用 POSIX 字符类
if grep -qE '(^|[^_a-zA-Z])(ruid|euid)([^_a-zA-Z]|$)' "$SHOOK"; then
  die "$SHOOK: 函数体里出现了不该有的 ruid/euid (改名残留)"
fi
BE="$KS/hook/syscall_event_bridge.c"
[ -f "$BE" ] && sed -i 's/ksu_handle_setresuid(old_uid, current_uid().val)/ksu_handle_setresuid(old_uid, current_uid().val, current_uid().val)/' "$BE"
log "    ksu_handle_setresuid -> 追加第 3 参 (未改参数名)"

# 3d. 摘除内核侧 fs/exec.c 的 sucompat 钩子块。
#     该块要的 ksu_handle_execveat(*fd, struct filename**, void*, void*, int*) 与
#     FinaSU 的 kprobe 式 ksu_handle_execve*_sucompat(...pt_regs*) 属于两套架构;
#     FinaSU 自己的 sucompat 已能完成 su 检测, 两套并存会互相打架且无法桥接。
#     用 node 摘除(python3 在部分环境不可用; node 在 CI 与本地都可用)。
command -v node >/dev/null 2>&1 || die "需要 node 来摘除 fs/exec.c 钩子"
node "$SCRIPT_DIR/strip_exec_hook.js" fs/exec.c || die "摘除 fs/exec.c sucompat 钩子失败"
grep -q 'ksu_handle_execveat' fs/exec.c && die "fs/exec.c 仍有 ksu_handle_execveat 残留"
log "    fs/exec.c sucompat 钩子已摘除"

# ---------------------------------------------------------------------------
# 3e. SUSFS 域 SID 缓存 -> kernel/selinux/selinux.c
#
# 内核侧 fs/namespace.c、security/selinux/avc.c 等引用了:
#   susfs_is_current_ksu_domain() / susfs_is_current_zygote_domain() / ...
#   susfs_ksu_sid / susfs_priv_app_sid / susfs_zygote_sid ...
# 这些上游是在对接补丁里放进 kernel/selinux/selinux.c 的 (它不是 fs/susfs.c 的职责)。
# 放在 selinux.c 而不是适配层, 是为了直接复用该文件已有的 include
# (objsec.h -> current_sid()/selinux_cred(); 且它本就在用 security_secctx_to_secid)。
SELC="$KS/selinux/selinux.c"
SELH="$KS/selinux/selinux.h"
RULESC="$KS/selinux/rules.c"
for f in "$SELC" "$SELH" "$RULESC"; do [ -f "$f" ] || die "找不到 $f"; done
if grep -q 'susfs_ksu_sid' "$SELC"; then
  log "    selinux.c 已含 SUSFS SID 块, 跳过"
else
  cat >> "$SELC" <<'SEOF'

/* ===================== SUSFS: 域 SID 缓存 (对接层) ===================== */
#define SUSFS_INIT_DOMAIN      "u:r:init:s0"
#define SUSFS_ZYGOTE_DOMAIN    "u:r:zygote:s0"
#define SUSFS_ZYGOTE_NEXT_DOMAIN "u:r:zygote_next:s0"
/* priv_app 的 MLS 字段与上游保持一致 */
#define SUSFS_PRIV_APP_DOMAIN  "u:r:priv_app:s0:c512,c768"

u32 susfs_ksu_sid __read_mostly = 0;
u32 susfs_init_sid __read_mostly = 0;
u32 susfs_zygote_sid __read_mostly = 0;
u32 susfs_zygote_next_sid __read_mostly = 0;
u32 susfs_priv_app_sid __read_mostly = 0;

static void susfs_set_sid(const char *secctx_name, u32 *out_sid)
{
	int err;

	if (!secctx_name || !out_sid)
		return;
	err = security_secctx_to_secid(secctx_name, strlen(secctx_name), out_sid);
	if (err) {
		pr_err("susfs: failed setting sid for '%s', err: %d\n", secctx_name, err);
		return;
	}
	pr_info("susfs: sid '%u' is set for secctx_name '%s'\n", *out_sid, secctx_name);
}

bool susfs_is_sid_equal(const struct cred *cred, u32 sid2)
{
	const struct task_security_struct *tsec = selinux_cred(cred);

	if (!tsec)
		return false;
	return tsec->sid == sid2;
}

u32 susfs_get_sid_from_name(const char *secctx_name)
{
	u32 out_sid = 0;
	int err;

	if (!secctx_name)
		return 0;
	err = security_secctx_to_secid(secctx_name, strlen(secctx_name), &out_sid);
	if (err)
		return 0;
	return out_sid;
}

u32 susfs_get_current_sid(void)
{
	return current_sid();
}

bool susfs_is_current_zygote_domain(void)
{
	return unlikely(current_sid() == susfs_zygote_sid);
}

bool susfs_is_current_zygote_next_domain(void)
{
	return unlikely(current_sid() == susfs_zygote_next_sid);
}

bool susfs_is_current_ksu_domain(void)
{
	return unlikely(current_sid() == susfs_ksu_sid);
}

bool susfs_is_current_init_domain(void)
{
	return unlikely(current_sid() == susfs_init_sid);
}

void susfs_set_batch_sid(void)
{
	susfs_set_sid(SUSFS_ZYGOTE_DOMAIN, &susfs_zygote_sid);
	susfs_set_sid(SUSFS_ZYGOTE_NEXT_DOMAIN, &susfs_zygote_next_sid);
	susfs_set_sid(KERNEL_SU_CONTEXT, &susfs_ksu_sid);
	susfs_set_sid(SUSFS_INIT_DOMAIN, &susfs_init_sid);
	susfs_set_sid(SUSFS_PRIV_APP_DOMAIN, &susfs_priv_app_sid);
}
/* =================== SUSFS: 域 SID 缓存 结束 =================== */
SEOF
  # 声明进 selinux.h (rules.c 要调用 susfs_set_batch_sid)
  if ! grep -q 'susfs_set_batch_sid' "$SELH"; then
    awk 'BEGIN{done=0} { if(!done && /^#endif/){ print "extern u32 susfs_ksu_sid;"; print "extern u32 susfs_init_sid;"; print "extern u32 susfs_zygote_sid;"; print "extern u32 susfs_zygote_next_sid;"; print "extern u32 susfs_priv_app_sid;"; print "bool susfs_is_sid_equal(const struct cred *cred, u32 sid2);"; print "u32 susfs_get_sid_from_name(const char *secctx_name);"; print "u32 susfs_get_current_sid(void);"; print "bool susfs_is_current_zygote_domain(void);"; print "bool susfs_is_current_zygote_next_domain(void);"; print "bool susfs_is_current_ksu_domain(void);"; print "bool susfs_is_current_init_domain(void);"; print "void susfs_set_batch_sid(void);"; print ""; done=1 } print }' "$SELH" > "$SELH.tmp" && mv "$SELH.tmp" "$SELH"
    grep -q 'susfs_set_batch_sid' "$SELH" || die "$SELH: SUSFS 声明插入失败"
  fi
  # 在 apply_kernelsu_rules() 末尾 (reset_avc_cache() 之后) 设置 sid
  # 只改第一个 reset_avc_cache(); (即 apply_kernelsu_rules 内的那个)
  awk 'BEGIN{done=0} { print; if(!done && /^[[:space:]]*reset_avc_cache\(\);/){ print "\tsusfs_set_batch_sid();"; done=1 } }' \
      "$RULESC" > "$RULESC.tmp" && mv "$RULESC.tmp" "$RULESC"
  grep -q 'susfs_set_batch_sid();' "$RULESC" || die "$RULESC: susfs_set_batch_sid() 调用插入失败"
  log "    SUSFS SID 块 -> selinux.c; 声明 -> selinux.h; 初始化 -> rules.c"
fi

# ---------------------------------------------------------- 4. 适配层
log "4/6 写 KSU 适配层 feature/susfs_adapter.c"

cat > "$KS/feature/susfs_adapter.c" <<'CEOF'
// SPDX-License-Identifier: GPL-2.0
/*
 * SUSFS <-> FinaSU(KernelSU) 适配层
 *
 * 只补齐 susfs4ksu 内核侧补丁 (50_add_susfs_in_gki-android15-6.6.patch)
 * 真正引用的 KSU 符号; 其余一律交给 FinaSU 已有实现。
 *
 * 为什么不用上游 10_enable_susfs_for_ksu.patch:
 *   它是针对老版 KernelSU 写的, 与本树 (FinaSU, kernel/{core,feature,hook,
 *   policy,runtime,selinux,sulog,supercall} 新布局) 代差过大 —— 95 hunk 里
 *   9 个无法匹配, 且失败会引发 ksu_late_loaded / ksu_bundled /
 *   symbol_resolver / lsm_hook 等 8+ 处悬空引用, 严格套用必然编译失败。
 */
#include <linux/types.h>
#include <linux/cred.h>
#include <linux/sched.h>
#include <linux/fs.h>
#include <linux/file.h>
#include <linux/uaccess.h>
#include <linux/static_key.h>
#include <linux/version.h>
#include <linux/susfs_def.h>
#include <linux/susfs.h>

#include "klog.h" // IWYU pragma: keep
#include "ksu.h"
#include "supercall/supercall.h"
#include "uapi/supercall.h" // KSU_INSTALL_MAGIC1

/* ---- 1) 内核侧补丁引用的静态键 ---- */

/* drivers/input/input.c: static_branch_unlikely 后直接调用
 * ksu_handle_input_handle_event(); FinaSU 用无条件 kprobe, 没有这个键。
 * 补上并默认开启, 语义等价 (开机后按音量下 3 次即关闭输入钩子)。 */
DEFINE_STATIC_KEY_TRUE(ksu_is_input_hook_enabled);

/* fs/read_write.c / fs/stat.c: 用于跳过 init.rc 阶段处理。FinaSU 有等价的
 * rc_hooked 逻辑, 这里给一把常开的键即可满足内核侧引用。 */
DEFINE_STATIC_KEY_TRUE(ksu_is_init_rc_hook_enabled);

/* ---- 2) 内核侧补丁引用的处理函数 (签名须与 50 补丁 extern 逐字一致) ---- */

/* fs/stat.c / fs/open.c / fs/exec.c 中用于 su 路径的场景化处理。
 * FinaSU 的 su 检测与提权由自己的 syscall 钩子完成, 此处无需重复,
 * 返回 0 = "无需额外处理"。 */
int ksu_handle_stat(int *dfd, struct filename **filename_ptr, int *flags)
{
	return 0;
}

int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags)
{
	return 0;
}

/* fs/read_write.c: 50 补丁声明为单参 ksu_handle_sys_read(unsigned int fd) */
void ksu_handle_sys_read(unsigned int fd)
{
}

/* fs/stat.c: 50 补丁声明为 ksu_handle_vfs_fstat(int fd, loff_t *kstat_size_ptr) */
void ksu_handle_vfs_fstat(int fd, loff_t *kstat_size_ptr)
{
}

/* ---- 2b) 域判断 ----
 *
 * susfs_is_current_ksu_domain() / susfs_get_current_sid() 等等由
 * kernel/selinux/selinux.c 里的 SUSFS SID 块提供 (见脚本第 3e 步),
 * 那里和上游对接补丁的做法一致 (用 current_sid() 与缓存的 sid 比较)。
 */

/* ---- 3) SUSFS 用户态命令入口 ----
 *
 * FinaSU 管理器/ksud 下发方式 (已核对其 userspace/ksud/src/susfs/abi.rs):
 *   syscall(SYS_reboot, 0xdeadbeef, 0xfafafafa, CMD_SUSFS_*, &payload)
 * 内核侧 kernel/reboot.c 会调用本函数, 我们按 SUSFS_MAGIC 分派。
 */
int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg)
{
	if (magic1 != KSU_INSTALL_MAGIC1)
		return -EINVAL;
	if (magic2 != SUSFS_MAGIC)
		return -EINVAL;
	/* 仅 root 可下发 (与上游 susfs 一致) */
	if (current_uid().val != 0)
		return -EPERM;

	switch (cmd) {
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
	case CMD_SUSFS_ADD_SUS_PATH:
		susfs_add_sus_path(arg);
		return 0;
	case CMD_SUSFS_ADD_SUS_PATH_LOOP:
		susfs_add_sus_path_loop(arg);
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
	case CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS:
		susfs_set_hide_sus_mnts_for_non_su_procs(arg);
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
	case CMD_SUSFS_ADD_SUS_KSTAT:
	case CMD_SUSFS_ADD_SUS_KSTAT_STATICALLY:
		susfs_add_sus_kstat(arg);
		return 0;
	case CMD_SUSFS_UPDATE_SUS_KSTAT:
		susfs_update_sus_kstat(arg);
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
	case CMD_SUSFS_SET_UNAME:
		susfs_set_uname(arg);
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_ENABLE_LOG
	case CMD_SUSFS_ENABLE_LOG:
		susfs_enable_log(arg);
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
	case CMD_SUSFS_SET_CMDLINE_OR_BOOTCONFIG:
		susfs_set_cmdline_or_bootconfig(arg);
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
	case CMD_SUSFS_ADD_OPEN_REDIRECT:
		susfs_add_open_redirect(arg);
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
	case CMD_SUSFS_ADD_SUS_MAP:
		susfs_add_sus_map(arg);
		return 0;
#endif
	case CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING:
		susfs_set_avc_log_spoofing(arg);
		return 0;
	case CMD_SUSFS_SHOW_ENABLED_FEATURES:
		susfs_get_enabled_features(arg);
		return 0;
	case CMD_SUSFS_SHOW_VARIANT:
		susfs_show_variant(arg);
		return 0;
	case CMD_SUSFS_SHOW_VERSION:
		susfs_show_version(arg);
		return 0;
	default:
		pr_info("susfs: unknown cmd 0x%x\n", cmd);
		return -EINVAL;
	}
}
CEOF
[ -s "$KS/feature/susfs_adapter.c" ] || die "susfs_adapter.c 写入失败"
grep -q "ksu_handle_sys_reboot" "$KS/feature/susfs_adapter.c" || die "适配层缺少 ksu_handle_sys_reboot"
grep -q "ksu_handle_vfs_fstat" "$KS/feature/susfs_adapter.c" || die "适配层缺少 ksu_handle_vfs_fstat"
log "    适配层已写入 ($(wc -l < "$KS/feature/susfs_adapter.c") 行)"

# 链接期兜底: fs/susfs.c 以 extern 引用的每个符号, 必须能由
#   (a) 内核侧 50 补丁, (b) FinaSU 自身, 或 (c) 本适配层 之一提供。
# 上游对接补丁里定义过 susfs_is_current_ksu_domain() 之类的东西, 我们没用那个
# 补丁, 所以必须自己逐个确认 —— 漏一个就是一轮 CI 才发现的 undefined symbol。
log "    校验 SUSFS 侧 extern 符号是否都有提供者"
node "$SCRIPT_DIR/check_symbols.js" fs/susfs.c "$P50_USE" "$KS" \
     "$KS/feature/susfs_adapter.c" \
  || die "SUSFS 有符号无人提供 (会 undefined symbol, 见上方列表)"

# 挂进 Kbuild —— 直接用已定位的 KS 前缀, 避免误挂到内核源码根自己的 Kbuild
KB="$KS/Kbuild"
[ -f "$KB" ] || die "找不到 KernelSU 的 Kbuild: $KB"
grep -q 'kernelsu-objs' "$KB" || die "$KB 不是 KernelSU 的 Kbuild (无 kernelsu-objs)"
# 适配层源码在 feature/ 下, 从 Kbuild 所在目录 (KSU 根) 看就是 feature/susfs_adapter.o
grep -q 'susfs_adapter.o' "$KB" || printf 'kernelsu-objs += feature/susfs_adapter.o\n' >> "$KB"
grep -q 'susfs_adapter.o' "$KB" || die "$KB: 未挂入 susfs_adapter.o"
log "    已挂入 $KB"

# ------------------------------------------------------------- 5. 配置
log "5/6 写入 SUSFS 标准全套配置 -> $CFGFILE"
[ -f "$CFGFILE" ] || die "找不到配置文件 $CFGFILE"
sed -i '/^CONFIG_KSU_SUSFS/d' "$CFGFILE"
cat >> "$CFGFILE" <<'CFGEOF'
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CFGEOF
NCFG="$(grep -c '^CONFIG_KSU_SUSFS' "$CFGFILE")"
[ "$NCFG" = "10" ] || die "SUSFS 开关数量异常: $NCFG (期望 10)"
log "    10 个 SUSFS 开关已写入"

# ------------------------------------------------- 4b. SUSFS Kconfig 开关
# 关键: CONFIG_KSU_SUSFS_* 这些开关原本由上游对接补丁写进 kernel/Kconfig。
# 我们没用那个补丁, 所以必须自己把菜单补进 KernelSU 的 Kconfig, 否则
# defconfig 里的 CONFIG_KSU_SUSFS=y 会被 kconfig 当作未知符号丢弃 ——
# 结果是"看着配了 SUSFS, 实际一行代码都没编进去"的假包。
KCONF="$KS/Kconfig"
[ -f "$KCONF" ] || die "找不到 KernelSU Kconfig: $KCONF"
KMENU="$SCRIPT_DIR/susfs_kconfig.txt"
[ -s "$KMENU" ] || die "缺少 SUSFS Kconfig 菜单片段: $KMENU"
if grep -q '^config KSU_SUSFS$' "$KCONF"; then
  log "    Kconfig 已含 SUSFS 开关, 跳过"
else
  awk -v menu="$KMENU" '
    { lines[NR] = $0 }
    END {
      last = 0
      for (i = 1; i <= NR; i++) if (lines[i] ~ /^endmenu[[:space:]]*$/) last = i
      if (last == 0) { print "找不到 endmenu" > "/dev/stderr"; exit 1 }
      for (i = 1; i < last; i++) print lines[i]
      while ((getline l < menu) > 0) print l
      close(menu)
      for (i = last; i <= NR; i++) print lines[i]
    }
  ' "$KCONF" > "$KCONF.tmp" || die "Kconfig 菜单插入失败"
  mv "$KCONF.tmp" "$KCONF"
  grep -q '^config KSU_SUSFS$' "$KCONF" || die "$KCONF: SUSFS 菜单插入后仍未找到 config KSU_SUSFS"
  for o in KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_MOUNT KSU_SUSFS_SUS_KSTAT KSU_SUSFS_SPOOF_UNAME \
           KSU_SUSFS_ENABLE_LOG KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
           KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG KSU_SUSFS_OPEN_REDIRECT KSU_SUSFS_SUS_MAP; do
    grep -q "^config $o\$" "$KCONF" || die "$KCONF: 缺少 config $o"
  done
  log "    SUSFS Kconfig 菜单已插入 ($(wc -l < "$KCONF") 行)"
fi

# 结构校验: 防止把上游补丁里的 Kconfig 语法缺陷带进去。
# 实测坑: 上游 config KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG 少了 "help",
# 于是其 "- ..." 说明行被 kconfig 当成语句, 报
#     drivers/kernelsu/Kconfig:121: syntax error
#   120: unknown statement "-"
# 这类缺陷只能在编译早期的 olddefconfig 阶段才暴露, 代价是一整轮 CI,
# 所以这里用 node 先在本地产出阶段就拦下来。
node "$SCRIPT_DIR/check_kconfig.js" "$KMENU" || die "SUSFS Kconfig 菜单结构校验失败"

# 确认每个 defconfig 开关在 Kconfig 里都有定义 (防止被静默丢弃)
for o in $(grep -oE '^CONFIG_KSU_SUSFS[A-Z_]*' "$CFGFILE" | sed 's/^CONFIG_//'); do
  grep -q "^config $o\$" "$KCONF" || die "Kconfig 未定义 $o (defconfig 里写了但会被丢弃)"
done
log "    Kconfig 与 defconfig 开关一一对应 ✓"


# ------------------------------------------------------------- 6. 校验
log "6/6 最终校验"
[ -f fs/susfs.c ]                                    || die "fs/susfs.c 丢失"
[ -f include/linux/susfs.h ]                         || die "include/linux/susfs.h 丢失"
[ -f include/linux/susfs_def.h ]                     || die "include/linux/susfs_def.h 丢失"
grep -q '^obj-$(CONFIG_KSU_SUSFS) += susfs.o' fs/Makefile || die "fs/Makefile 未挂 susfs.o"
grep -q 'ksu_handle_setresuid(uid_t old_uid, uid_t new_uid, uid_t suid)' "$KS/hook/setuid_hook.c" || die "setresuid 第 3 参未生效"
grep -q 'DEFINE_STATIC_KEY_TRUE(ksu_su_compat_enabled)' "$KS/feature/sucompat.c"          || die "su_compat 静态键未生效"
grep -qE '^bool ksu_selinux_hide_running' "$KS/feature/selinux_hide.c"                   || die "selinux_hide 去 static 未生效"
grep -q 'susfs_adapter.o' "$KB"                                                    || die "适配层未挂入构建"
grep -q "ksu_handle_sys_reboot" "$KS/feature/susfs_adapter.c"                            || die "适配层缺少 reboot 分派"
if grep -q 'ksu_handle_execveat(' fs/exec.c; then die "fs/exec.c 仍有 sucompat 钩子残留"; fi
grep -q 'CONFIG_KSU_SUSFS=y' "$CFGFILE"                                            || die "配置未写入"

echo "    [susfs] ===== SUSFS 标准全套集成完成 ====="
echo "    [susfs] 内核实现 : fs/susfs.c"
echo "    [susfs] 适配层   : feature/susfs_adapter.c"
echo "    [susfs] 配置开关 : 10 项 (SUS_PATH/SUS_MOUNT/SUS_KSTAT/SPOOF_UNAME/"
echo "    [susfs]            ENABLE_LOG/HIDE_SYMBOLS/SPOOF_CMDLINE/OPEN_REDIRECT/SUS_MAP)"
