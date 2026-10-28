#!/usr/bin/env node
'use strict';
/*
 * 归一化 fake status 页 (KSU-SELINUX-STATUS-NORMALIZE)。
 *
 * FinaSU 的 initialize_fake_status() 是把内核当前的 selinux_kernel_status 页
 * memcpy 一份当假页。开机 early 阶段克隆到的是 sequence=0 / policyload=0,
 * 而 my_write_access() 对 /sys/fs/selinux/access 固定回 avd.seqno=1。
 * Duck Detector 正是拿 status.policyload 和 access 返回的 seqno 对比,
 * 得到 "policyload/access seqno split"。
 *
 * 这里在克隆完成后统一改写成「只加载过一次策略」的原厂样子:
 *   sequence=1, policyload=1, enforcing=1, deny_unknown=1
 * 和 access 的 seqno=1 对齐, 也和 enforce/deny_unknown 的读取值一致。
 */
const fs = require('fs');
const path = require('path');
const MARK = 'KSU-SELINUX-STATUS-NORMALIZE';

function findKsuRoot() {
  for (const c of ['KernelSU/kernel', 'drivers/kernelsu', 'kernel']) {
    if (fs.existsSync(path.join(c, 'feature/selinux_hide.c'))) return c;
  }
  return null;
}
const KS = findKsuRoot();
if (!KS) { console.error('[x] 找不到 KernelSU 源码根'); process.exit(1); }
const f = path.join(KS, 'feature/selinux_hide.c');
let s = fs.readFileSync(f, 'utf8');
if (!s.includes(MARK)) {
  const anchor = `    fake_status = new_page;`;
  if (!s.includes(anchor)) { console.error('[x] selinux_hide.c 锚点缺失'); process.exit(1); }
  const inject = `    /* ${MARK}: 与 my_write_access 返回的 seqno=1 对齐, 消除 policyload/access seqno split */
    new_status->sequence = 1;
    new_status->policyload = 1;
    new_status->enforcing = 1;
    new_status->deny_unknown = 1;

    fake_status = new_page;`;
  s = s.replace(anchor, inject);
  fs.writeFileSync(f, s);
  console.log('    selinux_hide.c: 已归一化 fake status 页 (1/1/1/1)');
} else {
  console.log('    selinux_hide.c: 已归一化, 跳过');
}
const chk = fs.readFileSync(f, 'utf8');
if (!chk.includes(MARK) || !/new_status->policyload = 1;/.test(chk)) {
  console.error('[x] 归一化校验失败'); process.exit(1);
}
console.log('    fake status 归一化补丁就绪');
