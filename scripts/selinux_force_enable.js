#!/usr/bin/env node
'use strict';
/*
 * 在 boot_completed 兜底再启用一次 SELinux 隐藏。
 *
 * 背景: FinaSU 的 ksu_selinux_hide_enable() 开头是
 *     if (!backup_sepolicy) { pr_err(...); return -EAGAIN; }
 * backup_sepolicy 由 apply_kernelsu_rules() 在"首次加载策略"时克隆产生。
 * 若策略/备份晚于 post-fs-data 就绪, 或管理器里那个开关(每台设备各自的
 * .feature_config id=4)没开, ksu_selinux_hide_running 就会一直是 false ->
 * SUSFS 在 security/selinux/{selinuxfs,hooks,avc}.c 里的钩子全部走原路径 ->
 * 春秋报「检测到可疑 SELinux Policy」。
 *
 * 本脚本做三件事 (幂等, 已打过会跳过):
 *   1. selinux_hide.c   : 新增 ksu_selinux_hide_force_enable()
 *   2. selinux_hide.h   : 声明该函数
 *   3. boot_event.c     : on_boot_completed() 里先 ksu_feature_apply_forced(),
 *                         再 force_enable(), 最后打印 enabled/running/backup 状态
 * 任一处没打上 -> 退出码非 0, 由 build.sh die。
 */
const fs = require('fs');
const path = require('path');

const MARK = 'KSU-SELINUX-FORCE-ENABLE';

function findKsuRoot() {
  const cands = ['KernelSU/kernel', 'drivers/kernelsu', 'kernel'];
  for (const c of cands) {
    if (fs.existsSync(path.join(c, 'feature/selinux_hide.c')) &&
        fs.existsSync(path.join(c, 'runtime/boot_event.c'))) return c;
  }
  return null;
}

const KS = findKsuRoot();
if (!KS) { console.error('[x] 找不到 KernelSU 源码根 (KernelSU/kernel | drivers/kernelsu)'); process.exit(1); }

let changed = 0;

// ---------- 1. selinux_hide.c ----------
const shPath = path.join(KS, 'feature/selinux_hide.c');
let sh = fs.readFileSync(shPath, 'utf8');
if (!sh.includes(MARK)) {
  const anchor = `static const struct ksu_feature_handler selinux_hide_handler = {`;
  if (!sh.includes(anchor)) { console.error('[x] selinux_hide.c 锚点缺失'); process.exit(1); }
  const inject = `#ifdef CONFIG_KSU_SUSFS
/* ${MARK}: boot_completed 兜底启用 (见 scripts/selinux_force_enable.js 注释) */
void ksu_selinux_hide_force_enable(void)
{
    selinux_hide_feature_set(1);
}
#endif

`;
  sh = sh.replace(anchor, inject + anchor);
  fs.writeFileSync(shPath, sh);
  console.log('    selinux_hide.c: 已插入 ksu_selinux_hide_force_enable()');
  changed++;
} else console.log('    selinux_hide.c: 已含标记, 跳过');

// ---------- 2. selinux_hide.h ----------
const hPath = path.join(KS, 'feature/selinux_hide.h');
let h = fs.readFileSync(hPath, 'utf8');
if (!h.includes('ksu_selinux_hide_force_enable')) {
  const anchor = `void ksu_selinux_hide_handle_post_fs_data();`;
  if (!h.includes(anchor)) { console.error('[x] selinux_hide.h 锚点缺失'); process.exit(1); }
  h = h.replace(anchor, anchor + `\nvoid ksu_selinux_hide_force_enable();`);
  fs.writeFileSync(hPath, h);
  console.log('    selinux_hide.h: 已声明 ksu_selinux_hide_force_enable()');
  changed++;
} else console.log('    selinux_hide.h: 已含声明, 跳过');

// ---------- 3. boot_event.c ----------
const bePath = path.join(KS, 'runtime/boot_event.c');
let be = fs.readFileSync(bePath, 'utf8');
if (!be.includes(MARK)) {
  const anchor = `    track_throne(true);
    ksu_selinux_hide_drop_backup_if_unused();`;
  if (!be.includes(anchor)) { console.error('[x] boot_event.c 锚点缺失'); process.exit(1); }
  const inject = `    track_throne(true);
#ifdef CONFIG_KSU_SUSFS
    {
        /* ${MARK}: 此时策略/备份一定已就绪; 管理器开关没开或 post-fs-data
         * 那次因 -EAGAIN 失败, 都在这里补上, 之后不再需要用户手动开开关。 */
        extern struct selinux_policy *backup_sepolicy;
        ksu_feature_apply_forced();
        ksu_selinux_hide_force_enable();
        pr_info("selinux_hide: boot_completed enabled=%d running=%d backup=%d\\n",
                ksu_selinux_hide_enabled, ksu_selinux_hide_running, backup_sepolicy != NULL);
    }
#endif
    ksu_selinux_hide_drop_backup_if_unused();`;
  be = be.replace(anchor, inject);
  fs.writeFileSync(bePath, be);
  console.log('    boot_event.c: 已在 on_boot_completed() 插入兜底启用');
  changed++;
} else console.log('    boot_event.c: 已含标记, 跳过');

// ---------- 校验 ----------
const ok = fs.readFileSync(shPath, 'utf8').includes('ksu_selinux_hide_force_enable') &&
           fs.readFileSync(hPath, 'utf8').includes('ksu_selinux_hide_force_enable') &&
           fs.readFileSync(bePath, 'utf8').includes(MARK);
if (!ok) { console.error('[x] 补丁校验失败'); process.exit(1); }
console.log(`    SELinux 兜底启用补丁就绪 (本次改动 ${changed} 处)`);
