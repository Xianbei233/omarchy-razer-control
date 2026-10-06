# 协议与来源

本文事实限制由源项目文档保留。该实现独立编写；本分支禁用电池写入。

本项目独立实现 Rust 代码，没有复制 RazerControl 或 OpenRazer 的实现。

2026-09-07 核对：RazerControl main 文件树没有 LICENSE 文件，其 package.json
中的元数据不能替代明确的源代码授权。因此只参考硬件命令事实和功能行为。
OpenRazer 仅作为协议交叉核对来源，不作为运行时或 DKMS 依赖。

- RazerControl：https://github.com/Razer-Linux/RazerControl
- 报文：https://github.com/Razer-Linux/RazerControl/blob/main/src/services/RazerPacket.js
- 功能参数：https://github.com/Razer-Linux/RazerControl/tree/main/src/components
- 校验：https://github.com/openrazer/openrazer/blob/master/driver/razercommon.c
- Blade 亮度：https://github.com/openrazer/openrazer/blob/master/driver/razerchromacommon.c

## 报文

Linux hidraw feature report 共 91 字节，包含 report ID 0。后续 90 字节是
Razer 报文。事务 ID 使用 0x1f，请求串行执行。

| 含 report ID 的索引 | 含义 |
| --- | --- |
| 0 | HID report ID，0 |
| 1 | 状态，成功响应为 2 |
| 2 | 事务 ID |
| 3–5 | 剩余报文数和协议类型，当前均为 0 |
| 6 | 数据长度，最多 80 |
| 7–8 | 命令类和命令 ID |
| 9–88 | 参数 |
| 89 | 索引 3 到 88 的 XOR |
| 90 | 保留，0 |

WebHID receiveFeatureReport 返回值的索引与 Linux 含 report ID 的缓冲区不同。
这里统一在 HID 层去掉头部，对业务层只暴露参数。

## 能力清单

| 能力 | 类 | 读 / 写 | 参数 |
| --- | --- | --- | --- |
| 风扇 / 性能模式 | 0d | 82 / 02 | 00 01 performance manual |
| CPU/GPU 风扇 | 0d | 81 / 01 | 00 device rpm/100 |
| CPU/GPU 自定义档位 | 0d | 87 / 07 | 00 device level |
| 充电限制 | 07 | 92 / 12 | 仅 GET 读取；SET 写入禁用 |
| Logo 开关 | 03 | 80 / 00 | 01 04 enabled |
| Logo 灯效 | 03 | 82 / 02 | 01 04 mode（0 常亮，2 呼吸） |
| 键盘灯效 | 03 | 8a / 0a | 80 字节灯效参数 |
| Blade 键盘亮度 | 0e | 84 / 04 | 01 brightness（0–255） |

device：1 CPU，2 GPU。CPU 档位 0–3，GPU 档位 0–2。
键盘灯效：0 关闭，1 波浪，2 响应，4 光谱，6 静态，19(hex) 星光。
星光返回模式可能与设置模式不同，必须以本机验证为准。

上游缺口：静音/均衡模式未实现；键盘呼吸灯、双颜色和随机星光仍有 TODO。
界面明确标识这些功能未验证，不猜测报文，不返回虚假成功。

## 数据和恢复语义

GET 0d/81 返回保留的手动设定值，自动模式下不会因此清零，不能用于实时测速。
API 字段为 `target_rpm`、`kind=manual_setpoint`，`actual_rpm=null`；移除了含糊的
`rpm` 字段。面板显示实时转速不可用，将手动设定值单独列出。手动范围只有通过本机
写入和读回验证后才解锁；验证范围不代表硬件的物理极限。

每次允许的主动写入先保存原状态，检查每个应答，再用 GET 命令读回并比对。电池写入与包含电池变更的验证恢复均禁用；恢复会先只读比对电池，若与备份不同则在发送任何恢复写入前拒绝。
部分失败或超时不会自动重试写入。CLI 返回非零和 JSON 错误；面板保留错误。
读取失败时不使用本地设置冒充当前设备值。

每次显式请求重新发现设备并重新打开 HID。仅在打开面板或手动刷新时读取，
操作成功后直接使用后端读回状态；没有定时轮询、启动读取或后台重连探测。
断连或休眠后，需要重新打开面板或手动刷新才会更新状态。
跨进程 flock 防止本项目的多个调用交错。它无法协调不使用同一锁的网页或
其他 HID 程序，因此验收和日常使用时应关闭其他硬件控制程序。

外层进程给硬件工作进程设置截止时间；内核 ioctl 阻塞时结束工作进程。
如果内核暂时不可中断，工作进程退出前仍持有锁，后续请求返回忙。

设置与备份：`${XDG_STATE_HOME:-~/.local/state}/omarchy-razer-control/settings.json`，
权限 0600，原子替换。不存在启动时自动回放设置的逻辑。
