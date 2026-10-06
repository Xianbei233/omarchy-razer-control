# Omarchy Razer Control

本项目包含 Rust HID 安全后端、Omarchy Quickshell 状态栏按钮与控制面板，以及用户级部署脚本。后端仅允许 Razer Blade 14 2021（USB `1532:0270`）。软件测试和构建已通过；未进行真实硬件验证。

## 构建与测试

需要 Rust/Cargo。运行 `sh bin/check.sh`（等价于 `cargo test --locked` 与 `cargo build --release --locked`）。二进制名为 `omarchy-razer-control`。

## CLI / JSON 契约

所有命令 stdout 输出单行 JSON；失败为退出码 1 和 `{"ok":false,"error":"..."}`。

```text
omarchy-razer-control discover
omarchy-razer-control status
omarchy-razer-control verify-fans  # 写入/读回四个风扇目标点，随后尝试恢复
omarchy-razer-control fan-auto
omarchy-razer-control fan CPU_RPM GPU_RPM
omarchy-razer-control performance cpu|gpu LEVEL
omarchy-razer-control battery 0|1 LIMIT  # 保留原 CLI 参数；当前仅允许读取，写入拒绝
omarchy-razer-control logo off|static|breathing
omarchy-razer-control keyboard MODE SPEED DIRECTION R G B
omarchy-razer-control brightness PERCENT
```

`discover`：`{ok:true,devices:[{path,interface,accessible,vendor,product}]}`。`status` 及成功写入返回 `{ok:true,device,model,fields,timestamp,settings,limitations}`；每个字段为 `{ok:true,value:...}` 或 `{ok:false,error}`。风扇读数是 `{target_rpm,actual_rpm:null,kind:"manual_setpoint",raw}`，绝不是实时 RPM。写操作契约为完成设备应答和读回核验后返回相同状态结构；波浪方向只能确认应答，不能读回方向。帮助为 `{ok:true,usage,no_automatic_replay:true}`。

## 安装

先 `cargo build --release --locked`，确认同一仓库 `plugin/` 已准备好，并安装 `jq`。然后可运行 `sh bin/install-plugin.sh`：仅向 `~/.config/omarchy/plugins/xianbei233.razer-control` 安装插件；备份后合并 `shell.json` 内 `plugins[]` 与 `bar.layout.right[]` 对象条目，不会假设独立 `bar.layout` 文件或顶级插件字符串数组，也保留未知字段。不会写入系统目录。可用 `XDG_CONFIG_HOME` 沙箱测试。安装脚本不安装 udev 规则。

默认通过设备权限访问 hidraw。若设备不可访问，可自行审核 `udev/70-omarchy-razer-control.rules`，并由管理员明确手动安装至系统 udev 规则目录、reload/trigger；这会授予当前活动本地用户匹配设备的访问权限。规则不应未经审查自动启用。

## 安全与事实限制

- 设备白名单严格为已发现的 `1532:0270`；HID 报文串行处理并校验状态、校验和、事务匹配和期限。
- 每次写入先保存状态、逐条检查应答，再读回核验；失败/超时结果可能未知，不会自动重放或重试。多个本程序进程由 state 目录 flock 串行化。
- 风扇手动范围必须先经设备验证才解锁；不得把范围当成物理极限。风扇接口返回保留设定值而非转速。
- `verify-fans` 是显式的风扇专用验证：仅操作自动/手动风扇模式和 CPU/GPU 风扇设定值，依次验证 4000、4500、5000、5400 RPM，之后恢复并读回原风扇模式及两个原设定值。仅所有点读回通过且恢复读回确认后才保存 `verified_fan_range=[4000,5400]`。这是协议设定值范围，不代表实测转速或物理极限。失败时停止、保留备份/结果且不解锁；通信超时后的设备状态仍可能未知。
- **电池充电阈值写入已禁用**；电池只读。
- `battery 0|1 LIMIT` 保留兼容 CLI 形状，但命令会拒绝，不会发送电池 SET 报文。
- 不自动恢复/重放先前设置，不依赖 OpenRazer、daemon 或 DKMS，不运行 sudo。
- `verify-hardware` 是可能改变风扇、性能、灯光等设置的显式硬件测试命令；不要将它用于普通测试/安装。硬件写入验证未在本轮执行，也不声称此设备验证通过。发生部分失败时应手动检查设备状态。
- 只需验证风扇范围时使用 `verify-fans`，不要使用会写入多个控制组的 `verify-hardware`。
- 源项目记录的目标设备观测：充电阈值读回不一致；自动风扇读取值可保留手动设定；部分效果参数不可读回。详情见 [协议说明](docs/PROTOCOL.md)。

设置保存在 `${XDG_STATE_HOME:-~/.local/state}/omarchy-razer-control/settings.json`（权限 0600）。
