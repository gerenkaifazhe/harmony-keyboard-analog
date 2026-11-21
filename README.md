# 灵感卡片 · HarmonyOS 卡片交互与蓝牙键盘模拟

一个 HarmonyOS（ArkTS / ArkUI）平板应用示例：左侧是卡片瀑布，点一张卡片它会**从原位置飞到右侧画布展开**；其中「蓝牙键盘」卡片可以把平板变成一只**标准蓝牙 HID 键盘**，给电脑、平板或手机打字。

主界面同时演示了 HarmonyOS 官方的**沉浸光感材质（systemMaterial）**、**沉浸渐变模糊标题栏**与**悬浮胶囊底栏**。

---

## 功能特性

### 卡片主页

- 9 张渐变卡片：首行通栏大卡 + 其余两列排布，左侧列表可滚动，右侧是固定不动的「详情画布」。
- **飞行动画**：点击缩略卡，卡片从瓦片位置飞到右侧画布（460ms 贝塞尔曲线），内容分「缩略态退场 → 详情态登场」两段淡入淡出；再次点击原位置即可收回。
- 卡片可单独设置背景壁纸，缩略态与展开态共用同一张图与同色蒙版，保证白字可读。
- 底部是**悬浮胶囊页签**（主页 / 个人），磨砂、投影、点光源全部由系统渲染，内容可以从胶囊底下透出来。

### 蓝牙键盘模拟

- **经典蓝牙 HID Device 优先**：注册标准键盘的 HID Report Descriptor，系统蓝牙列表里会以 `HarmonyOS Keyboard` 出现。
- **BLE HID over GATT 降级**：经典 HID 不可用时（如部分机型返回 `801`），改用 GATT Server 广播 HID 服务（`0x1812`），包含 Report Map、HID Information、Protocol Mode、Control Point 与 Report 特征值。
- 连接历史（最多 5 台，持久化）+ 「我的设备」（系统里已配对的电脑 / 手机，按设备类型过滤）。
- 点设备即可申请回连；「主动回连」全局只允许一台，开机后自动连它。
- 已配对但链路密钥失效时，会先补配对再回连；超时给出可操作提示，而不是一直转圈。

### 键盘页

- 6 行全尺寸键位，按 1u 基准等比排布（整行 15u，随屏宽自适应缩放）。
- 上排三块：**快捷键**（复制 / 粘贴 / 剪切 / 撤销 / 全选 / 保存 / 返回 / 切换 / 确认）、**触控板**（滑动发方向键）、**数字键盘**。
- Shift / Caps 有激活态，字符键会切换上下档；单击 Shift 只影响一个字符。
- 修饰键位图直接拼进 HID 报告的第一个字节，不需要额外粘键逻辑。

### 其他

- **实况窗**：应用退到后台且仍连着设备时，在实况窗显示「当前已连接 XXX」并带「断开连接」按钮；未开通实况窗权益（错误码 `1003500005`）时自动降级成普通通知，功能不丢。
- **个人页**：本机蓝牙名（读系统 `connection.getLocalName()`，随系统改名自动刷新）、连接状态、连接历史数量。

---

## 技术要点

### 1. 一个页面里的四层飞行卡片

卡片从列表飞到画布，如果直接对同一个组件做 `shadow` / `borderRadius` 的属性动画，交接处会出现阴影跳变。这里的做法是把一张卡片拆成**四层独立节点**，全部挂在页面根 `Stack` 上，用 `translate` + 透明度做动画：

| 层 | 作用 | 说明 |
| --- | --- | --- |
| 抬升层 | 展开后的重阴影 | 底色层阴影始终保持缩略图参数，重阴影靠透明度渐入 |
| 背景层 | 渐变 / 壁纸 + 同色蒙版 | 三层同级、全程 `opacity` 不变，收起时不会明暗跳变 |
| 缩略态 | `CardFace` | 与列表里的瓦片像素对齐，起飞瞬间看不出替换 |
| 详情态 | `CardDetail` | 延后 50% 时长才登场，避免两层文字叠在一起发糊 |

同时维护 `activeId`（展开中）与 `exitingId`（收回中）两份状态，点新卡片时先把旧卡片快照到退场层再接管，所以快速连点也不会出现两张卡同时飞。

### 2. systemMaterial 只对部分控件生效

官方沉浸光感材质在**页面内容区**只对 `Toggle` / `Slider` / `Select` 等少数控件生效，`Text`、`Row`、`Button` 一律不渲染。项目里所有需要玻璃质感的元素（标签胶囊、关闭按钮、底部胶囊按钮、每一个键帽）都用 `Toggle(ToggleType.Button)` 承载，只借它的材质能力：

```ts
Toggle({ type: ToggleType.Button, isOn: false }) {
  Text('进入键盘').fontSize(18).fontColor(card.c2)
}
.backgroundColor(Color.Transparent)
.selectedColor(Color.Transparent)
.systemMaterial(new uiMaterial.ImmersiveMaterial({
  style: uiMaterial.ImmersiveStyle.REGULAR,
  applyShadow: true,
  interactive: true,   // 按下形变
  lightEffect: {}      // 触摸光感（仅中高算力设备可见）
}))
```

按键有 48 个，所以键帽统一用 `THIN` 且关掉阴影，避免几十层材质叠加的功耗。

### 3. 标题栏跟着列表滚

`HdsNavigation` 的标题栏绑定 `Scroller`，使用 `ScrollEffectType.IMMERSIVE_GRADIENT_BLUR`，模糊在前 48vp 内吃满；材质类型与强度交给系统按设备能力选档（`MaterialType.ADAPTIVE` / `MaterialLevel.ADAPTIVE`）。

### 4. 状态管理的分工

页面里 `CardDetail` 有多份实例（飞行层每层一份），而按位订阅的回调只允许一个。所以蓝牙状态统一由 `KeyboardBridge` 单例写进 `AppStorage`，各层用 `@StorageProp` 只读订阅：

```
BluetoothKeyboardService（HID 注册 / 连接 / 配对）
        ↓ 回调
KeyboardBridge（整理历史、我的设备、壁纸、回连配置）
        ↓ AppStorage
Index / CardFace / CardDetail / KeyboardPage（@StorageProp 只读）
```

### 5. HID 报告的发送

标准 8 字节键盘报告，第一个字节是修饰键位图（Ctrl `0x01`、Shift `0x02`），第三字节起是用法码。按下后 20ms 发一次全零报告表示抬起：

```ts
const press   = new Uint8Array([modifiers, 0x00, usageId, 0, 0, 0, 0, 0]);
const release = new Uint8Array(8);
this.service.sendReport(0, press);
setTimeout(() => this.service.sendReport(0, release), 20);
```

几个踩过的坑，代码里都有注释：

- HID 设备能力**系统同一时刻只允许一个应用持有**（`2903051`）。上次异常退出会留下残留注册，所以失败时先 `unregisterHidDevice()` 清理再重试一次。
- 应用在后台时注册会被系统回收（`2903050`），回到前台要重新注册并按配置回连。
- 回连要用 `BluetoothAddressType.VIRTUAL`（连接状态回调上报的是对端虚拟地址），按 `REAL` 连会出现 ACL 通了但 Profile 一直停在 `CONNECTING`。
- 对已配对设备调用 `pairDevice` 会被系统静默忽略，所以不能靠「无限重试 connect」解决密钥不同步，只能清掉半开连接等主机主动连。

---

## 项目结构

```
WorkBuddyPageTest/
├── AppScope/                                     应用级配置、名称、图标
├── entry/src/main/ets/
│   ├── entryability/EntryAbility.ets             启动入口：初始化桥接层、沉浸式窗口、前后台与实况窗回调
│   ├── entrybackupability/EntryBackupAbility.ets  备份扩展（模板自带）
│   ├── pages/Index.ets                           主页：卡片网格、飞行动画、浮动底栏、个人页
│   ├── pages/KeyboardPage.ets                    键盘页：快捷键 / 触控板 / 数字键盘 / 主键盘
│   ├── components/CardFace.ets                   卡片缩略态与展开态内容组件
│   ├── model/CardData.ets                        卡片数据模型与示例数据
│   ├── model/KeyboardBridge.ets                  界面与蓝牙服务之间的桥，状态写入 AppStorage
│   ├── model/DeviceLiveView.ets                  实况窗，权益缺失时降级为通知
│   └── service/BluetoothKeyboardService.ets      HID 注册、连接、配对、回连、历史持久化
├── entry/src/main/resources/                     图标、颜色、字符串、页面路由
├── build-profile.json5                           构建配置（签名留空，首次打开时由 IDE 生成）
└── oh-package.json5                              依赖与模型版本
```

主代码 9 个 `.ets` 文件、约 4470 行 ArkTS，另有 4 个测试文件（Hypium）。

---

## 环境要求

| 项 | 版本 / 说明 |
| --- | --- |
| DevEco Studio | 支持 HarmonyOS 6.0 / API 26 的版本 |
| SDK | `targetSdkVersion` 与 `compatibleSdkVersion` 均为 `26.0.0` |
| 设备 | 手机 / 平板 / 2in1（`deviceTypes` 均声明） |
| 运行要求 | 蓝牙键盘模拟**必须真机**，且设备支持 HID Device 能力；模拟器没有蓝牙协议栈，跑不起来 |

### 构建与运行

```bash
# 1. 用 DevEco Studio 打开项目根目录，等待 Sync 完成
# 2. 首次打开会提示配置签名：选择自动签名（Auto Sign），IDE 会生成调试证书并写入 build-profile.json5
# 3. 连接真机，Run 'entry'
```

> 仓库里没有附带 `hvigorw` 包装脚本，请直接用 DevEco Studio 构建；需要命令行构建时，先让 IDE 同步一次（会自动生成 `hvigorw`），再用 `hvigorw assembleHap`。

### 使用蓝牙键盘

1. 主页点「蓝牙键盘」卡片，右侧展开详情。
2. 点「开始模拟」，首次会申请蓝牙权限与通知权限。
3. 在**电脑**上打开蓝牙，搜索并连接 `HarmonyOS Keyboard`。
4. 连上后点「进入键盘」开始打字；也可以点历史设备主动回连。
5. 退到后台仍连着时会显示实况窗，可在上面直接断开。

> 平板上本机蓝牙名称会作为主页第一张大卡片的标题实时显示，读不到时回退成「本机蓝牙设备」。

---

## 权限

| 权限 | 用途 |
| --- | --- |
| `ohos.permission.ACCESS_BLUETOOTH` | 开启蓝牙、注册 HID 设备、查询配对与连接状态 |
| `ohos.permission.DISCOVER_BLUETOOTH` | 让本机可被发现，主机才能在列表里搜到 |
| 通知授权（运行时申请） | 实况窗权益缺失时降级为通知，需要通知权限 |

---

## 已知限制

- 蓝牙键盘依赖系统 HID Device 能力，部分机型只支持 BLE 降级路径，个别机型两者都不支持。
- 系统同一时间只允许一个应用持有 HID 设备能力，与其它模拟键盘应用冲突时需先关闭对方。
- 实况窗需要单独申请权益，未开通时走普通通知降级。
- 除「蓝牙键盘」卡片外的 8 张卡片是**静态示例数据**，用于演示布局与动画，不接真实业务。
- 键盘页的深色主题接口（`setDarkMode`）与自定义壁纸入口已预留，默认未启用。

---

## 说明

- 应用显示名为「灵感卡片」，包名 `com.example.workbuddypagetest`，版本 `1.0.0`。
- 仓库里的 `build-profile.json5` **不含任何签名信息**。首次用 DevEco Studio 打开时会提示自动签名，IDE 生成的 `signingConfigs` 是本机证书路径与加密口令，**请勿再提交**（提交前可用 `git diff` 确认，或把它加入本地 `.git/info/exclude`）。
- 代码中的日志统一走 `hilog`（`console.info` 在真机上不进 hilog 缓冲区），抓日志：`hdc shell hilog | grep BTKeyboard`。
