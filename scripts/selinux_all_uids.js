#!/usr/bin/env node
'use strict';
/*
 * 去掉 SUSFS SELinux 隐藏钩子上的 "current_uid().val >= 10000" 限制。
 *
 * 原因 (Duck Detector 实测): 检测方用 android:zygotePreloadName 把探针放在
 * zygote 预加载类里跑, 那个 carrier 是 uid 0 (zygote 进程本体), 不是 app uid。
 * SUSFS 的钩子写的是:
 *     if (likely(current_uid().val >= 10000 && ksu_selinux_hide_running))
 *             return my_write_access(...);
 * 于是 uid 0 的探针直接走原函数, 拿到的是**真实策略**:
 *   - 能解析出 u:r:su:s0 / ksu_file / lsposed_file (KernelSU context materialized)
 *   - real status page 的 sequence=14 (KSU 注入/reload 次数) vs access 返回的 seqno=1
 *     -> "policyload/access seqno split"
 *   - KSU 的通配 allow (domain -> all) 让 system_server 的 execemem 查询变成 allowed
 * 全是这一条 uid 判断造成的。把条件去掉, 让所有 uid 在 running 时都用备份策略回答。
 */
const fs = require('fs');

const MARK = 'KSU-SELINUX-ALL-UIDS';
const FILES = ['security/selinux/selinuxfs.c'];  // 只改查询路径; setprocattr 保持原样(避免影响 init/zygote 的域切换)

let touched = 0, total = 0;
for (const f of FILES) {
  if (!fs.existsSync(f)) { console.error('[x] 缺少 ' + f); process.exit(1); }
  let s = fs.readFileSync(f, 'utf8');
  const before = (s.match(/ksu_selinux_hide_running/g) || []).length;
  const n = (s.match(/current_uid\(\)\.val >= 10000 &&\s*/g) || []).length;
  if (n > 0) {
    s = s.replace(/current_uid\(\)\.val >= 10000 &&\s*/g, '');
    if (!s.includes(MARK)) {
      // 只加一次注释, 放在第一个 extern ksu_selinux_hide_running 前面
      s = s.replace(/(extern bool ksu_selinux_hide_running)/,
        '/* ' + MARK + ': 对全部 uid 生效 (zygotePreload carrier 是 uid 0) */\n$1');
    }
    fs.writeFileSync(f, s);
    touched++;
    console.log(`    ${f}: 去掉 ${n} 处 uid 限制`);
  } else {
    console.log(`    ${f}: 无 uid 限制可去 (已处理过?)`);
  }
  const after = (fs.readFileSync(f, 'utf8').match(/ksu_selinux_hide_running/g) || []).length;
  if (after !== before) { console.error(`[x] ${f}: ksu_selinux_hide_running 计数变化 ${before} -> ${after}`); process.exit(1); }
  total += n;
}

// 校验: 两个文件里不应再出现该 uid 限制
for (const f of FILES) {
  if (/current_uid\(\)\.val >= 10000/.test(fs.readFileSync(f, 'utf8'))) {
    console.error('[x] ' + f + ' 仍残留 current_uid().val >= 10000'); process.exit(1);
  }
}
console.log(`    SELinux 隐藏已对全部 uid 生效 (本次改动 ${touched} 个文件 / ${total} 处)`);
