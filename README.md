# OPPO PJH110 内核 CI（DroidSpaces）

这个仓库用 GitHub Actions 编译 OPPO Reno11 5G（型号 `PJH110`，MT6896）的
Android 15 内核，目标是通过 DroidSpaces 的内核要求检查。

## 当前基线

- 源码：`oppo-source/android_kernel_oppo_mt6896`
- 分支：`oppo/mt6896_v_15.0.0_reno11`
- 提交：`65da65bd3ececbd209a03c1357175ba6f2efb12e`（公开源码为 5.10.209）
- 手机实际内核：`5.10.226-android12-9-o-g18972ebc96a3`
- 配置基线：你提供的 `/proc/config.gz`，保存在 `configs/pjh110-device.config`

公开源码比手机固件落后 17 个稳定版。为了保证原厂 vendor 模块能通过
`vermagic` 检查，构建时会把 `SUBLEVEL` 设为 `226`，并设置：

```text
CONFIG_LOCALVERSION="-android12-9-o-g18972ebc96a3"
CONFIG_LOCALVERSION_AUTO=n
```

这样生成的 release 字符串与原厂一致。5.10 的 GKI KMI 是稳定的，但这棵公开
源码并不是 870 固件的逐字节对应源码；如果模块 CRC 仍然不匹配，见下面的
“模块加载失败”。

## 两棵源码树

OPPO 的公开内核树把 vendor 驱动放在另一个仓库里，用符号链接接进来，例如：

```text
kernel/oplus_cpu                     -> ../../vendor/oplus/kernel/cpu
drivers/soc/oplus/hans               -> ../../../../vendor/oplus/kernel/hans
sound/soc/codecs/audio               -> ../../../../vendor/oplus/kernel_5.10/audio
```

一共三十多个这样的链接，全部指到 `kernel-src/` 旁边的 `vendor/`。只解压内核
tarball 的话它们是悬空链接，`olddefconfig` 会在
`init/Kconfig:858: can't open file "kernel/oplus_cpu/sched/Kconfig"` 处直接失败。

所以 CI 会同时拉取：

- `oppo-source/android_kernel_oppo_mt6896` → `kernel-src/`
- `oppo-source/android_kernel_modules_oppo_mt6896`（分支
  `oppo/mt6896_v_15.0.0_reno11`）→ `kernel-modules/`，并软链到 `vendor/`

`scripts/fetch-sources.sh` 在构建前会遍历所有 symlink，只要有一个指不进
`vendor/`，就打印路径并让任务失败，不会等到编译中途才报错。

## 已启用的特性

`configs/droidspaces.fragment` 在原厂配置上增加：

- DroidSpaces 必需：SYSVIPC、POSIX mqueue、IPC/PID/UTS/user namespace、
  seccomp、devtmpfs、cgroup device、tmpfs xattr/POSIX ACL
- 网络隔离：netns、veth、bridge、bridge netfilter、macvlan、macvtap、
  ipvlan、VXLAN、GENEVE、VLAN
- NAT / NAT66：IPv4/IPv6 masquerade、conntrack、addrtype、nf_tables、
  nft NAT/masq/redirect/reject 等
- UFW / fail2ban：ipset、xt recent/limit/hashlimit/owner/multiport/state、
  LOG/NFLOG/MARK/TCPMSS 等
- 容器镜像：squashfs（zlib/lz4/xz/zstd）、ext4、overlayfs、FUSE、TUN、
  loop

为了不破坏原厂模块 ABI，以下两个选项**故意没有开启**：

- `CONFIG_CFS_BANDWIDTH`：DroidSpaces 的 `--cpus` 需要
- `CONFIG_CGROUP_PIDS`：DroidSpaces 的 `--pids-limit` 需要

DroidSpaces 官方文档明确说明这两个选项会改变 scheduler/cgroup 结构大小，
导致几千个导出符号的 CRC 变化。开启后必须同时重新编译并刷入
`vendor_boot`/`vendor_dlkm`/`system_dlkm` 中的所有模块，否则会 bootloop。
本仓库只替换 `boot` 分区中的 GKI 内核，所以保持关闭。

## 编译

把仓库推到 GitHub，打开 Actions，运行 `Build PJH110 kernel`。

默认使用：

- Android clang r416183b（与原厂一致）
- ThinLTO（比原厂 Full LTO 快，保留 CFI）
- 关闭 `CONFIG_DEBUG_INFO`（减小体积，不影响模块加载）
- 保留 KASAN/UBSAN/CFI（原厂模块带这些插桩，内核必须保留对应符号）

工作流结束后下载 artifact `pjh110-droidspaces-kernel-<run>`，里面有：

- `Image.gz`（AnyKernel3 包里用的就是它；实测原厂 `boot.img` 的内核是 gzip，
  `arch/arm64/Makefile` 的 `KBUILD_IMAGE` 也是 `Image.gz`）
- `Image` / `Image.lz4`（手动重打包 `boot.img` 时的备选）
- `System.map`
- `config`
- `AnyKernel3-PJH110.zip`
- `build-info.txt`

只想验证配置、不想等完整编译时，手动运行工作流并勾选 `config_only`：
它只做源码拉取、打补丁、`olddefconfig` 和配置校验，几分钟出结果，并上传
最终 `.config`。

## 刷入前提

**bootloader 必须是解锁状态。** 你提供的设备信息是
`Bootloader: locked`、`Verified boot: green`。锁定状态下无法刷入未签名的
自定义内核；这是签名链限制，不是内核配置问题。

解锁后有两种方式：

1. 用支持 AnyKernel3 的自定义 recovery 刷 `AnyKernel3-PJH110.zip`。
2. 用 `Image.lz4` 解包/重打包原厂 `boot.img`，然后
   `fastboot flash boot new-boot.img`。

本仓库没有修改 `device.dtb`，也没有改 `vendor_boot`。如果只是替换 GKI
内核，通常只需要动 `boot` 分区。

## 验证

刷入后：

```bash
adb shell uname -r
# 期望：5.10.226-android12-9-o-g18972ebc96a3
```

然后打开 DroidSpaces：

`Settings -> Requirements -> Check Requirements`

“must have”和“recommended”应全部通过；只有 `--cpus` / `--pids-limit`
会因为上面两个选项保持关闭而显示不可用。

也可以用 `droidspaces check` 查看缺项。

## 模块加载失败

先看：

```bash
adb shell su -c 'dmesg | grep -i -E "version magic|disagrees|Unknown symbol"'
```

常见两类：

- `version magic ... should be ...`：release 字符串没有对齐。
- `disagrees about version of symbol`：模块 CRC 与内核不一致。

如果出现 CRC 不一致，说明 870 固件的 vendor 模块和公开 5.10.209 源码之间
仍有 OPPO 私有符号差异。此时需要：

1. 从手机提取一个原厂模块确认 vermagic：

   ```bash
   adb shell su -c 'f=$(ls /vendor/lib/modules/*.ko | head -1); strings "$f" | grep -m1 vermagic'
   ```

2. 提供 `dmesg` 中的具体符号名；或者提供原厂 `boot.img`、
   `vendor_boot.img`，再决定是否改为“重编全部模块 + 刷 vendor_dlkm”的方案。

## 备注

- 这是 GKI 内核，不是把 vendor 驱动全部内建的 monolithic 内核。
- 没有重新编译 vendor 模块，所以不要开启会破坏模块 ABI 的选项。
- 如果只需要能跑 DroidSpaces，当前配置已经覆盖官方文档的 required 和
  recommended 项（除 CPU/PID 限额）。
