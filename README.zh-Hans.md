# CMCC PZL8 PassWall 测试固件

本仓库以 `PZL8-2025-01-03` 的 CMCC PZ-L8 factory 固件为基底，在不替换原有
Linux 5.4、32 位 QSDK、Qualcomm 专有 WiFi 和 NSS 驱动的前提下，预置精简版
PassWall。

## 固件策略

- 保留原固件 kernel、DTB 和硬件驱动，不混入其他内核模块。
- 将 PassWall/Xray 写入只读 SquashFS，保留配置刷机也不会覆盖插件。
- 移除 MosDNS、其 LuCI 文件及专用 `v2dat` 工具，为 PassWall/Xray 腾出
  SquashFS 空间；保留 Xray 使用的 GeoIP/GeoSite 数据。
- LuCI/Web 升级镜像保留基底固件原有的 IPv6 DHCP Relay、Quagga 和
  ZeroTier，不因 U-Boot Web 的 32 MiB 限制删减这些功能。
- PassWall 只启用 nftables 透明代理。
- 只预置 Xray 核心，不加入 Sing-Box、SSR、Hysteria、NaiveProxy 等额外核心。
- 为内置 Xray 1.8.24 加入兼容层：启动时仅对 Xray 1.x 将新版 PassWall 生成的
  `raw` 传输以及扁平 VLESS、Shadowsocks 出站配置转换为旧核心可识别的格式。
- 将 PassWall nftables 阻断规则的 `reject` 降级为 `drop`，兼容基底固件的
  Linux 5.4 nftables；这也用于阻断 UDP 443，避免 QUIC 绕过仅 TCP 的代理。
- PassWall 开机兜底启动显式关闭标准输入，避免其 nftables 管道中的 `cat`
  等待 EOF，导致启动流程停在“开始加载 nftables 防火墙规则”。
- 包含 PassWall 中文 LuCI 翻译。
- LuCI 发行版名称和 SSH 登录横幅显示为 `PZL8`。
- 首次启动时默认无线名称为 `PZL8_2.4G_0` 和 `PZL8_5G_1`。
- 开机 90 秒后再次检查 SSID，修复 QSDK 后期初始化把名称覆盖回 `Nwrt` 的情况。
- PassWall 默认关闭，刷机后由用户配置节点并手动启用。
- rootfs 卷最多使用 246 个 LEB；`rootfs_data` 保持空白并自动扩容，预计仍有
  约 20.7 MB 可写空间。原有配置可继续覆盖只读 rootfs。
- 修复 QSDK `platform.sh` 对 NUL 分隔设备树兼容列表的解析，确保
  `cmcc,pzl8` 能进入 NAND sysupgrade 流程。
- 修复 Web 不保留配置升级后仍启动旧固件：升级时读取 bootconfig 的
  `upgradepartition`，只写入非活动的 `rootfs`/`rootfs_1` 槽，校验 UBI 中的
  kernel 和 rootfs 卷后再同步更新 `BOOTCONFIG`、`BOOTCONFIG1`。
- 双槽升级脚本只使用 QSDK stage2 RAMFS 默认携带的命令，避免因 `tr`、`head`
  未复制到 RAMFS 而在写入前退出、随后仅重启回旧槽。
- 构建额外输出 `PZL8-2026-08-11-passwall-nft-xray-uboot-recovery.bin`。
  该文件采用与官方刷机包相同的 FIT + `flash.scr` 形式，但只擦写当前双槽布局的
  两个 rootfs 区域，不改写 SBL1、MIBIB、BOOTCONFIG、QSEE、DEVCFG、CDT、
  APPSBL/U-Boot、ART 等引导或校准分区。

## U-Boot 救援固件

U-Boot recovery 固件只适用于已经采用本仓库当前双 rootfs 分区布局的 CMCC
PZL8。它不是 `single_to_sch` 分区转换包，不能用于仍为单 rootfs 布局的机器。
FIT 根描述使用官方 U-Boot Web 识别的 `Flashing nand 800 20000`，其中
`800`/`20000` 分别对应 2048 字节 NAND 页和 128 KiB 擦除块。不要把该文件
上传到 LuCI 系统升级页面。

设备自带 U-Boot Web 的 HTTP 上传程序有 32 MiB 硬限制。recovery FIT 因此
使用 U-Boot 支持的 gzip 载荷，在 RAM 地址 `0x48000000` 解压后再写入两个
rootfs 槽。为保留足够的上传余量，测试固件移除了不影响中文、Argon、
PassWall/Xray、QSDK 无线或 NSS 的 IPv6 DHCP Relay、Quagga、ZeroTier 和
ttyd Web 终端及 ksmbd。由于这版 U-Boot 的单次 gzip `imxtract` 解压上限为
8 MiB，recovery 会把 UBI 分为多个不超过 7 MiB 的节点，依次解压到连续 RAM
后再整体写入。

U-Boot recovery 固件固定复用 `pzl8-passwall-656ca3f` 已验证附件，SHA-256
必须为
`027bccc7394d8ae6149cf3a9270747f1a90d1b683b0903dd8a7f2b19207b5fce`。
构建只扩充 LuCI/Web 升级镜像，不能重新生成或改变该 recovery 文件。

通过 TFTP 加载后可执行：

```text
tftpboot 0x44000000 PZL8-2026-08-11-passwall-nft-xray-uboot-recovery.bin
setenv imgaddr 0x44000000
source 0x44000000:script
reset
```

脚本会校验 IPQ5018 `soc_hw_version`/`machid`，随后把同一 UBI 镜像写入
`0x00900000` 和 `0x04300000` 两个 58 MiB rootfs 槽。执行前应保留 TTL，
并确认设备分区布局与本仓库验证的 PZL8 双槽布局一致。

## 固定版本

所有输入版本和 SHA-256 均记录在 `pins.env`。基底固件的 SHA-256 必须为：

```text
b2464663e4d0693b5869c277d61542258b3562c40bfed3353faf071155fad7e3
```

构建使用 OpenWrt 23.05.5 `ipq40xx/generic` SDK，其用户空间架构与基底固件均为
`arm_cortex-a7_neon-vfpv4`。SDK 只用于构建用户空间软件，SDK 的 kernel module
不会打入固件。

## 构建产物

GitHub Actions 输出：

- `PZL8-2026-08-11-passwall-nft-xray-rootfs-factory.bin`
- `PZL8-2026-08-11-passwall-nft-xray-uboot-recovery.bin`（锁定原文件）
- `sha256sums`
- `build-manifest.txt`
- `passwall-packages.txt`

`build-manifest.txt` 会记录基底与成品哈希、UBI 卷参数、overlay 大小、Xray ELF
架构、Xray 1.x 兼容层、nftables 阻断动作、Web 镜像恢复的软件包、锁定的
U-Boot recovery 来源和 PassWall 默认状态。

## 风险边界

CI 成功仅证明软件包构建、固件尺寸和静态结构校验通过。实体启动、无线可见性、
NSS 状态、有线/无线千兆性能仍需在 PZ-L8 上刷机验证。首次测试应保留 TTL 和
initramfs 救援条件，不要擦除 ART、bootconfig 或其他校准分区。

当前实体机已验证 VLESS/Reality 和 Shadowsocks 的 TCP 透明代理，并验证一次
受控重启后的 PassWall 自动启动、nftables 规则、DNS、HTTPS 和 PZL8 SSID。
UDP 节点未配置，其他协议、链式代理、负载均衡及分流节点仍需单独验证。
