#!/bin/bash
# =============================================================================
# AnyKernel3 刷机脚本 —— 一加 Ace 6 (PLQ110 / ossi / SM8750 "sun")
# 内核: GKI 6.6 (官方 ace_6 源码) + 风驰 HMBIRD 调度类 + FinaSU(KernelSU, UAPI 6)
#
# 分区布局要点:
#   * A/B 双槽 (IS_SLOT_DEVICE=1)
#   * 内核 Image 在 boot 分区, 一阶段 ramdisk 在独立的 init_boot 分区
#     -> 有 init_boot 时只做 split_boot/flash_boot, 绝不动 ramdisk, 不碰 vbmeta
#   * do.modules=0: 厂商模块留在 vendor_dlkm, 靠内核 vermagic 对齐后加载
# =============================================================================

### AnyKernel setup
# global properties
properties() { '
kernel.string=@DEV_NAME@
do.devicecheck=0
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=
device.name2=
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### AnyKernel install
## boot shell variables
BLOCK=boot
IS_SLOT_DEVICE=1
RAMDISK_COMPRESSION=auto
PATCH_VBMETA_FLAG=0
NO_MAGISK_CHECK=1
NO_VBMETA_PARTITION_PATCH=1

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh

ui_print " "
ui_print "*******************************"
ui_print " @DEV_NAME@ + fengchi + FinaSU"
ui_print "*******************************"
ui_print " "
ui_print "!! 仅限 @DEV_IDS@ !!"
ui_print "!! 其他机型刷入必重启 !!"
ui_print "!! (电源/温控/显示驱动不匹配) !!"
ui_print " "
ui_print "[i] Device : @DEV_NAME@"
ui_print "[i] Kernel : GKI 6.6 official source + fengchi (HMBIRD)"
ui_print "[i] Root   : FinaSU (KernelSU, UAPI=6)"
ui_print " "
ui_print "[i] 机型: @DEV_NAME@ / 内核: 风驰 HMBIRD / Root: FinaSU"
ui_print " "

# 规避部分机型文件系统 I/O 延迟导致的二进制执行异常 (cctv18 同款加固)
sync
sleep 0.5
chmod -R 755 $AKHOME/tools

# boot install
# 该机有独立 init_boot 分区: 内核在 boot, ramdisk 在 init_boot,
# 因此只要存在 init_boot 就只替换内核, 绝不重打 ramdisk。
if [ -L "/dev/block/bootdevice/by-name/init_boot_a" ] || [ -L "/dev/block/by-name/init_boot_a" ]; then
    ui_print "[i] 检测到独立 init_boot, 仅替换内核 Image, 保留 ramdisk"
    split_boot
    flash_boot
else
    ui_print "[i] 未检测到 init_boot, 走完整流程"
    split_boot
    if [ -f "split_img/ramdisk.cpio" ]; then
        unpack_ramdisk
        write_boot
    else
        flash_boot
    fi
fi
## end boot install

ui_print " "
ui_print "[OK] 刷入完成, 重启后用 FinaSU 管理器确认 Root (应显示 32960-6)"
ui_print "[OK] Done. Reboot and check root with the FinaSU manager (32960 / uapi 6)."
ui_print " "
