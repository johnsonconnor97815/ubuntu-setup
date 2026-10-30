# Adv360 Pro 蓝牙连接故障排查记录

## 结果

2026-10-29，Adv360 Pro 键盘在拔掉 USB 后无法输入。重启电脑的蓝牙服务、清除键盘上本机对应档位的旧配对并重新配对后，无线输入恢复。用户确认可以打字；最终检查同时确认 USB 键盘已断开，蓝牙连接和蓝牙键盘输入设备仍存在。

这次观察符合两端配对状态不一致、电脑保留失效连接状态的情况。最初触发原因未确定，不能据此认定为系统升级、驱动故障或键盘硬件损坏。

## 验证环境

- 日期与时区：2026-10-29，America/Los_Angeles，当天为 UTC-07:00。
- 系统：Ubuntu 24.04.5 LTS，x86_64，内核 `6.17.0-1033-oem`。
- 蓝牙软件：BlueZ `5.72-0ubuntu5.8`。
- 蓝牙适配器：Realtek `0bda:8771`，运行时控制器为 `hci1`。
- 键盘：Kinesis Advantage360 Professional，蓝牙名称 `Adv360 Pro`。
- 同时连接的鼠标：`MX Ergo S`。

这里只记录与故障相关的环境和脱敏结果。完整机器清单、设备地址、配对密钥和原始运行日志保留在本机私有目录。

## 故障表现与关键证据

用户确认：键盘插着 USB 可以输入，拔掉 USB 后不能输入。

| 检查项 | 修复前 | 重新配对后 |
| --- | --- | --- |
| 蓝牙服务 | `active / running` | `active / running` |
| 蓝牙开关与屏蔽状态 | `Powered: yes`，软硬件均未屏蔽 | 保持开启 |
| 键盘界面状态 | `Paired: yes`、`Bonded: yes`、`Trusted: yes`、`Connected: yes` | 同样为 `yes` |
| `ServicesResolved` | `false`，服务发现未完成 | `true` |
| 底层实际连接列表 | 只有鼠标，没有键盘 | 鼠标和键盘均存在 |
| 内核键盘输入设备 | 有 USB 键盘，没有蓝牙键盘 | 出现 `Adv360 Pro Keyboard`，`Bus=0005` |
| 拔掉 USB 后输入 | 用户报告不能输入 | 用户确认可以输入，USB 节点已消失 |

`ServicesResolved` 是 BlueZ 的服务发现状态。它为 `true` 表示已完成该阶段，但仍需结合输入设备和实际打字结果判断键盘是否可用。

当天较早的日志中还出现过适配器命令超时、USB 重置，以及 `HID Information read failed`。HID 是键盘、鼠标等输入设备使用的协议。这些旧日志可以作为线索，但不足以解释本次故障的最初原因。

## 实际处理过程

### 先读取状态

先运行仓库的只读检查入口：

```bash
./ubuntu-setup runtime status --format json
./ubuntu-setup capabilities --format json
./ubuntu-setup inspect --format json --no-open
```

运行时检查通过；能力目录版本为 `0.13.0`；系统检查退出码为 `0`，保存了报告。这个退出码只表示报告生成成功。报告中的驱动兼容性、部分配置、更新来源仍有未知项，实际输入最初也未通过用户验证。它们没有被当作蓝牙正常的证据，也没有扩展成系统更新任务。

随后用 `systemctl`、`rfkill`、`bluetoothctl`、`busctl`、`hcitool`、内核输入清单和日志交叉检查。以下命令用变量代替本机设备地址；`KEYBOARD_MAC` 是键盘地址，`KEYBOARD_DEVICE_PATH` 是对应的 BlueZ 对象路径，`HCI_DEVICE` 是实际控制器名：

```bash
systemctl show bluetooth.service --property=ActiveState,SubState
rfkill --output ID,TYPE,DEVICE,SOFT,HARD
bluetoothctl show
bluetoothctl info "$KEYBOARD_MAC"
busctl get-property org.bluez "$KEYBOARD_DEVICE_PATH" org.bluez.Device1 ServicesResolved
hcitool -i "$HCI_DEVICE" con
cat /proc/bus/input/devices
journalctl -b -u bluetooth.service --no-pager
```

本机这些读取命令成功返回。一次批量 `GetManagedObjects` 枚举调用返回退出码 `1`，没有错误文本；后续结论使用成功读取的单设备属性、实际连接列表和内核输入清单。

### 只重连键盘未能恢复

19:04 起，先后对这把键盘执行：

```bash
bluetoothctl --timeout 15 disconnect "$KEYBOARD_MAC"
bluetoothctl --timeout 15 connect "$KEYBOARD_MAC"
```

两条命令的进程退出码都是 `0`，但结果不同：

- 断开命令在等待期间没有给出成功断开提示，读取到的 `Connected` 仍为 `true`；服务日志出现 `Failed to disconnect device: Disconnected (0x0e)`。
- 连接命令输出 `Connection successful`，但 `hcitool` 的实际连接列表里仍只有鼠标，没有键盘，蓝牙键盘输入设备也没有出现。

因此，进程退出码和“连接成功”文本都没有被当作恢复完成。

### 重启蓝牙服务并恢复鼠标

19:05:34 执行：

```bash
sudo -n systemctl restart bluetooth.service
```

命令退出码为 `0`。启动最初短暂出现设备不可用、控制器网络未就绪；等待初始化后，服务恢复 `active / running`，控制器为 `Powered: yes`。

此操作短暂断开了鼠标。随后单独连接 `MX Ergo S`，确认它恢复实际连接、服务发现和蓝牙输入设备。

重启后，键盘变为 `Paired: no`、`Bonded: no`、`Trusted: no`、`Connected: no`。只检查配对文件是否存在，发现电脑此时没有键盘的 `info` 文件，而鼠标文件存在。

本次没有执行电脑端删除配对的命令。重启前没有检查该文件，因此不能确定记录是在何时丢失、未保存，或为何与此前的界面状态不同。

### 第一次重新配对失败

启动交互式配对客户端：

```bash
bluetoothctl --agent KeyboardDisplay
```

在该客户端中执行 `pair <键盘地址>`，键盘短暂连接后断开，返回：

```text
Failed to pair: org.bluez.Error.AuthenticationCanceled
```

此时仍没有蓝牙键盘输入设备，未报告修复成功。

### 清除键盘当前档位的旧配对后重试

用户在键盘上切到本机原先使用的蓝牙档位，按 `Mod + Windows` 清除该档位的旧配对。只处理本机对应档位，未要求清除其他档位。期间 USB 保持连接，供用户输入。

19:08:35 起重新执行配对，返回 `Pairing successful`；随后执行 `trust <键盘地址>`，返回信任设置成功。19:08:43 的内核记录显示创建了蓝牙 HID 设备和 `Adv360 Pro Keyboard` 输入设备。

19:09 检查确认：

- `Paired`、`Bonded`、`Trusted`、`Connected` 均为 `yes`。
- `ServicesResolved=true`。
- 底层实际连接列表中有键盘和鼠标。
- 键盘输入设备为 `Bus=0005`，表示蓝牙输入；此时 USB 输入设备也还存在。
- 电脑已保存键盘配对文件，权限为 `0600`，含配对密钥字段且 `Trusted=true`。检查只输出字段是否存在，未输出密钥内容。

### 拔线验证

用户确认两半电源打开后拔掉左半 USB，并反馈“现在可以了”。19:22:03 再次读取系统状态，确认 USB 键盘输入设备已消失，蓝牙键盘输入设备、实际连接和 `ServicesResolved=true` 均保持。

至此，配对成功、系统识别和实际无线输入三项都有证据。没有再通过重启电脑或重启服务测试持久恢复，也没有进行长时间断连、休眠唤醒或多档位切换测试。

## 原因判断与再次排查时的要点

已确认的问题是：电脑的“已连接”显示与底层实际连接不一致，键盘服务未就绪。重启后读取到的配对记录也与此前界面状态不一致；清除键盘当前档位的旧配对并重新配对后恢复。

这些观察支持“两端配对状态不一致，且电脑保留失效连接状态”的判断，但没有定位最初触发因素。早上的适配器超时、内核版本变化均不能单独证明因果关系。

再次遇到相同表现时，应先检查服务、开关、`ServicesResolved`、实际连接和输入设备，再决定是否重连、重启服务或重新配对。不要只看界面“已连接”，也不要只看命令退出码。

左半键盘插入电脑 USB 时，官方设计会优先把按键发给 USB 主机。插线输入正常不能证明蓝牙正常；无线验收需要拔掉左半 USB，同时确保两半仍有电并已开机。需要重新配对时，只清理确认属于目标电脑的档位。

这些是本次实机处理经验，并未新增仓库的蓝牙自动修复命令，也不构成其他设备或系统版本的兼容性验证。

## 本地资料

原始 HTML 报告和 JSON 记录保留在私有状态目录的 `ubuntu-setup/bluetooth-diagnostics/20261029-190318/` 下；未设置 `XDG_STATE_HOME` 时，其根目录为 `~/.local/state/`。

- `bluetooth-status.html`：面向用户的检查结果与最终处理结论。
- `bluetooth-status.json`：初始蓝牙检查。
- `reconnect-attempt.json`：重连、服务重启、首次配对失败和中间状态。
- `pair-after-keyboard-clear.json`：重新配对、保存检查及拔线输入确认。
- `inspection.json`：仓库检查程序的完整结果。

这些文件未提交到 Git。报告打开请求超时，未确认浏览器显示；这不影响已保存的记录和无线输入验收。

## 官方参考

以下资料于本次排查中核对，适用于说明产品操作和接口含义，不能替代本机验证：

- [Kinesis Advantage360 Pro 支持](https://kinesis-ergo.com/support/kb360pro/)：USB 输入优先；重新配对需处理键盘对应档位和电脑端记录；键盘端清除操作为 `Mod + Windows`。
- [Kinesis Advantage360 Pro 入门](https://kinesis-ergo.com/advantage360-pro-getting-started/)：USB 与蓝牙使用方式、左右半供电及连接关系。
- [BlueZ Device API](https://bluez.readthedocs.io/en/latest/device-api/)：`ServicesResolved` 表示服务发现是否完成。
