# Ace6 GKI 6.6 内核构建工程（风驰 + FolkSU）

面向 **一加 Ace 6（PLQ110 / 代号 `ossi` / SM8750 "sun" / Android 16 ColorOS 16）** 的
GKI 6.6 内核自动构建工程。云编译（GitHub Actions），本机无需 Linux。

> **出品前必读：[出品要求（Release Gate）](#出品要求release-gate必须全部满足)。**
> 其中「检测到可疑 SELinux / Duck Detector 的 SELinux 项」是**硬性验收项**，不满足不许发布。

## 产出的内核是什么

| 项目 | 取值 | 说明 |
|---|---|---|
| 源码基线 | `OnePlusOSS/android_kernel_common_oneplus_sm8750`<br>分支 `oneplus/sm8750_b_16.0.0_ace_6` | 一加官方开源内核源码（提交 `65b954a`，PLQ110_16.0.9.401 CN01） |
| 内核版本 | `6.6.118-android15-8-o-4k` | 与出厂 `vendor_dlkm` 里模块的 `vermagic` **逐字一致**，保证厂商模块能加载 |
| 风驰内核 | OPlus **HMBIRD** 调度类（`CONFIG_HMBIRD_SCHED=y`） | 由 `patches/fengchi.patch` 移植；官方 common 树只有 `include/linux/sched/hmbird.h`，缺 `kernel/sched/hmbird/` 实现 |
| Root | **FolkSU**（KernelSU fork）内核侧代码，`KERNEL_SU_UAPI_VERSION = 5` | 与 `FolkSU_v0.1.0-beta2_32783-release.apk` 完全匹配 |
| 管理器信任 | 证书 `size=0x2cc`、`sha256=2d89b50a…8458` | 从你的 APK 实测提取，编进内核后该 APK 被识别为**受信任管理器** |
| 刷机包 | AnyKernel3 zip（只含 `Image`） | `BLOCK=boot`、A/B 双槽、有独立 `init_boot` 时只换内核不动 ramdisk |

## 目录结构

```
.github/workflows/build.yml   GitHub Actions 构建流程
scripts/build.sh              主编译脚本（本地/Linux 也能直接跑）
scripts/make_ak3.sh           打包 AnyKernel3 刷机包
scripts/apk_sign.py           从 APK 提取 KernelSU 侧管理器签名 (size, sha256)
ak3/anykernel.sh              Ace 6 专用 AnyKernel3 刷机脚本
patches/fengchi-ace6.patch    风驰内核补丁（已重基到 ace_6，0 reject）
patches/fengchi.patch         上游原始风驰补丁（保留备查）
```

### 风驰补丁是怎么来的

上游 `fengchi.patch` 的基线是 cctv18 fork 的 **一加13** 分支，直接打到官方 **ace_6** 分支上有
**19 个 hunk 冲突**（涉及 6 个文件，都在 ACK LTS 频繁改动的区域）。`fengchi-ace6.patch` 是重基
结果，19 处冲突逐条解决并验证：

| 文件 | 冲突 hunk | 处理方式 |
|---|---|---|
| `include/linux/cpufreq.h` | 1 | **丢弃** —— ace_6 里 `store/show_scaling_governor` 声明已存在 |
| `include/linux/sched.h` | 2 | 去掉 `sched_prop`/`scx` KABI 槽；**保留 `task_dma_buf_info` 在槽 3**（ace_6 新增，出厂厂商模块按此偏移编译） |
| `kernel/fork.c` | 2 | `hmbird_free()` 替换；标签合并时**保留 ace_6 新增的 `bad_fork_cleanup_dmabuf:`** |
| `kernel/time/tick-sched.c` | 1 | 插入 `android_vh_tick_nohz_idle_stop_tick_handler()` 调用 |
| `kernel/sched/debug.c` | 1 | `ext.enabled` → `hmbird.enabled` + 2 个新 `__PS` |
| `kernel/sched/core.c` | 12 | `sched_move_task` 一处**丢弃**（ace_6 已是展开版）；其余为 `hmbird_tasks_lock`、`__setscheduler_prio`、cgroup hmbird deadline 等逐条移植 |

生成后经校验：`git apply --reject` → **0 reject / 0 failed hunk**，所有文件 `#ifdef/#endif` 配平。


## 怎么用（云编译）

1. 打开仓库 → **Actions** → 左侧 **Build Ace6 GKI 6.6 (fengchi + FolkSU)** → **Run workflow**。
2. 保持默认即可：

   | 输入 | 默认 | 含义 |
   |---|---|---|
   | `apply_fengchi` | ✅ true | 移植风驰（HMBIRD 调度类）。关掉就退回 AOSP sched_ext |
   | `apply_susfs` | ⬜ false | SuSFS 隐藏补丁。**默认关闭**：FolkSU 的 `kernel/Kconfig` 里没有任何 `SUSFS` 项，且其目录结构已重构，`susfs4ksu` 的联动补丁大概率冲突 |
   | `localversion` | `-android15-8-o-4k` | 内核版本后缀，**别乱改**，改了会和厂商模块 vermagic 不匹配 |
   | `ksu_expected_size` / `ksu_expected_hash` | 已填好 | 受信任管理器证书。换 APK 时用 `scripts/apk_sign.py` 重新提取 |
   | `build_target` | `Image` | 只编内核镜像，最快；改 `all` 会连模块一起编 |

3. 等构建完成（首次约 30–60 分钟），在 run 页面底部下载 **`Ace6-GKI-6.6-fengchi-FolkSU-<run>`** 工件，里面的 zip 即可刷入。

## 怎么用（本地 Linux）

```bash
INSTALL_DEPS=1 bash scripts/build.sh          # 自动装 clang-18 等依赖
bash scripts/make_ak3.sh work/out/Image dist  # 打成刷机包
```

## 换一个 FolkSU 管理器 APK

```bash
python3 scripts/apk_sign.py /path/to/NewManager.apk
# 把输出的 size / sha256 填给 workflow 的 ksu_expected_size / ksu_expected_hash
```

## 刷入须知

- 刷前**务必备份**官方 `boot.img`（用 `fastboot getvar current-slot` 确认槽位）。
- 本包只替换 `boot` 分区里的 `Image`，**不碰 ramdisk / init_boot / vbmeta**。
- 该机有独立 `init_boot` 分区，AnyKernel3 会自动走 `split_boot`/`flash_boot` 分支。
- 刷完开机后用 **FolkSU 管理器**确认 Root；管理器里应显示版本 `32783-5`。
- 验证风驰是否生效：`adb shell ls /proc/hmbird_sched/`（需要设备 DTBO 里有
  `/soc/oplus,hmbird/version_type = "HMBIRD_OGKI"`，一加 Ace 6 官方固件自带）。

## 两个已知的技术要点

1. **风驰补丁会删掉 AOSP 的 sched_ext**。`fengchi.patch` 是 OPlus 在自家树上的分支 diff：
   删除 `kernel/sched/ext.c`、`include/linux/sched/ext.h`、`tools/sched_ext/**`，
   把 `SCHED_EXT`(7) 改名为 `SCHED_HMBIRD`(7)、`CONFIG_SCHED_CLASS_EXT` 改为 `CONFIG_HMBIRD_SCHED`。
   这**就是一加官方的做法**（官方树自带 `include/linux/sched/hmbird.h`），所以"保留风驰"与
   "保留 sched_ext" 二者不可兼得。
2. **SuSFS 默认不开**。要做隐藏请先在 FolkSU 树里确认 SUSFS 接入点，或改用支持 SuSFS 的 KSU 分支。

---

## 出品要求（Release Gate，必须全部满足）

发布任何一个包之前，下面每一条都要成立。前 5 条由构建流程**自动拦截**（不满足直接构建失败，
不会产出 zip），后 5 条是**上机人工验收**，不通过不许发版。

### 一、构建侧（自动强制）

| # | 要求 | 落在哪里 |
|---|---|---|
| 1 | `SUSFS=1` 时 `security/selinux/{avc,hooks,selinuxfs}.c` 三处 SUSFS 改动**必须保留**，且命中 7 个钩子特征：`avc.c:{susfs_is_avc_log_spoofing_enabled,bypass_orig_flow}`、`hooks.c:{handle_selinux_setprocattr,my_setprocattr}`、`selinuxfs.c:{handle_sel_write_access,handle_sel_write_context,ksu_selinux_hide_running,fake_status}` —— 不满足 `die`，不出包 | `scripts/apply_susfs.sh` |
| 2 | 出包前按源码 + `System.map` 复核 4 个符号：`handle_sel_write_access`、`handle_sel_write_context`、`handle_selinux_setprocattr`、`my_write_access` —— 缺一个 `die` | `scripts/build.sh` |
| 3 | `boot_completed` 兜底启用 SELinux 隐藏（不依赖管理器开关、不依赖 `-EAGAIN` 之后的碰运气重试） | `scripts/selinux_force_enable.js` |
| 4 | 查询路径去掉 `current_uid().val >= 10000`（`selinuxfs.c` 三处；`hooks.c` 的 `setprocattr` 保留，避免影响 init/zygote 域切换） | `scripts/selinux_all_uids.js` |
| 5 | `build-info.txt` 必须 `SUSFS=1` → `SELINUX_HIDE=1`，打包前再校验一次 | `scripts/make_ak3.sh` |
| 6 | **扫盘（unicode 路径绕过）修复**：`fs/unicode/mkutf8data.c` 必须已删掉 `ignore_init()` 且 `utf8data.c_shipped` 已重生成，`build-info.txt` 必须 `UNICODE_BYPASS_FIX=1`。构建时无条件执行并 `die` 断言，打包前再校验一次 | `scripts/build.sh` + `scripts/make_ak3.sh` |

> **为什么第 4 条是硬性的**：Duck Detector 用 `android:zygotePreloadName` 把探针放进
> **zygote 进程（uid 0）**里跑。保留 `uid >= 10000` 判断时它直接走原函数，读到的是真实策略，
> 于是报 `Enforcing with KSU context materialized`、`policyload/access seqno split`、
> `system_server execemem as allowed` —— 这与「隐藏 SELinux 修改」开关开没开**完全无关**，
> 开关开了也没用。

### 二、上机验收（人工，逐条留证）

1. **版本串**：`uname -r` 与目标一致。例：Ace6 6.6.89 =
   `6.6.89-android15-8-g11d7ebe61a81-abogki537459655-4k`；一加 13 =
   `6.6.89-android15-8-gf4dc45704e54-abogki446052083-4k`。
2. **扫盘修复**：`build-info.txt` 里 `UNICODE_BYPASS_FIX=1`，且 `fs/unicode/utf8data.c_shipped` 已重生成（`a\u200Bb` 这类名字归一化后不得等价于 `ab`）。
3. **内核侧状态**：`su -c dmesg | grep -i selinux_hide` 必须出现
   `selinux_hide: boot_completed enabled=1 running=1 backup=1`。
3. **Duck Detector**：SELinux 项**不得为 Danger**；详情里不得出现
   `KSU context materialized`、`policyload/access seqno split`、
   `system_server execemem ... allowed`。
4. **春秋检测器**：不得出现「检测到可疑 SELinux Policy」/「检测到可疑 SELinux」，
   以及与之关联的「检测到 ROOT 权限」条目。
5. **失败即止**：以上任一条不过，该包不许进发布目录，也不许改名当新版本发。

### 二·补充：Duck 的「实验性时序」不算门禁

Duck Detector 的 `App Zygote attr/current timing (experimental)` 这一项会判 Positive/Negative，
但它是**微架构级噪声**，不是策略泄漏：

- 实测同一套内核配置：Ace 6（6.6.118，CPU6）为 **Negative**（−52 ns）；Ace 5 Pro / 一加 13（6.6.89，CPU1/CPU2）为 **Positive**（+103~104 ns）。
- **原厂 boot** 在同一台 Ace 5 Pro 上同样跑出 **Positive（+104 ns，A=729/B=625）** —— 说明该偏差与我们的内核无关。
- 报告原文也写着：`Stock kernels also take different paths for A and B, and CPU/load can change the sign`、`Timing direction is supporting information, not proof of hiding`。

判定规则：
1. 只要 `Context validity oracle` 是 `00`（KSU 上下文全拒）、`DirtySepolicy` 无命中、`system_server execmem / ksu_file / lsposed_file` 全 `Denied`，就**视为内容干净，可以发布**；
2. 若该时序项与原厂 boot 结论一致（同为 Positive 或同为 Negative），一律按**设备基线噪声**处理，不纳入门禁、不回炉；
3. 只有当同一台机器上「原厂 Negative、我们内核 Positive」时，才需要继续查内核路径（曾用过的修法：让 uid≥10000 的 `/proc/self/attr/current` 写入走原厂 `selinux_setprocattr`，见 `scripts/selinux_setprocattr_stock.js`）。

### 三、事故备忘（防止回退到旧行为）

| 症状 | 真实原因 | 修法 |
|---|---|---|
| 春秋「检测到可疑 SELinux Policy」 | 早期脚本把 SUSFS 的 SELinux 三处改动 strip 掉了；而 FinaSU 在 `CONFIG_KSU_SUSFS` 下 `ksu_selinux_hide_enable()` 直接 `return 0` → 两边都不装钩子 | 保留三处改动（门禁 1） |
| 钩子在但 `running=0` | `backup_sepolicy` 晚于 feature 应用就绪 → `-EAGAIN`，之后没人重试 | `boot_completed` 兜底启用（门禁 3） |
| Duck Detector「KSU context materialized」 | 探针跑在 uid 0 的 zygote carrier 上，被 `uid >= 10000` 判断绕过 | 去掉查询路径 uid 限制（门禁 4） |
