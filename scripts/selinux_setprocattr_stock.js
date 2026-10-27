#!/usr/bin/env node
'use strict';
/*
 * 让普通 app（uid>=10000）写 /proc/self/attr/current 时**走原厂 selinux_setprocattr**。
 *
 * 背景：Duck Detector 的 `App Zygote attr/current timing (experimental)` 用 app_zygote
 * 载体做 A/B 计时（A=非法 type、B=同长度换行前缀，两者都必须 EINVAL），判 Positive
 * 就给 SELinux 标红。FinaSU 的 my_setprocattr 用 backup_sepolicy 解析，和原厂用 live
 * 策略解析的耗时不同，于是 A 路径多出几十~一百多纳秒（实测 A−B ≈ +103ns）。
 *
 * 修法：uid>=10000 时直接调用原厂 selinux_setprocattr（kallsyms 取地址），
 * 使 app 侧时序与原厂一致；su 进程（uid 0）仍走 FinaSU 的隐藏策略切换逻辑。
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

// 需要 symbol resolver
if (!s.includes('infra/symbol_resolver.h')) {
  s = s.replace('#include "selinux_hide.h"', '#include "selinux_hide.h"\n#include "infra/symbol_resolver.h"');
  if (!s.includes('infra/symbol_resolver.h')) { console.error('[x] 无法加入 symbol_resolver include'); process.exit(2); }
}

// 找到 my_setprocattr 的定义开头
const re = /((?:^|\n)(?:static\s+)?int\s+(?:__nocfi\s+)?my_setprocattr\(const char \*name, void \*value, size_t size\)\s*\{)/;
const m = s.match(re);
if (!m) { console.error('[x] 找不到 my_setprocattr 定义'); process.exit(3); }

const inject = `\n#ifdef CONFIG_KSU_SUSFS
    /* ${MARK}: 普通 app 的 attr/current 写入交回原厂实现, 消除 backup/live 策略解析的耗时差 */
    if (current_uid().val >= 10000) {
        static int (*orig_setprocattr)(const char *name, void *value, size_t size);
        if (!orig_setprocattr)
            orig_setprocattr = (void *)find_kernel_symbol_exact("selinux_setprocattr");
        if (orig_setprocattr)
            return orig_setprocattr(name, value, size);
    }
#endif\n`;

s = s.replace(re, m[1] + inject);
fs.writeFileSync(f, s);

const chk = fs.readFileSync(f, 'utf8');
if (!chk.includes(MARK) || !/find_kernel_symbol_exact\("selinux_setprocattr"\)/.test(chk)) {
  console.error('[x] 注入校验失败'); process.exit(4);
}
console.log('    selinux_hide.c: app attr/current 写入已改回原厂 setprocattr');
