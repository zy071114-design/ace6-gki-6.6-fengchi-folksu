#!/usr/bin/env node
// 修正 FinaSU(KernelSU) 音量键安全模式的误触发。
//
// 原始逻辑(上游 FinaSU v1.0.4):
//     if (val) count++;                 // 1=按下, 2=自动重复 -> 都算一次, 阈值 3
// 问题: 按住音量下约 0.3 秒产生的自动重复就能凑够 3 次 -> "没按"也会进安全模式。
//
// 修正后:
//     if (val == 1 && ksu_safe_mode_jiffies &&
//         time_before(jiffies, ksu_safe_mode_jiffies + HZ * 60)) count++;
//   - 只统计首次按下(val==1), 自动重复(val==2)不计
//   - 只在内核初始化后 60 秒内采样(jiffies 只读变量, kprobe 上下文安全)
//   - 两个条件同时满足才计数 -> 日常调音量不再误触发
//
// 用法: node ksu_safe_mode_fixup.js <KSU源码根>
'use strict';
const fs = require('fs'), path = require('path');

const root = process.argv[2];
if (!root) { console.error('用法: node ksu_safe_mode_fixup.js <KSU源码根>'); process.exit(1); }

const target = path.join(root, 'kernel/runtime/ksud_integration.c');
if (!fs.existsSync(target)) { console.error('[x] 找不到 ' + target); process.exit(1); }

let src = fs.readFileSync(target, 'utf8');
const MARK = 'ksu_safe_mode_jiffies';

if (src.includes(MARK)) {
    console.log('[=] 音量键安全模式修正已在, 跳过');
    process.exit(0);
}

function must(cond, msg) { if (!cond) { console.error('[x] ' + msg); process.exit(1); } }

// 1) jiffies 头文件
if (!src.includes('#include <linux/jiffies.h>')) {
    const anchorInc = src.includes('#include <linux/kprobes.h>')
        ? '#include <linux/kprobes.h>'
        : '#include <linux/printk.h>';
    must(src.includes(anchorInc), '找不到 include 锚点');
    src = src.replace(anchorInc, anchorInc + '\n#include <linux/jiffies.h>');
}

// 2) 记录采样窗口起点的静态变量
const varAnchor = 'static unsigned int volumedown_pressed_count = 0;';
must(src.includes(varAnchor), '找不到 volumedown_pressed_count 定义');
src = src.replace(varAnchor,
    'static unsigned long ksu_safe_mode_jiffies;  /* 采样窗口起点(init 时赋值) */\n' + varAnchor);

// 3) init 里记录起点
const initAnchor = '    INIT_WORK(&stop_input_hook_work, do_stop_input_hook);';
must(src.includes(initAnchor), '找不到 INIT_WORK 锚点');
src = src.replace(initAnchor,
    initAnchor + '\n    ksu_safe_mode_jiffies = jiffies;');

// 4) 计数条件(兼容原始 if (val) 与旧修正 if (val == 1))
const ai = src.indexOf('pr_info("KEY_VOLUMEDOWN val: %d\\n", val);');
must(ai >= 0, '找不到 KEY_VOLUMEDOWN 打印锚点');
const tail = src.slice(ai);
const oldCond = /(\r?\n[ \t]*)if \(val(?: == 1)?\) \{/;
const m = oldCond.exec(tail);
must(m !== null, '锚点之后找不到 if (val...) 条件');

const indent = m[1];
const newCond =
    indent + 'if (val == 1 && ksu_safe_mode_jiffies &&' +
    indent + '    time_before(jiffies, ksu_safe_mode_jiffies + HZ * 60)) {' +
    indent + '    /* 只计首次按下(val==1), 且仅内核初始化后 60 秒内采样:\n' +
    indent + '     * 自动重复(val==2)与日常调音量都不再累计, 避免误进安全模式 */';

const replaced = tail.replace(oldCond, newCond);
must(replaced !== tail && replaced.includes(MARK), '替换未生效');
src = src.slice(0, ai) + replaced;

must(src.includes('ksu_safe_mode_jiffies = jiffies;'), 'init 赋值未写入');
must(src.includes('#include <linux/jiffies.h>'), 'jiffies 头文件未写入');

fs.writeFileSync(target, src);
console.log('[+] 已修正: 音量键安全模式 = 只计首次按下(val==1) 且仅 init 后 60 秒内');
