# EVE 事件监测（macOS）

EVE 事件监测是一款完全本地运行的 macOS 13+ 屏幕事件监测工具。它可以监控指定的屏幕区域或应用窗口，在目标颜色达到设定阈值时发出警报。软件不包含网络请求、服务器、截图历史或上传功能。

EVE Event Monitor is a fully local macOS 13+ SwiftUI app that watches a selected screen region or application window. It alarms when a configured target colour occupies enough pixels. No network code, server, screenshot history, or upload is used.

## 最新版本：v1.6.3（macOS）

新增装备常开监护、分级中文语音、窗口优先的抽屉界面、每角色独立频道配置和独立启停。完整内容见 [v1.6.3 更新说明](releases/v1.6.3.md)。

## Download

Download the latest Apple Silicon installer from [GitHub Releases](https://github.com/mop517945957/eve-event-monitor-macos/releases/latest).

### Windows version

The Windows port is located in `windows/EVEEventMonitor.Windows`. It supports screen-region and application-window monitoring, colour thresholds, image-template matching, repeating alarms, local settings, and live preview. Tagged Windows builds are published as a self-contained 64-bit single-file EXE through GitHub Actions.

## Open and build

1. Open `ScreenAlarm.xcodeproj` in Xcode 15 or newer.
2. Select the **ScreenAlarm** scheme and an Apple Silicon (or Intel) Mac destination.
3. Build and run (`⌘R`).

Command line build (requires full Xcode, not Command Line Tools):

```sh
xcodebuild -project ScreenAlarm.xcodeproj -scheme ScreenAlarm -configuration Debug build
```

## Permissions

The first capture attempt requests **Screen Recording** permission. If it is denied, open **System Settings → Privacy & Security → Screen Recording**, enable Screen Alarm, then restart the app. The app intentionally has no network entitlement.

The optional alarm auto-click feature also requires **Accessibility** permission. Enable it under **System Settings → Privacy & Security → Accessibility**. When an alarm is active and the pointer has not moved for 60 seconds, Screen Alarm clicks the current pointer location once for that alarm.

## Implemented

- Region selection per display, Retina-aware point-to-pixel cropping
- Multi-colour picker with RGB/HEX magnifier and tolerance/area threshold
- ScreenCaptureKit capture pipeline, configurable 50–500 ms detection cadence
- Consecutive-hit/release state machine preventing duplicate alarms
- Default or user-selected WAV/MP3/M4A sound with test playback
- Optional one-time left click when an alarm is active and the mouse has been idle for 60 seconds
- Settings persistence in UserDefaults and Application Support
- Menu-bar controls, background operation, permission UI, and collapsible debug data

## Deliberate first-version limits

- Captured previews are shown after the first live frame, not retained as screenshot history.

## macOS 1.2 多窗口预览

- 在“多窗口预览”中刷新列表，勾选角色（或“全选 EVE”），点击“开启预览”。可显示其他应用用于选择和验证。
- 每个窗口使用独立 ScreenCaptureKit 流，宽度最高 640 像素、最高 10 FPS；原有检测仍使用原来的采集路径和精度。
- 点击预览画面切换到对应窗口，需要辅助功能权限；拖动画面移动、拖动四边或四角自由缩放。按应用与窗口标题保存布局及选择。标题重复或为空时只能按当前窗口 ID 区分，重启游戏后需要重新选择。
- 预览可置顶、跨桌面显示；右键隐藏单个预览，可通过“显示全部预览”恢复；“关闭全部预览”释放预览采集。
- 开启期间每 5 秒刷新窗口列表，并重试失效的采集。重启软件后需手动开启预览，避免未经操作启动多个采集流。
- 当前仍只有一个监控目标；窗口模式触发报警时，对应预览显示红框。没有为每个预览独立创建检测规则。
- 最小化、游戏后台停止渲染、全屏 Space 和多显示器行为需结合真实游戏验证；预览不能保证让暂停渲染的游戏持续刷新。

## macOS 1.2.1 无边框预览

- 移除预览窗口的标题栏和底部状态栏，画面铺满窗口。
- 单击画面切换角色；拖动画面移动；拖动四边或四角自由改变宽高，不锁定比例（画面随窗口拉伸）。最小尺寸 64 × 40 点。
- 右键选择“隐藏此预览”，在主界面“显示全部预览”恢复。
- 主界面透明度滑块支持 0%–80% 透明度，立即应用到全部预览并保存。
- 捕获/切换错误改为主界面错误提示，不再占用底部栏。

## macOS 1.2.2

- 删除“固定样式 / 图标”界面，包括红色/黄色图标截取、样式匹配度和说明。
- 报警仅使用颜色规则；旧模板配置和文件保留以兼容历史版本，但不参与检测。

## macOS 1.2.3 窗口内选区

- 统一在上方列表勾选预览，并点击“设为监控窗口”指定唯一监控目标；移除下方重复窗口选择入口。
- “选择监控区域”打开所选窗口的独立快照，在图像内拖拽并松开确认，Esc 或关闭窗口取消；不再使用桌面全屏框选。
- 选区按窗口图像归一化保存，自动处理缩放和留白，拖出图像的部分会被裁掉。
- 切换目标或重新选区先停止监控，完成后手动重新开始。历史全屏区域不再作为可启动的监控来源；旧配置仍保留。

## macOS 1.2.4

- 窗口列表仅显示标题包含角色名的 EVE 游戏窗口，过滤启动器、空窗口和其他应用。
- 增加预览宽高输入，点击“应用到全部预览”统一调整并保存。新角色预览使用该默认大小，已有角色保留自己的布局；仍支持拖动边缘单独调整。

## macOS 1.2.5 角色设置卡片

- 每个游戏窗口使用独立可折叠卡片，展开后设置该角色的监控区域、宽高和透明度。
- 所有设置按角色分别保存；拖拽缩放同步回该角色尺寸。删除全局尺寸/透明度控件及重复的“监控来源”块。
- “监控此窗口”使用此角色已保存的区域切换当前监控目标；仍一次监控一个窗口。

## macOS 1.2.6

- 各角色的宽度、高度改为滑条配数字输入，双向同步，调整后自动应用和保存，移除“应用大小”按钮。

## macOS 1.2.7 窗口切换

- 按已验证的窗口 ID 和进程 ID 激活目标；辅助功能标题不一致时匹配窗口几何位置，仅有一个游戏窗口的进程可直接激活。
- 恢复窗口、设置主窗口、激活应用并延迟聚焦，随后检查目标是否出现在当前桌面。不会自动修改系统桌面切换设置。
- 无法确认桌面切换成功时显示明确提示，真实全屏 Space 切换仍需现场验证。

## macOS 1.2.8 流畅预览与点击穿透

- 预览默认从 10 FPS 提高到 30 FPS，可选 10/15/30/60 FPS；实际帧率取决于游戏渲染和系统负载，后台停止渲染时不会凭空补帧。
- 默认全局快捷键 Control + Option + L 切换预览锁定，可在界面选择组合键与 L/F6–F12。快捷键冲突会提示并保留原设置。
- 锁定时角色预览及监控区域预览都忽略鼠标，点击穿透到后方应用；主界面和菜单栏保留解锁入口。
- 触发报警自动解锁全部预览；报警持续时禁止重新锁定，报警结束后不自动重新锁定。重启软件默认解锁。

## macOS 1.2.9 崩溃修复

- 修复预览对象销毁时，尚在主线程队列等待的画面未归还信号量导致的崩溃。帧许可独立持有信号量并在释放时归还，不依赖预览对象继续存活。
- 添加 10000 次“回调待处理时先销毁所有者”的回归测试，覆盖提前退出和帧队列限流。

## macOS 1.3.0 一键多窗口监控

- 主按钮及菜单栏统一开始/停止全部窗口监控：重新发现在线角色，恢复各角色保存的选区与预览外观，自动打开对应预览。未配置选区的角色会提示并跳过；无需逐个重设。
- 各窗口独立计算连续命中和解除状态，共用主界面颜色规则；报警声音及自动点击汇总处理，避免多个角色同时触发重复点击。
- 重启后点击“开始全部监控”即可恢复；不会在未经点击时自动启动监控。
- 锁定时顶部持续显示点击穿透提示，解锁和报警自动解锁显示 2.5 秒提示；提示本身不拦截鼠标。

## macOS 1.3.1

- 锁定、解锁及报警自动解锁的浮动提示均在 2.5 秒后消失，隐藏提示不会改变锁定状态。

## macOS 1.3.2 跨桌面持续监控

- 刷新列表时保留仍在运行的游戏进程对应的小窗口和监控，避免切换 Space 期间窗口短暂缺失导致预警自动关闭。
- 监控采集流中断时保留监控任务和检测状态，每 2 秒自动重连，并显示采集中断提示；停止全部监控时取消重连。
- 游戏进程退出后清理对应监控。窗口关闭但进程仍在时保留任务等待恢复，可手动停止；重连期间没有新画面可供检测。
- 自动回归覆盖跨桌面窗口列表暂时为空、返回后去重、进程退出清理；真实游戏跨 Space 操作仍需现场复测。

### 1.4.0：本地频道预警与每角色独立定位

- 软件运行时仅读取 `~/Documents/EVE/logs/Gamelogs` 和 `Chatlogs`，无 ESI、SSO 或位置查询网络请求；日志目录可修改。
- 根据 Gamelogs 的 Listener/收听者和角色 ID 隔离位置，读取中文“从 A 跳到 B”和英文“Jumping from A to B”。窗口标题 `EVE - 角色名` 精确匹配角色，未知/歧义身份不借用其他角色的位置。卡片显示最后一次跳跃时间。
- 首次在后台扫描已有日志恢复位置，之后每 2 秒增量读取。支持 UTF-8、UTF-16、拆分字符/行、日志轮换和同频道多客户端去重。2 秒是软件读取间隔，不是游戏写入延迟保证。
- 只读取玩家自建频道，不读取本地频道；界面勾选要监控的频道，首次发现默认选择 `wc.` 开头的频道。按消息开头完整星系名解析，支持本地化星系名和尾部 `*`；忽略置顶信息及状态询问，`clr / clear / 安全 / 清空` 等清除同频道的对应星系报告。自由文本不可能完全消歧，暂不支持缩写或星系名不在开头的报告。
- 开始全部监控后，对每个有监控区域的在线角色，分别计算其位置到报告星系的普通星门最短跳数。默认 3 跳、报告有效期 5 分钟，均可调整。0 跳仍为黄色预警；只有视觉检测产生红色报警，红色优先。
- 对应预览黄框、角色卡片显示报告/距离、黄色提示音和报警自动解除点击穿透。黄色提示不触发自动点击。关闭报警可静音当前黄色报告，新报告重新提示；停止全部监控关闭黄色提示音和黄框。
- 位置为最后一次日志记录的位置；尚未验证克隆跳跃、虫洞、跳桥等特殊移动是否总能产生相同格式的记录。星图不包含玩家跳桥或动态虫洞；过期或没有报告不等于安全。
- 随包离线地图取自 [CCP 官方静态数据](https://developers.eveonline.com/docs/services/static-data/)，SDE build 3503375（2026-09-10），包含 8,490 个星系和 6,989 条无向星门连接。原始 ZIP SHA-256 和来源记录在 `IntelMap.json`；`scripts/build_intel_map.py <官方 JSONL ZIP>` 可重新生成，不在应用运行时下载。
- 验证：`tests/LocalIntelTests.swift` 覆盖独立角色/距离、0 跳、范围边界、过期、清除、询问、置顶、UTF 分段、追加、轮换、本地频道排除及乱序消息；原有预览回归测试通过。真实本地日志读取通过；未模拟游戏内危险人员或实际触发自动点击。

### 修、抗常开监护（1.5.1）

在主界面「修、抗常开监护」中选择角色、填写装备名称，点击「框选装备」，在窗口快照内框选**一个完整装备按钮及其运行指示**。每件修、主动抗性装备分别设置。

1. 在安全位置关闭该装备，点击「采集关闭」，保持状态 6 秒。
2. 开启该装备，点击「采集开启」，保持状态 6 秒。样本无法区分时会要求重新采样。
3. 全部装备校准后点击「开始装备监护」。它与原有敌情监控独立启停，启动应用不会自动开启。
4. 连续 2 秒确认未开启后发出重复声音，并在浮动提示中列出角色和装备；无法识别或超过 3 秒没有新画面也提醒。可静音当前提醒，恢复开启后再次异常会重新提示。

识别采用两侧及下方环形区域的 RGB 距离、亮度分布和拒绝判定，忽略顶部固定绿条；绿色光晕与白色循环圈均作为运行样本，亮度分布比较允许白圈角度变化，每秒采集约 5 次。画面变化不符合任何一组样本时不判为正常。每件装备可在设置中看到最新裁剪画面和判定结果。布局、UI 缩放或装备变化后需要删除该项并重新框选、采样。未知状态不是确定停转；持续输出相同画面的游戏冻结也不保证能识别。首次使用必须安全验证开关、背景变化和后台窗口表现，不能把合成测试等同于实际 EVE 识别准确率。本功能仅提醒，不点击装备。

1.5.1 修复：关闭采样允许静止画面，仅需一个有效样本；ScreenCaptureKit 明确报告 idle 时沿用上一帧，采集失败或无回调仍报异常。旧样本按新算法重新验证；无法区分时要求重采。框选需紧贴单个装备外圈、图标居中，不可框选多个按钮。三张用户截图覆盖两个装备的关闭、绿圈、白圈状态；仍需实机验证完整运行周期。

1.5.2 修复瞬时不确定误报：已确认的开启状态遇到短暂动画差异时显示「已开启（复核中）」，不响铃；连续关闭证据 2 秒后才报未开启。持续无法确认 5 秒才提醒，采集失效/超过 3 秒无画面仍提醒。加入一分钟交替开启/不确定帧、持续停转和持续未知状态的回归测试。沿用已有样本，无需因本次更新重新采样。

1.5.3 修复已采集却显示待采样：环形比较增加内侧检测带，避免选区留白把真实运行圈排除在外。样本数量与校验状态分别显示：未采样、缺少开启/关闭、两组差异不足、已校准。现有样本启动时重新验证，保留选区与数据。实际保存的两组样本（26/27 帧、25/25 帧）均通过新校验；仍保留差异不足时的拒绝启动保护。

1.5.4：移除装备提醒浮窗。装备提醒改用独立中文语音，每 8 秒最多播报一次，不与敌情报警共用声音；未开启播报「装备未开启，请检查」，不确定及采集异常分别播报对应原因，静音/停止监护会停止语音。关闭判定在图标匹配且两组绿色光晕特征清晰分离时，允许背景亮度小幅变化，同时保留白色循环圈保护。已用用户明确关闭的截图和本机保存样本复现并修正；仍需实机验证其他场景。

1.5.5：修复背景变化导致已关闭装备持续显示无法确认。补充从开启/关闭样本中学习绿色运行光晕位置的检测，仅在关闭基线稳定、典型开启帧可区分且图标匹配时采用。用户确认两件关闭的实时采集中，29 个有效帧均判为关闭；保留未知状态拒绝、2 秒确认、语音与静音行为。未自动改变采样数据。

1.5.6：频道黄色预警改用平缓中文语音「周边有预警情报，请注意安全」，语速 175、重复间隔 12 秒；本地颜色检测红色报警改用急促语音「警报！本地进人了！立即注意」，语速 240、重复间隔 4 秒。每段播报结束后才允许下一次播报。沿用静音、解除及红色优先规则；设置增加两类语音独立试听，共用原报警音量。自定义音频配置保留在存储中，当前预警统一使用语音。

### 1.6.0 窗口优先界面

启动后自动发现 EVE 角色窗口；展开窗口后，使用同级的「监控小窗口」「预警频道」「装备监控」三个抽屉。装备设置自动归属当前窗口，无需重复选择角色。预警频道启用、频道集合、跳数、报告有效期按角色独立保存；首次使用继承旧版设置。日志目录、预览快捷键、帧率、颜色识别与语音放在顶部齿轮「通用设置」。

顶部统一开始/停止监护与静音；菜单栏使用同一套入口。装备只启动当前在线窗口的规则，未配置装备时不阻止频道与本地预警；无本地颜色选区的窗口仍可参与频道预警。监控区域、预览尺寸、透明度和装备样本保留。窗口列表每 5 秒自动刷新。

1.6.1：三个功能抽屉改为整行标题按钮，箭头、标题及右侧空白均可展开/收起，点击高度至少 44 点；展开内容中的输入框、滑块和按钮不触发折叠。

1.6.2：通用设置统一为五个同级抽屉：小窗口与快捷键、预警语音、本地识别规则、报警后自动点击、EVE 日志目录。默认收起，复用整行可点击标题、图标和分隔线样式，保留原设置内容。

1.6.3：每个角色窗口栏增加独立「显示/关闭小窗口」与「开始/停止监护」。单角色监护覆盖对应本地颜色、频道预警和装备规则，停止一个角色不会重启或停止其他角色的装备采集；异步旧采集回调按会话失效。顶部仍控制全部。首次单独显示窗口不会顺带恢复其他已保存选择。
