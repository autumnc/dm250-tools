# DM250 Warp!! 技术文档

Pomera DM250（Rockchip RK3128，armhf，Linux 3.10）上复刻 Lineo「Warp!!」瞬时开关机。
本仓库存放这套机制的**用户态半边**：触发脚本、runit 服务、台架验证脚本，以及主机侧的部署/取证工具。
内核半边（存/恢复序列本身）在 `dm200_debian_kernel` 仓库（分支 `dm250_dev`）。

---

## 1. 一句话原理

Warp 把「整个运行中的系统」在**存盘瞬间**冻结成一块 DRAM 镜像写进 eMMC 的 p5 分区，
之后**直接断电**（不 umount、不关机流程）。再次上电时 U-Boot 把这块 DRAM 原样倒回内存、
跳回内核，于是「同一个会话」在原地继续跑——屏幕上是断电前的那一屏，PID 不变，
`/proc/uptime` 从存盘时刻接着数，而不是从 0。

- **热 warp（hot warp）**：原地存盘 + 原地恢复，不断电。用于验证存/恢复路径本身。
- **冷 warp（cold warp）**：存盘 + 断电，下次上电由 U-Boot 冷恢复。**这是产品形态**，
  也是 F12 与合盖通路做的事。

冷 warp 的关键约束：**存盘完成到断电之间，任何东西都不能写 ext4**。
产品流程是「存完立刻切电」，没有窗口；而台架脚本如果存完之后还跑用户态动作
（写日志、拉起 wifi），干净关机时的 umount 会把**更新的** ext4 元数据刷回，
而恢复侧的内核用的是**存盘瞬间**的 ext4 视图——两者分歧 = 文件系统损坏。

---

## 2. p5 布局（warp 分区）

p5 是 warp 专属分区（`/dev/mmcblk0p5`，约 512 MiB）。机制相关的固定偏移：

| 偏移 | 名称 | 内容 | 说明 |
|---|---|---|---|
| `0x0` | **W5HD** | `5735484400000150`（8 字节） | 休眠驱动 blob 头。**绝不可清**——清了 warp 直接报废（`Warp!! error -5: Can't find hibernation driver`），热 warp 也一样需要。 |
| `0x18000` | **journal** | 16 槽 × 512 B 环形 | p5 黑匣子，冷 warp 挂死时的唯一现场证据。读全部要 `dd ... count=8192`（`count=4096` 只看得到 8 条）。 |
| `0x1f000` | **WARPCLD** | 标记（8 字节） | 内核冷恢复判别子，用于区分「这是被冷恢复的会话」还是「普通开机」。 |
| `0x20000` | **W5BF** | `57354246`=armed / `00000000`=正常 | bootflag。U-Boot 冷恢复的第二个闸门（1 KB 块，`bs=1024 seek=128`）。 |
| `0x20404` | **snapid** | 4 字节 | 存盘镜像 ID，供配对校验。 |

> ⚠ 一个反复踩的坑：**blob 在每次普通存盘途中会自己写 W5BF**，所以热 warp 也有「双闸门同时开」的窗口。
> 若 warp 恰好在该窗口挂死，W5BF 残留 ⇒ 之后每次上电 U-Boot 都冷恢复（黑屏亮背光 + 无网），
> 板子被锁死约 20 分钟。铁律：**魔数只夹住 `echo disk` 那一段**，脚本 trap 兜底，绝不跨轮保留。

---

## 3. warp 实现原理

### 3.1 存盘：`echo disk > /sys/power/state`

内核 `kernel/power/` 下的 warp 补丁把标准 swsusp 挂起到磁盘改造成「存到 p5 + 可控断电」。
- 只保存 `swsusp_page_is_saveable()` 判定的页（可节约页），不是整块 DRAM。
- 存盘**要求面板已熄屏**（`echo 1 > /sys/class/graphics/fb0/blank`）。面板亮着时
  `hibernate()` 会挂死——这是历史缺陷 **#77**。因此所有脚本都先熄屏再存盘。
- 存盘过程中早期显示恢复的寄存器捕获必须是**活体**寄存器。blank 会让时钟门控，
  读回全 `1`/全 `0`，直接把垃圾写进 blob，恢复出来就是彩条或雪花
  （历史缺陷 #139 / #140 / #141，判定见 §8）。

### 3.2 冷恢复：U-Boot 双闸门

`dm200_uboot` 的 `cmd_warp.c`：

```
冷启动 = GPIO2_4 高 且 非 recovery 模式
       → warp_checkboot()   // 闸门 = p5+0 是 W5HD  且  p5+0x20000 是 W5BF
       → blob HIBERNATE (0x28 → 0x488) 恢复 DRAM + CPU
       → 跳回内核
```

两个闸门**都要**满足才冷恢复。因此：
- 只清 W5BF（`dd ... bs=1024 seek=128 count=1`）⇒ 下次是**普通开机**，且 blob（W5HD）完好。
- 清了 W5HD ⇒ warp 彻底失效。

### 3.3 `/proc/warp/` 控制面

| 节点 | 作用 |
|---|---|
| `halt` | **只具信息性，不再选择断电**。置 1 只是顺手设 `keepbf=1` + `earlydisp=1` 再把自己清零；`hibernate()` 本身不断电。 |
| `keepbf` | 存盘时保留 bootflag（即让 blob 写 W5BF）。冷 warp 必须为 1。 |
| `earlydisp` | 显示恢复提前执行（#142 相关）。 |
| `canceled` | 取消标志。存盘前清 0。 |
| `compress` | 存盘镜像压缩。 |
| `stat` / `error` | 存/恢复状态与错误码，成功时 `error=0`。 |

> ⚠ **不要用 `halt=1` 来做冷 warp**。blob 把 halt 存盘当成另一种请求，**根本不 arm W5BF**
> （journal 会出现 `stat=1`，p5+0x20000 保持 0），结果下次 POWER 只是普通开机。
> 第一次 F12 实测就是这么「看起来成功、其实是热 warp」的。
> 正确姿势：`halt=0` + 手工 `keepbf=1` + `earlydisp=1`。

### 3.4 恢复侧内核自动做的事

冷恢复后内核走 cold 分支，自动执行三连（dmesg 里可见，是判据）：
1. `warp_bootflag_clear()` —— 清掉 W5BF（disarm）
2. `warp_wifi_reinit_schedule()` —— 排队 wifi 重枚举
3. `warp_display_unblank()` —— **屏幕自己亮**（#142：末尾复刻 sysfs `fb_blank(UNBLANK)`）

### 3.5 外设不重建问题与 wifi 恢复（warpnet）

冷恢复是 DRAM 回卷，外设不会自动重新上电/枚举：
- **屏幕**：靠 §3.4 的 `warp_display_unblank()` 自亮。
- **warp 前若 `echo 0 > /sys/class/rkwifi/driver`**（存盘必需的静默，见下），AP6212 被断电，
  恢复后 wlan0 不存在。**第一次重载驱动必定失败**：mmc core 看到卡在芯片断电时消失，
  首次 SDIO 读返回 `-ENOMEDIUM (-123)`，bcmdhd abort，需 2–3 次 `dhd_open` 才稳定
  （`_dhdsdio_download_firmware: dongle image file download failed` 等）。
  **`warpnet`** 服务就是这段重试的用户态实现，恢复后约 **95 s** 补回链路。
- **键盘**（tc3589x MFD @ i2c-0 0x45）：`tc3589x_resume()` 本身带 `pm_device_down` 重建逻辑，
  实测 3 轮均自动恢复，不需用户态干预（任务 #143 判为不复现）。

### 3.6 为什么存盘前要静默 wifi

`hibernate()` 需要 mmc2 SDIO 设备能 freeze，而 bcmdhd **不让**：dongle 持 wakelock，
freeze 请求被拒，`echo disk` 以 `-EBUSY` 中止。**存盘前解绑驱动**把热 warp 成功率从
87.5% 拉到 **8/8 = 100%**。顺序有讲究：先 `sv down wpa_supplicant dhcpcd`（它占着接口、
会和 unbind 竞态），再 `echo 0 > /sys/class/rkwifi/driver`。

---

## 4. 用户态通路与脚本用法

### 4.1 F12 —— 冷 warp（tmux 绑定）

前缀是 **F11**（`set -g prefix F11`）。`.tmux.conf` 里：

```tmux
# F12 单击：冷 warp
bind -n F12 run-shell -b '/root/bin/coldwarp.sh >/dev/null 2>&1'
# F11 + F12：正常关机（先清 W5BF + 冷标记，再 shutdown）
bind F12 run-shell -b 'dd if=/dev/zero of=/dev/mmcblk0p5 bs=1024 seek=128 count=1 conv=notrunc 2>/dev/null; \
                       dd if=/dev/zero of=/dev/mmcblk0p5 bs=1 seek=126976 count=8 conv=notrunc 2>/dev/null; \
                       sync; sudo shutdown -h now'
```

- `-b` = 后台执行，不阻塞 tmux server；输出重定向到**文件**而不是管道
  （`echo disk` 期间任何停在管道上的用户态进程都会让 `freeze_processes()` 难受）。
- **正常关机前必须清 W5BF**：U-Boot 是双闸门，但一次「普通重启」若 W5BF 仍 armed 就会掉进冷恢复。
  只清 bootflag 不碰 W5HD，blob 完好。

> 复刻 F12 时别在 ssh 管道里直跑脚本，要用
> `tmux run-shell -b '/root/bin/coldwarp.sh >/dev/null 2>&1'`。

### 4.2 `coldwarp/coldwarp.sh` —— 冷 warp 主体

F12 与合盖计时器**共用**这一个脚本。逐段说明：

```sh
exec >>/tmp/coldwarp.log 2>&1        # tmpfs：存盘到断电之间不写 ext4
[ -e /run/coldwarp.lock ] && exit 1  # 互斥：F12 与合盖不能同时跑
: > /run/coldwarp.lock
```

1. **AC 拒绝**：`ac/online != 0` 直接拒绝并退出。外电在位时软关机会在 ~60 s 后自动重启，
   用起来就变成「重启」而不是「关机」。
2. **熄屏**：`echo 1 > /sys/class/graphics/fb0/blank; sleep 3`（#77）。
3. **静默 wifi**（三个动作为的都是「存盘前不写 ext4 + 让 SDIO 能 freeze」）：
   ```sh
   touch /run/warpnet.off            # 先停用 warpnet（它是 ext4 写者）
   sv down wpa_supplicant dhcpcd     # 再停用户态（dhcpcd 写 leases/hooks）
   echo 0 > /sys/class/rkwifi/driver # 最后解绑驱动
   ```
   `/run` 是 tmpfs，标志随 blob 一起被恢复到冷恢复侧；恢复侧脚本会删掉它，把活交还 warpnet。
4. **存盘**：
   ```sh
   echo 1 > /proc/warp/earlydisp
   echo 1 > /proc/warp/keepbf
   echo 0 > /proc/warp/halt          # 见 §3.3：绝不能用 halt=1
   echo 0 > /proc/warp/canceled
   echo 1 > /proc/warp/compress
   sync
   echo disk > /sys/power/state
   ```
5. **replay 守卫**（本脚本最容易写错的地方）：
   ```sh
   bf=$(dd if=/dev/mmcblk0p5 bs=1 skip=$((0x20000)) count=4 | od -An -tx1 | tr -d ' \n')
   if [ "$bf" = "57354246" ]; then   # W5BF 还在 ⇒ 活侧
       sync; /usr/bin/poweroff -f
   else                              # 已被 U-Boot 冷恢复 ⇒ 这是重放
       rm -f /run/warpnet.off; rm -f /run/coldwarp.lock
   fi
   ```
   - **为什么需要守卫**：`echo disk` 恢复后 U-Boot 把 DRAM 回卷到存盘瞬间，
     脚本会**从 `echo disk` 返回处被重放**。只有「活侧」W5BF 还 armed。
     搞反了就会「一恢复就再断电」——无限循环。
   - **为什么要 `poweroff -f`**：`-f` 直走 `reboot(RB_POWER_OFF)`，由内核
     `device_shutdown()` 和 rk818 切电；不加 `-f` 时 busybox 先通知 init，runit 跑关机器脚本并
     **umount**——那个 umount 会把「存盘后活会话写的更新元数据」刷盘，正是要避免的 ext4 分歧。
     这是最接近原厂「存完立刻切电」的软件做法。
   - 存盘失败（`rc != 0`）时**绝不能断电**：会话还活着，切电等于丢会话；脚本会解开 warpnet 的 park 并退出。
   - **锁必须留在 `/run`（tmpfs），且必须由被恢复的一侧删掉**——`/run` 随 blob 一起恢复，
     不删的话冷恢复后的会话再也发不起冷 warp。

### 4.3 合盖策略（三段，阈值 5 分钟）

`lidscreen` 已经做对了屏幕部分（轮询 `gpio20`，低有效：0=合盖；`edge=both` + `poll()`；
合盖 `FBIOBLANK(POWERDOWN)`，只在开盖跳变时 unblank；30 s 看门狗只重关不点亮）。
**`lidwarp` 只拥有「计时 + 断电」**，不碰 lidscreen，避免改坏已验证的熄灭/点亮逻辑。

```
TICK=5  LIMIT=300                 # LID=/sys/class/gpio/gpio20/value
循环：闭合则 closed += TICK；closed >= 300 时 → closed=0 → /root/bin/coldwarp.sh
      开着则 closed = 0
```

| 段 | 触发 | 动作 | 恢复方式 |
|---|---|---|---|
| **1** | 合盖 | lidscreen 熄屏；系统照常运行（**不存盘**） | — |
| **2** | 5 min 内开盖 | lidscreen 点亮；`closed` 清零；会话从未中断，瞬时可用 | 直接继续 |
| **3** | 合盖满 5 min | `coldwarp.sh`：已熄屏 → 存盘 → replay 守卫 → **自动断电** | **按 POWER**（开盖不唤醒） |

设计取舍：合盖**不做热 warp**。热 warp 是原地存/恢复，屏幕本来就由 lidscreen 管；
存盘那 ~25 s 只会白写一次 p5，还把 **#77 存盘挂死**从「偶发」变成「每次合盖」。

外电在位时 `coldwarp.sh` 拒绝（§4.2 第 1 点），所以接充电器合盖 ⇒ 保持「熄屏但运行」。

> 已知边界：`lidwarp` 随 DRAM 被冷恢复，若盖仍合着，5 分钟后会再冷 warp 一次。
> 这其实是正确行为（盖合着＝没人用）；若要改，让它在恢复后等一个开盖跳变再重新计时。

### 4.4 `warpnet` —— 恢复后补 wifi

`coldwarp/warpnet.run`。启动时先等链路建立（避开开机 bring-up），然后：
- `TICK=5`，`DEBOUNCE=45`（无地址持续这么久才动手；必须大于 warp 冻结窗口 ~20 s），
  `FROZE=12`（一次 TICK 秒的 sleep 实际耗时这么久 ⇒ 进程被冻结过 ⇒ warp 刚恢复，立即动手），
  `MAXTRY=6`，`SETTLE=15`。
- 每次尝试：`echo 0/1 > /sys/class/rkwifi/driver` → `sv up wpa_supplicant dhcpcd` → 查 IPv4。
- 唯一诚实的成功判据是「wlan0 拿到非 169.254 的 IPv4」，只有用户态能看到。
- `touch /run/warpnet.off` 可停用（冷 warp 存盘前就是这么 park 它的）。

### 4.5 其他 runit 服务（`coldwarp/*.run`）

| 文件 | 目标 `/etc/sv/<name>/run` | 作用 |
|---|---|---|
| `run` | `lidwarp/run` | `exec /root/bin/lidwarp.sh >>/tmp/lidwarp.log 2>&1` |
| `lidscreen.run` | `lidscreen/run` | `exec /root/bin/lidscreen >>/tmp/lidscreen.log 2>&1` |
| `warpnet.run` | `warpnet/run` | 见 §4.4 |
| `fbblank.run` | `fbblank/run` | 空闲 `IDLE` 秒后 `FBIOBLANK` 关屏 |
| `wdt-arm.run` | `wdt-arm/run` | `[ -w /proc/wdt ] && echo 1 > /proc/wdt`，再 sleep 常驻。**只在带 `CONFIG_RK312X_WDT` 的内核（#144+）里才有意义**，否则 `/proc/wdt` 不存在、服务空转。 |
| `warpsave.run` | `warpsave/run` | 一次性：挂 pstore，把 `/sys/fs/pstore/*` 搬到 `/var/log/crash/`，清 pstore，`echo 1 > softlockup_panic`，`exec sleep infinity` 常驻。 |
| `kcapture.sh` | — | 每秒把 dmesg 落盘到 `/root/soak/dmesg.<boot_id>`，只留最新 8 份。panic/oops 存活到重启后。 |
| `kmsglog.sh` | — | 把 `/dev/kmsg` 追加进 `/var/log/kmsg.log`，跨重启。注：shell 逐字节 `read` `/dev/kmsg` 会 `EINVAL`，用 `cat`。 |

### 4.6 部署：`coldwarp/deploy-coldwarp.sh`

```bash
HOST=root@192.168.50.251 ./coldwarp/deploy-coldwarp.sh [--keep-wdt]
```

- 拷 `coldwarp.sh`、`lidwarp.sh` 到 `/root/bin/`，`run` 到 `/etc/sv/lidwarp/run`，
  tmux 配置到 `/root/.tmux.conf`；`ln -sfn` 启用 `lidwarp`。
- `--keep-wdt`：保留 `/var/service/wdt-arm` 软链。运行带 `CONFIG_RK312X_WDT` 的内核（#144+）时传。
  不传则摘掉软链（`CONFIG_WARP_DIAG=n` 且无独立看门狗的内核里 `/proc/wdt` 不存在，服务空转）。
- 末尾自检：grep `.tmux.conf`、看 `/proc/wdt`、`sv status lidwarp warpnet`、读 `ac/online`。

---

## 5. 冷 warp 端到端过程（实测）

```
① 拔外电（必须，否则 coldwarp.sh 拒绝）
② 按 F12（或合盖满 5 min）
     → coldwarp.sh：熄屏 → park warpnet → 停 wifi → echo disk → p5 存 blob + arm W5BF
     → replay 守卫读到 W5BF=57354246（活侧）→ poweroff -f
     → 板子断电
③ 按 POWER
     → U-Boot：W5HD + W5BF 双闸门成立 → 倒回 DRAM → 跳回内核
     → 内核 cold 分支三连：disarm W5BF / 排 wifi 重枚举 / 屏幕自亮
     → 脚本被重放，守卫读到 W5BF 已清 → 删 /run 锁、解开 warpnet park
     → warpnet 约 95 s 补回 wlan0
```

**判「确实是冷恢复而非正常开机」的最锋利一条**：`/tmp/coldwarp.log`（tmpfs）
里面带着**存盘前那半边**的日志（活侧行会被 DRAM 回卷抹掉，看到的是恢复侧重放行，
不是失败）。其它佐证：`/proc/uptime` 从存盘时刻延续（不是 0）、PID 与存盘前一致、
dmesg 有冷恢复三连、journal 9 条记录。

**判「正常关机走正常开机」**（F11+F12 的语义）：`/tmp/coldwarp.log` **不存在**
（tmpfs 已随掉电重建）、`uptime` 从 0、PID 全新、dmesg 无 cold restore 痕迹、`bf=0`。

### 状态速查（设备上）

```sh
# p5 三件套
dd if=/dev/mmcblk0p5 bs=1 count=8                     2>/dev/null | od -An -tx1   # W5HD 魔数
dd if=/dev/mmcblk0p5 bs=1 skip=$((0x20000)) count=4   2>/dev/null | od -An -tx1   # W5BF
dd if=/dev/mmcblk0p5 bs=1 skip=$((0x1f000)) count=8   2>/dev/null | od -An -tx1   # WARPCLD
# 全量 journal（16 槽，count 必须 8192）
dd if=/dev/mmcblk0p5 bs=1 skip=$((0x18000)) count=8192 2>/dev/null | strings
# warp 状态
cat /proc/warp/stat /proc/warp/error
# 外电
cat /sys/class/power_supply/ac/online
```

---

## 6. 台架与验证脚本

### 6.1 主机侧（`scripts/`）

| 脚本 | 用途 |
|---|---|
| `flash-p2.sh <image> [tag]` | **刷内核**。先 disarm 写断点 → 整块备份 p2 到 `/home/ywz/p2-backups/p2-backup-before-<tag>.img`（校验长度）→ 清 W5BF + 冷标记（保证重启是**普通开机**）→ 写 p2 → 重启并等回线。**只管 p2**，绝不碰 p1/U-Boot。 |
| `watch-coldwarp.sh` | 冷 warp 无人值守取证。等板子离线（连续 2 次 ssh 失败才算）→ 提示按 POWER → 等回线后把 `coldcap-remote.sh` 的输出来抓回 `~/dm250-evidence/coldwarp-test-capture.log`。每事件一行 stdout（适合 Monitor）。 |
| `coldcap-remote.sh` | 经 ssh 管道到设备上 `sh -s` 执行：dump uptime/warp stat/coldwarp.log/journal/magic·bf·marker/ext4 错误/显示 gpio/wifi/服务状态。 |
| `dm250-patrol.sh` | 崩溃巡检。轮询 `boot_id`，变了 = 上一轮非干净关机；拉回该轮 `dmesg` 与 `/var/log/crash/*` 到 `~/dm250-crashes/`，打印一行 ALERT。无变化时静默。 |
| `dm250-patrol-notify.sh` | patrol 的通知包装。 |

### 6.2 设备台架（`warp-bench/`、`hotwarp-round.sh`）

| 脚本 | 用途 |
|---|---|
| `hotwarp-round.sh` | **阶段 2 热 warp 回归**：一轮 `sv down wpa_supplicant dhcpcd` → `echo 0 > rkwifi/driver` → `echo disk`，写 `/root/hotwarp.log`。 |
| `cw148.sh` / `cw149.sh` / `cw150.sh` | 冷 warp 端到端台架（显示+wifi+键盘三项）。cw150 是 **DIRECTION-A 修正版**：日志/抓帧走 tmpfs（零 ext4 写）、FIRST 段不调 `wifi_up()`（p8 写者）、`touch /run/warpnet.off` park 掉 warpnet；操作员信号 = 存盘后 unblank 并闪 3 次 = 立即硬断电。 |
| `ww126/127/128.sh`、`wwloop_host.sh`、`wwround.sh` | 写断点（warp_watch）抓内存破坏 writer 的一族实验。 |
| `freeze_gate_test.sh` | `echo freeze` 门控实验。 |
| `wifi_unload_test.sh` | 验证「warp 前卸载 wifi」杠杆。 |
| `sr-*.sh` | suspend-to-RAM 路线（**已证死路**，#44 回退，留作记录）。 |

> ⚠ `cw146.sh` 的 `p5off()` 会清零 p5+0 的 W5HD ⇒ **warp 全废**。它是历史台架，别当模板。

---

## 7. 救砖与常见陷阱

### 救砖
只用 `dd` 清 **bootflag** 与**冷标记**，**保留 p5+0 的 W5HD**：

```sh
dd if=/dev/zero of=/dev/mmcblk0p5 bs=1024 seek=128 count=1 conv=notrunc   # 清 W5BF
dd if=/dev/zero of=/dev/mmcblk0p5 bs=1 seek=$((0x1f000)) count=8 conv=notrunc  # 清 WARPCLD
sync
```

### 陷阱清单
1. **清了 W5HD（p5+0）** ⇒ warp 彻底失效（`Warp!! error -5`），必须从备份恢复。
2. **W5BF 跨轮残留** ⇒ 下次上电必冷恢复（黑屏 + 无网，锁 ~20 min）。所以「魔数只夹住 `echo disk`」。
3. **`halt=1` 做冷 warp** ⇒ blob 不 arm W5BF ⇒ 实际是普通开机（§3.3）。
4. **存盘后写 ext4** ⇒ 恢复后文件系统损坏。脚本日志/抓帧一律走 tmpfs。
5. **`/run/coldwarp.lock` 不在恢复侧删掉** ⇒ 冷恢复后的会话永远发不起冷 warp。
6. **正常关机不清 W5BF** ⇒ 掉进冷恢复（§4.1）。
7. **设备上 `grep` 是 `rg` 的包装函数** ⇒ 一律用 `/bin/grep`，否则匹配语义会被静默改掉。
8. **写断点 `warp_watch` 武装状态下重 I/O 会间歇 soft-lockup** ⇒ 刷机前务必
   `echo 0 > /proc/warp_watch_auto` 与 `/proc/warp_watch`（`flash-p2.sh` 已内置）。

### 判据速查（显示）
| 观察 | 健康值 | 故障含义 |
|---|---|---|
| gpio0 低 8 位 | `09000000`（b27=背光使能） | b27=0 ⇒ 屏幕黑（#142 未生效） |
| `1010e020`（WIN0_YRGB_MST） | `10000000` | `00000000`/`ffffffff` ⇒ 雪花（指向地址 0） |
| LVDS `grf150` | `0000034c` | `0000030c` ⇒ LVDS off（#141） |
| 键盘 i2c 0x80 / 0xF3 | `0x03` / `0x03` | 读须 `i2cget -f -y 0 0x45`（驱动占 0x45） |

---

## 8. 参考：内核侧对应关系

| 主题 | 内核位置 / 提交 |
|---|---|
| 存/恢复主流程 | `kernel/power/warp.c`、`snapshot.c` |
| 冷恢复三连 | `warp.c` cold 分支（bootflag_clear / wifi_reinit / display_unblank） |
| 冷恢复判别子 | p5+0x1f000 的 WARPCLD（commit `2d4bd2d1`） |
| 显示非活体捕获修复 | #139 / #140 / #141（LCDC/LVDS 活体判定 + 调用顺序） |
| 冷恢复自亮屏 | #142（`warp_display_unblank()`） |
| 内存破坏根因修复 | #93 `timer.c:cascade()` 补重插循环；#94 净环境 24 h 复验 |
| 硬看门狗拆分 | #144 `CONFIG_RK312X_WDT` 独立于 `CONFIG_WARP_DIAG` |
| pstore 捕获链 | #147（`CONFIG_PSTORE*` + `CONFIG_MISC_FILESYSTEMS`） |

内核构建（`dm200_debian_kernel`）：

```bash
export PATH=/home/ywz/gcc-linaro-4.9-2014.11-x86_64_arm-linux-gnueabihf/bin:$PATH
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- dm250_defconfig
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- zImage -j$(nproc)
./mkkrnlimg arch/arm/boot/zImage kernel-NNN.img
```

> ⚠ `make dm250_defconfig` 会用 defconfig **重生成** `.config`，静默丢掉只在 `.config` 里手工开的选项
> （pstore 就是这么丢过一次）。手工选项要写进 `arch/arm/configs/dm250_defconfig`。
