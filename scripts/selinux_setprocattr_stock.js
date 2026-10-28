#!/usr/bin/env node
'use strict';
/*
 * 让普通 app（uid>=10000）写 /proc/self/attr/current 时**走原厂 selinux_setprocattr**。
 *
 * 背景：Duck Detector 的 `App Zygote attr/current timing (experimental)` 用 app_zygote
 * 载体做 A/B 计时（A=非法 type、B=同长度换行前缀，两者都必须 EINVAL），判 Positive
 * 就给 SELinux 标红。FinaSU 的 my_setprocattr 用 backup_sepolicy 解析，和原厂用 live
 * 策略解析的耗时不同，A 路径就多出几十~一百多纳秒（实测 A−B ≈ +103ns）。
 *
 * 修法：uid>=10000 时直接调用原厂 selinux_setprocattr（kallsyms 取地址），
 * 使 app 侧时序与原厂一致；su（uid 0）仍走 FinaSU 的隐藏策略切换。
 * 注入点在变量声明之后（`mysid = current_sid();` 之前），避免 declaration-after-statement。
 */
const fs = require('fs');
const path = require('path');

const MARK = 'KSU-SETPROCATTR-STOCK';
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
if (s.includes(MARK)) { console.log('    已含标记, 跳过'); process.exit(0); }

if (!s.includes('infra/symbol_resolver.h')) {
  s = s.replace('#include "selinux_hide.h"', '#include "selinux_hide.h"\n#include "infra/symbol_resolver.h"');
  if (!s.includes('infra/symbol_resolver.h')) { console.error('[x] 无法加入 symbol_resolver include'); process.exit(2); }
}

const decl = s.indexOf('my_setprocattr(const char *name, void *value, size_t size)');
if (decl < 0) { console.error('[x] 找不到 my_setprocattr 声明'); process.exit(3); }

// 找变量声明之后的第一个语句，作为注入点（避免 declaration-after-statement）
const bodyAnchor = s.indexOf('\n    mysid = current_sid();', decl);
if (bodyAnchor < 0) { console.error('[x] 找不到注入点'); process.exit(4); }

const inject = `#ifdef CONFIG_KSU_SUSFS
    /* ${MARK}: 普通 app 的 attr/current 写入交回原厂实现, 消除 backup/live 策略解析的耗时差 */
    if (current_uid().val >= 10000) {
        static int (*orig_setprocattr)(const char *name, void *value, size_t size);
        if (!orig_setprocattr)
            orig_setprocattr = (void *)find_kernel_symbol_exact("selinux_setprocattr");
        if (orig_setprocattr)
            return orig_setprocattr(name, value, size);
    }
#endif
`;
s = s.slice(0, bodyAnchor + 1) + inject + s.slice(bodyAnchor + 1);
fs.writeFileSync(f, s);

const chk = fs.readFileSync(f, 'utf8');
if (!chk.includes(MARK) || !/find_kernel_symbol_exact\("selinux_setprocattr"\)/.test(chk)) {
  console.error('[x] 注入校验失败'); process.exit(5);
}
console.log('    selinux_hide.c: app attr/current 写入已改回原厂 setprocattr');
