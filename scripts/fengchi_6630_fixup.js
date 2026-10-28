#!/usr/bin/env node
// 把风驰补丁(基于 6.6.118)在 6.6.30 基线上打不上的 8 处, 用精确替换修正。
// 用法: node fengchi_6630_fixup.js <内核源码根>
'use strict';
const fs=require('fs'), path=require('path');
const root=process.argv[2]||'.';
function edit(rel, pairs){
  const p=path.join(root,rel);
  if(!fs.existsSync(p)){ console.log('    [skip] 缺文件 '+rel); return; }
  let s=fs.readFileSync(p,'utf8');
  for(const [name,oldT,newT] of pairs){
    const n=s.split(oldT).length-1;
    if(n===0){ console.log('    [skip] '+rel+' :: '+name+' (未匹配)'); continue; }
    if(n>1){ console.log('    [!] '+rel+' :: '+name+' 匹配 '+n+' 次, 只替换第一处'); }
    s=s.replace(oldT,newT);
    console.log('    [ok]   '+rel+' :: '+name);
  }
  fs.writeFileSync(p,s);
}

// ---- F1: include/linux/sched.h KABI 槽位(6.6.30 没有 dmabuf_info) ----
edit('include/linux/sched.h', [['KABI-slim', [
'#ifdef CONFIG_SLIM_SCHED',
'	ANDROID_KABI_USE(1, unsigned long sched_prop);',
'	ANDROID_KABI_USE(2, struct sched_ext_entity *scx);',
'#else',
'	ANDROID_KABI_RESERVE(1);',
'	ANDROID_KABI_RESERVE(2);',
'#endif',
'	ANDROID_KABI_RESERVE(3);'].join('\n'), [
'	ANDROID_KABI_RESERVE(1);',
'	ANDROID_KABI_RESERVE(2);',
'	ANDROID_KABI_RESERVE(3);'].join('\n')]]);

// ---- F2: kernel/sched/core.c fork 钩子 ----
edit('kernel/sched/core.c', [['fork-hooks', [
'	raw_spin_unlock_irqrestore(&p->pi_lock, flags);',
'',
'	return scx_fork(p);',
'}',
'',
'void sched_cancel_fork(struct task_struct *p)',
'{',
'	scx_cancel_fork(p);',
'}',
'',
'void sched_post_fork(struct task_struct *p)',
'{',
'	uclamp_post_fork(p);',
'	scx_post_fork(p);',
'}'].join('\n'), [
'	raw_spin_unlock_irqrestore(&p->pi_lock, flags);',
'#ifdef CONFIG_HMBIRD_SCHED',
'	hmbird_fork(p);',
'#endif',
'}',
'',
'void sched_cancel_fork(struct task_struct *p)',
'{',
'	/* 6.6.30 的 fork.c 仍会调用, 保留空实现 */',
'}',
'',
'void sched_post_fork(struct task_struct *p)',
'{',
'	uclamp_post_fork(p);',
'',
'#ifdef CONFIG_HMBIRD_SCHED',
'	hmbird_post_fork(p);',
'#endif',
'}'].join('\n')],

// ---- F3: scheduler_tick ----
['tick', [
'	scx_notify_sched_tick();',
'	perf_event_task_tick();'].join('\n'), [
'#ifdef CONFIG_HMBIRD_SCHED',
'	hmbird_notify_sched_tick();',
'#endif',
'	perf_event_task_tick();'].join('\n')],
['tick-balance', [
'	if (!scx_switched_all()) {',
'		rq->idle_balance = idle_cpu(cpu);',
'		trigger_load_balance(rq);',
'	}'].join('\n'), [
'#ifdef CONFIG_HMBIRD_SCHED',
'	if (!hmbird_enabled()) {',
'#endif',
'		rq->idle_balance = idle_cpu(cpu);',
'		trigger_load_balance(rq);',
'#ifdef CONFIG_HMBIRD_SCHED',
'	}',
'#endif'].join('\n')],
['tick-tail', [
'	trace_android_vh_scheduler_tick(rq);',
'}'].join('\n'), [
'	trace_android_vh_scheduler_tick(rq);',
'#ifdef CONFIG_HMBIRD_SCHED',
'	scheduler_tick_handler(NULL, NULL);',
'#endif',
'}'].join('\n')],

// ---- F4: __sched_setscheduler 的 scx_check_setscheduler ----
['check-setscheduler', [
'	retval = scx_check_setscheduler(p, policy);',
'	if (retval)',
'		goto unlock;'].join('\n'), [
'#ifdef CONFIG_HMBIRD_SCHED',
'	retval = hmbird_check_setscheduler(p, policy);',
'	if (retval)',
'		goto unlock;',
'#endif'].join('\n')],

// ---- F5: SCHED_CHANGE_BLOCK 展开 ----
['change-block', [
'	SCHED_CHANGE_BLOCK(rq, p, queue_flags) {',
'		prev_class = p->sched_class;',
'',
'		if (!(attr->sched_flags & SCHED_FLAG_KEEP_PARAMS)) {',
'			__setscheduler_params(p, attr);',
'			__setscheduler_prio(p, newprio);',
'			trace_android_rvh_setscheduler(p);',
'		}',
'		__setscheduler_uclamp(p, attr);',
'',
'		/*',
'		 * We enqueue to tail when the priority of a task is',
'		 * increased (user space view).',
'		 */',
'		if (oldprio < p->prio)',
'			queue_flags |= ENQUEUE_HEAD;',
'',
'	}'].join('\n'),
['queued = task_on_rq_queued(p);',
'	running = task_current(rq, p);',
'	if (queued)',
'		dequeue_task(rq, p, queue_flags);',
'	if (running)',
'		put_prev_task(rq, p);',
'',
'	prev_class = p->sched_class;',
'',
'	if (!(attr->sched_flags & SCHED_FLAG_KEEP_PARAMS)) {',
'		__setscheduler_params(p, attr);',
'		__setscheduler_prio(p, newprio);',
'		trace_android_rvh_setscheduler(p);',
'	}',
'	__setscheduler_uclamp(p, attr);',
'',
'	if (queued) {',
'		/*',
'		 * We enqueue to tail when the priority of a task is',
'		 * increased (user space view).',
'		 */',
'		if (oldprio < p->prio)',
'			queue_flags |= ENQUEUE_HEAD;',
'',
'	}'].join('\n')],

// ---- F6/F7: case SCHED_EXT (两处, 全部替换) ----
['case-ext', '	case SCHED_EXT:', '	case SCHED_HMBIRD:'],

// ---- F8: cgroup deadline 块 (6.6.30 的 cpu_cgroup_attach 无花括号) ----
['cgroup-attach', [
'	cgroup_taskset_for_each(task, css, tset)',
'		sched_move_task(task);'].join('\n'), [
'	cgroup_taskset_for_each(task, css, tset) {',
'#ifdef CONFIG_HMBIRD_SCHED',
'		hmbird_change_rt_sched_prop(css, task, task->prio);',
'#endif',
'		sched_move_task(task);',
'	}'].join('\n')]
]);

// case SCHED_EXT 两处需要全替换
(function(){
  const p=path.join(root,'kernel/sched/core.c');
  let s=fs.readFileSync(p,'utf8');
  const n=s.split('	case SCHED_EXT:').length-1;
  if(n>0){ s=s.split('	case SCHED_EXT:').join('	case SCHED_HMBIRD:'); fs.writeFileSync(p,s); console.log('    [ok]   core.c :: case-ext 替换 '+n+' 处'); }
})();
console.log('    风驰 6.6.30 修正脚本执行完成');
