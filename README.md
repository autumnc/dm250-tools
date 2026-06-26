# dm250-tools

Pomera DM200/DM250 (rk3128 ARM Linux) 系统工具集。所有工具均为单二进制、无运行时依赖，适合嵌入式环境。

## 工具列表

### blctl — 背光调节

TUI 背光亮度控制器，通过 `/sys/class/backlight/rk28_bl/brightness` 调节屏幕亮度。

- PageUp / PageDown 步进 ±5%
- 进度条 + 百分比 + 原始值实时显示
- 3 秒无操作自动退出
- 纯 C，无外部依赖

### fbblank — 帧缓冲空闲关屏

键盘输入监控守护进程，空闲超时后通过 `FBIOBLANK` ioctl 关闭屏幕，配合 runit 前台运行。

- 自动扫描 `/dev/input/event*` 发现键盘设备（检测 EV_KEY 能力位）
- 单阶段模式：空闲 → 关屏，任意按键亮屏
- 两阶段模式：空闲 → 关屏 → 再空闲 → 执行休眠命令（如 `zzz`）
- 收到 SIGTERM/SIGINT 时自动恢复亮屏后退出
- 纯 C，静态 armhf 编译后约 22K

```
fbblank [-t idle_sec] [-s sleep_sec] [-c cmd] [-f /dev/fbN]
```

### qsend — 快写发送

flomo 笔记快速发送 TUI 工具。登录后进入编辑器，写完 Ctrl+S 即发送并退出。

- flomo API 登录（邮箱/密码），token 持久化到 `~/.flomo-cli/`
- 全功能文本编辑器：光标移动、换行、退格删除、行合并、滚动
- 底部状态栏显示字数/行数/字节数
- 支持 CJK 字符宽度正确处理
- Rust + ratatui + crossterm

### wifi-tui — WiFi 管理器

基于 wpa_supplicant 的 TUI WiFi 管理工具，[wifi-config](https://github.com/DennisSchulmeister/wifi-config) 的 Rust 重写版。

- 扫描附近 WiFi 网络
- 连接开放 / WPA2-PSK / WPA-Enterprise (PEAP) 网络
- 管理已保存网络（添加、编辑、删除）
- 查看连接状态、IP 地址、wpa_supplicant 配置
- 支持 `--debug` 模式查看底层命令输出
- Rust + ratatui + crossterm

## 编译目标

所有工具以 armv7-unknown-linux-gnueabihf（DM200/DM250）为主要目标平台：

| 工具 | 语言 | 编译方式 |
|------|------|----------|
| blctl | C | `arm-linux-gnueabihf-gcc` 或 `zig cc --target=arm-linux-musleabihf -static` |
| fbblank | C | `zig cc --target=arm-linux-musleabihf -static` |
| qsend | Rust | `cargo-zigbuild --target armv7-unknown-linux-gnueabihf` |
| wifi-tui | Rust | `cargo +nightly build -Z build-std --target armv7-unknown-linux-gnueabihf` |
