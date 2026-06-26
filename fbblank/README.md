# fbblank

Linux 帧缓冲空闲关屏守护进程，配合 runit 前台运行。

编译后为单个静态二进制，无运行时依赖，适合嵌入式 / DM200 等环境。

## 编译

本地编译:

```sh
gcc -Wall -Wextra -Os -s -o fbblank fbblank.c
```

ARM 交叉编译（静态链接，musl libc，~22K）:

```sh
zig cc --target=arm-linux-musleabihf -static -Os -s -flto \
    -ffunction-sections -fdata-sections -Wl,--gc-sections \
    -Wall -Wextra -Werror -o fbblank fbblank.c
```

## 用法

```
fbblank [-t idle_sec] [-s sleep_sec] [-c cmd] [-f /dev/fbN]
```

| 选项 | 默认值 | 说明 |
|------|--------|------|
| `-t` | 300 | 空闲多少秒后熄屏 (FBIOBLANK) |
| `-s` | 0 | 空闲多少秒后执行休眠命令，必须 > `-t`，0 表示禁用 |
| `-c` | - | 休眠命令，通过 `sh -c` 执行，与 `-s` 配套使用 |
| `-f` | `/dev/fb0` | 帧缓冲设备路径 |

### 单阶段：仅熄屏

```sh
fbblank -t 300
```

5 分钟无键盘输入后熄屏，任意按键亮屏并重置计时。

### 两阶段：熄屏后休眠

```sh
fbblank -t 300 -s 600 -c zzz
```

- 5 分钟无操作 → 熄屏
- 再 5 分钟无操作（总计 10 分钟） → 执行 `zzz` 进入休眠
- 任意按键亮屏并重置全部计时
- 休眠命令失败时记录日志，重新计时后再次尝试

## runit 集成

将 `run` 脚本放入 service 目录（如 `/etc/sv/fbblank/run`），通过 `conf` 文件覆盖默认值：

```sh
# /etc/sv/fbblank/conf
IDLE=300
SLEEP=600
SLEEP_CMD=zzz
FBDEV=/dev/fb0
```

## 注意事项

- 需要 `/dev/fb0` 读写权限和 `/dev/input/event*` 读权限
- 扫描 `/dev/input/` 目录自动发现键盘类设备（检测 EV_KEY 能力位）
- 休眠命令需有系统挂起权限（如 `zzz` 需写 `/sys/power/state`）
- 收到 SIGTERM/SIGINT 时先恢复亮屏再退出
