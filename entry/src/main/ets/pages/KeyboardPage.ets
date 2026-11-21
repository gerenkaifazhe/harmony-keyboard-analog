/**
 * 键盘页：完全沉浸（隐藏状态栏 + 底部导航条），布局按草图分四块：
 *   上排：快捷键（左） / 触控板（中） / 数字键盘（右）
 *   下排：全尺寸主键盘（键位与间距按 1u 基准等比还原）
 *
 * 背景默认纯白；深色主题与壁纸都留了开关函数，当前不调用。
 */
import { uiMaterial, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { BluetoothKeyboardService } from '../service/BluetoothKeyboardService';
import { KeyboardBridge } from '../model/KeyboardBridge';

// 修饰键（HID report 第一个字节的位）
const MOD_CTRL = 0x01;
const MOD_SHIFT = 0x02;

// 常用用法码
const KEY_ENTER = 0x28;
const KEY_ESC = 0x29;
const KEY_BACKSPACE = 0x2A;
const KEY_TAB = 0x2B;
const KEY_SPACE = 0x2C;
const KEY_UP = 0x52;
const KEY_DOWN = 0x51;
const KEY_LEFT = 0x50;
const KEY_RIGHT = 0x4F;

/**
 * 按键的官方沉浸光感材质：内容区只有 Toggle/Slider/Select 能渲染，
 * 所以按键用 Toggle(ToggleType.Button) 承载。按键数量多（48 个），
 * 用 THIN 且关掉阴影，避免几十层材质叠加的功耗。
 */
const KEY_MATERIAL: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
  style: uiMaterial.ImmersiveStyle.THIN,
  applyShadow: false,
  interactive: true,     // 按下形变反馈（所有算力档可见）
  lightEffect: {}        // 触摸光感（仅高/中算力设备可见，低算力档无视觉差异）
});

/** 一个键位：units 是相对 1u 的宽度，func 为空表示普通字符键 */
class KeyDef {
  label: string;
  shiftLabel: string;
  units: number;
  func: string;

  constructor(label: string, shiftLabel: string, units: number, func: string) {
    this.label = label;
    this.shiftLabel = shiftLabel;
    this.units = units;
    this.func = func;
  }
}

/** 快捷键：一个修饰键组合 */
class ComboDef {
  title: string;
  hint: string;
  mod: number;
  usage: number;

  constructor(title: string, hint: string, mod: number, usage: number) {
    this.title = title;
    this.hint = hint;
    this.mod = mod;
    this.usage = usage;
  }
}

@Entry
@Component
struct KeyboardPage {
  @StorageProp('btConnected') btConnected: boolean = false;
  @StorageProp('btConnectedName') btConnectedName: string = '';
  // 主题与壁纸：默认浅色、无壁纸；壁纸从主页「更换壁纸」写入 AppStorage
  @State dark: boolean = false;
  @StorageLink('wallpaperUri') wallpaperUri: string = '';
  @State shift: boolean = false;
  @State caps: boolean = false;
  // 1u 的实际宽度，随键盘区可用宽度自适应
  @State unit: number = 52;

  private service: BluetoothKeyboardService = BluetoothKeyboardService.getInstance();
  private readonly gap: number = 8;
  private readonly idx3: number[] = [0, 1, 2];
  // 触控板手势
  private lastX: number = 0;
  private lastY: number = 0;
  private lastMoveAt: number = 0;

  // ==================== 键位表（1u 基准，整行合计 15u）====================

  private rowFunc: KeyDef[] = [
    new KeyDef('Esc', 'Esc', 1, 'esc'),
    new KeyDef('F1', 'F1', 1, 'fx'), new KeyDef('F2', 'F2', 1, 'fx'),
    new KeyDef('F3', 'F3', 1, 'fx'), new KeyDef('F4', 'F4', 1, 'fx'),
    new KeyDef('F5', 'F5', 1, 'fx'), new KeyDef('F6', 'F6', 1, 'fx'),
    new KeyDef('F7', 'F7', 1, 'fx'), new KeyDef('F8', 'F8', 1, 'fx'),
    new KeyDef('F9', 'F9', 1, 'fx'), new KeyDef('F10', 'F10', 1, 'fx'),
    new KeyDef('F11', 'F11', 1, 'fx'), new KeyDef('F12', 'F12', 1, 'fx'),
    new KeyDef('PrtSc', 'PrtSc', 1, 'prtsc'), new KeyDef('Del', 'Del', 1, 'del')
  ];

  private rowNumber: KeyDef[] = [
    new KeyDef('`', '~', 1, ''), new KeyDef('1', '!', 1, ''), new KeyDef('2', '@', 1, ''),
    new KeyDef('3', '#', 1, ''), new KeyDef('4', '$', 1, ''), new KeyDef('5', '%', 1, ''),
    new KeyDef('6', '^', 1, ''), new KeyDef('7', '&', 1, ''), new KeyDef('8', '*', 1, ''),
    new KeyDef('9', '(', 1, ''), new KeyDef('0', ')', 1, ''), new KeyDef('-', '_', 1, ''),
    new KeyDef('=', '+', 1, ''), new KeyDef('⌫', '⌫', 2, 'back')
  ];

  private rowTop: KeyDef[] = [
    new KeyDef('Tab', 'Tab', 1.5, 'tab'),
    new KeyDef('q', 'Q', 1, ''), new KeyDef('w', 'W', 1, ''), new KeyDef('e', 'E', 1, ''),
    new KeyDef('r', 'R', 1, ''), new KeyDef('t', 'T', 1, ''), new KeyDef('y', 'Y', 1, ''),
    new KeyDef('u', 'U', 1, ''), new KeyDef('i', 'I', 1, ''), new KeyDef('o', 'O', 1, ''),
    new KeyDef('p', 'P', 1, ''),
    new KeyDef('[', '{', 1, ''), new KeyDef(']', '}', 1, ''), new KeyDef('\\', '|', 1.5, '')
  ];

  private rowHome: KeyDef[] = [
    new KeyDef('Caps', 'Caps', 1.75, 'caps'),
    new KeyDef('a', 'A', 1, ''), new KeyDef('s', 'S', 1, ''), new KeyDef('d', 'D', 1, ''),
    new KeyDef('f', 'F', 1, ''), new KeyDef('g', 'G', 1, ''), new KeyDef('h', 'H', 1, ''),
    new KeyDef('j', 'J', 1, ''), new KeyDef('k', 'K', 1, ''), new KeyDef('l', 'L', 1, ''),
    new KeyDef(';', ':', 1, ''), new KeyDef('\'', '"', 1, ''),
    new KeyDef('Enter', 'Enter', 2.25, 'enter')
  ];

  private rowShift: KeyDef[] = [
    new KeyDef('Shift', 'Shift', 2.25, 'shift'),
    new KeyDef('z', 'Z', 1, ''), new KeyDef('x', 'X', 1, ''), new KeyDef('c', 'C', 1, ''),
    new KeyDef('v', 'V', 1, ''), new KeyDef('b', 'B', 1, ''), new KeyDef('n', 'N', 1, ''),
    new KeyDef('m', 'M', 1, ''),
    new KeyDef(',', '<', 1, ''), new KeyDef('.', '>', 1, ''), new KeyDef('/', '?', 1, ''),
    new KeyDef('Shift', 'Shift', 2.75, 'shift')
  ];

  private rowBottom: KeyDef[] = [
    new KeyDef('Ctrl', 'Ctrl', 1.25, 'ctrl'),
    new KeyDef('Win', 'Win', 1.25, 'win'),
    new KeyDef('Alt', 'Alt', 1.25, 'alt'),
    new KeyDef('', '', 6.25, 'space'),
    new KeyDef('Alt', 'Alt', 1.25, 'alt'),
    new KeyDef('Win', 'Win', 1.25, 'win'),
    new KeyDef('Menu', 'Menu', 1.25, 'menu'),
    new KeyDef('Ctrl', 'Ctrl', 1.25, 'ctrl')
  ];

  // 数字键盘 3 列 x 4 行（最后一行的 0 . ⌫ 单独排）
  private padKeys: string[] = ['7', '8', '9', '4', '5', '6', '1', '2', '3'];

  // 快捷键 3 x 3
  private combos: ComboDef[] = [
    new ComboDef('复制', 'Ctrl C', MOD_CTRL, 0x06),
    new ComboDef('粘贴', 'Ctrl V', MOD_CTRL, 0x19),
    new ComboDef('剪切', 'Ctrl X', MOD_CTRL, 0x1B),
    new ComboDef('撤销', 'Ctrl Z', MOD_CTRL, 0x1D),
    new ComboDef('全选', 'Ctrl A', MOD_CTRL, 0x04),
    new ComboDef('保存', 'Ctrl S', MOD_CTRL, 0x16),
    new ComboDef('返回', 'Esc', 0, KEY_ESC),
    new ComboDef('切换', 'Tab', 0, KEY_TAB),
    new ComboDef('确认', 'Enter', 0, KEY_ENTER)
  ];

  aboutToAppear(): void {
    this.enterImmersive();
  }

  onPageHide(): void {
    this.exitImmersive();
  }

  // ==================== 主题 / 背景（预留）====================

  /** 切换深色主题：已留好接口，当前不调用 */
  setDarkMode(on: boolean): void {
    this.dark = on;
  }

  /** 设置壁纸：传图片 URI 即铺满背景，传空字符串恢复纯色 */
  setWallpaper(uri: string): void {
    KeyboardBridge.getInstance().setWallpaper(uri);
  }

  private pageBackground(): ResourceColor {
    return this.dark ? '#12161D' : '#FFFFFF';
  }

  private panelBackground(): ResourceColor {
    return this.dark ? '#1A2029' : '#FAFBFD';
  }

  private keyBackground(func: boolean): ResourceColor {
    if (this.dark) {
      return func ? '#1E2532' : '#2A3140';
    }
    return func ? '#E9EEF6' : '#F7F9FC';
  }

  /** Shift / Caps 打开时的底色，比普通功能键更明显 */
  private activeKeyBackground(): ResourceColor {
    return this.dark ? '#3C4C6B' : '#CBDCF7';
  }

  /** 功能键的浅灰玻璃底：半透明，叠在光感材质上不会把玻璃盖死 */
  private funcKeyBackground(): ResourceColor {
    return '#80E9EEF6';
  }

  private keyBorderColor(): ResourceColor {
    return this.dark ? '#39414F' : '#DDE3ED';
  }

  private keyTextColor(): ResourceColor {
    return this.dark ? '#F2F5FA' : '#1A2233';
  }

  private subTextColor(): ResourceColor {
    return this.dark ? '#8A94A6' : '#7C8797';
  }

  // ==================== 沉浸式 ====================

  private enterImmersive(): void {
    const ctx = this.getUIContext().getHostContext();
    if (!ctx) {
      return;
    }
    window.getLastWindow(ctx).then((win: window.Window) => {
      // 先进入全屏，系统栏的显隐配置才生效
      win.setWindowLayoutFullScreen(true).then(() => {
        win.setWindowSystemBarEnable([]).catch((e: BusinessError) => {
          console.error('hide system bars failed: ' + JSON.stringify(e));
        });
      }).catch((e: BusinessError) => {
        console.error('setWindowLayoutFullScreen failed: ' + JSON.stringify(e));
      });
    }).catch((e: BusinessError) => {
      console.error('getLastWindow failed: ' + JSON.stringify(e));
    });
  }

  private exitImmersive(): void {
    const ctx = this.getUIContext().getHostContext();
    if (!ctx) {
      return;
    }
    window.getLastWindow(ctx).then((win: window.Window) => {
      win.setWindowSystemBarEnable(['status', 'navigation']).catch((e: BusinessError) => {
        console.error('restore system bars failed: ' + JSON.stringify(e));
      });
    }).catch((e: BusinessError) => {
      console.error('getLastWindow failed: ' + JSON.stringify(e));
    });
  }

  // ==================== 发送 ====================

  private sendKey(usageId: number, modifiers: number): void {
    const press: Uint8Array = new Uint8Array([modifiers, 0x00, usageId, 0, 0, 0, 0, 0]);
    const release: Uint8Array = new Uint8Array(8);
    this.service.sendReport(0, press);
    setTimeout(() => {
      this.service.sendReport(0, release);
    }, 20);
  }

  private ensureConnected(): boolean {
    if (this.btConnected) {
      return true;
    }
    this.getUIContext().getPromptAction().showToast({
      message: '未连接主机，请先在卡片里开始模拟',
      duration: 1600
    });
    return false;
  }

  /** 字符 / 符号到 HID 用法码 */
  private usageOf(label: string): number {
    const lower: string = label.toLowerCase();
    if (lower.length === 1 && lower >= 'a' && lower <= 'z') {
      return lower.charCodeAt(0) - 'a'.charCodeAt(0) + 0x04;
    }
    if (label.length === 1 && label >= '0' && label <= '9') {
      return label === '0' ? 0x27 : label.charCodeAt(0) - 0x31 + 0x1E;
    }
    if (label === '`' || label === '~') {
      return 0x35;
    }
    if (label === '-' || label === '_') {
      return 0x2D;
    }
    if (label === '=' || label === '+') {
      return 0x2E;
    }
    if (label === '[' || label === '{') {
      return 0x2F;
    }
    if (label === ']' || label === '}') {
      return 0x30;
    }
    if (label === '\\' || label === '|') {
      return 0x31;
    }
    if (label === ';' || label === ':') {
      return 0x33;
    }
    if (label === '\'' || label === '"') {
      return 0x34;
    }
    if (label === ',' || label === '<') {
      return 0x36;
    }
    if (label === '.' || label === '>') {
      return 0x37;
    }
    if (label === '/' || label === '?') {
      return 0x38;
    }
    return -1;
  }

  private isLetter(label: string): boolean {
    return label.length === 1 && label >= 'a' && label <= 'z';
  }

  /** Caps 只影响字母，不影响数字和符号 */
  private upperCase(): boolean {
    return this.shift !== this.caps;
  }

  /** 当前应该显示的键帽文字 */
  private displayLabel(key: KeyDef): string {
    if (key.func.length > 0) {
      return key.label;
    }
    if (this.isLetter(key.label)) {
      return this.upperCase() ? key.shiftLabel : key.label;
    }
    return this.shift ? key.shiftLabel : key.label;
  }

  /** 键帽字号：随 1u 宽度缩放，长标签自动缩小 */
  private labelSize(key: KeyDef): number {
    if (key.func === 'fx') {
      return Math.max(10, this.unit * 0.26);
    }
    if (key.func === 'prtsc' || key.func === 'del') {
      return Math.max(9, this.unit * 0.22);
    }
    if (key.label.length <= 1) {
      return Math.max(12, this.unit * 0.44);
    }
    return Math.max(10, this.unit * 0.3);
  }

  private pressKey(key: KeyDef): void {
    const fn: string = key.func;
    if (fn === 'shift') {
      this.shift = !this.shift;
      return;
    }
    if (fn === 'caps') {
      this.caps = !this.caps;
      return;
    }
    if (!this.ensureConnected()) {
      return;
    }

    if (fn === 'back') {
      this.sendKey(KEY_BACKSPACE, 0);
      return;
    }
    if (fn === 'enter') {
      this.sendKey(KEY_ENTER, 0);
      return;
    }
    if (fn === 'space') {
      this.sendKey(KEY_SPACE, 0);
      return;
    }
    if (fn === 'tab') {
      this.sendKey(KEY_TAB, 0);
      return;
    }
    if (fn === 'esc') {
      this.sendKey(KEY_ESC, 0);
      return;
    }
    if (fn === 'fx') {
      // F1..F12 用法码连续：0x3A 起
      const index: number = Number(key.label.substring(1)) - 1;
      this.sendKey(0x3A + index, 0);
      return;
    }
    if (fn === 'prtsc') {
      this.sendKey(0x46, 0);
      return;
    }
    if (fn === 'del') {
      this.sendKey(0x4C, 0);
      return;
    }
    if (fn === 'ctrl' || fn === 'alt' || fn === 'win' || fn === 'menu') {
      // 单独按修饰键没有实际字符，忽略
      return;
    }

    const usage: number = this.usageOf(key.label);
    if (usage < 0) {
      return;
    }
    const needsShift: boolean = this.isLetter(key.label) ? this.upperCase() : this.shift;
    this.sendKey(usage, needsShift ? MOD_SHIFT : 0);
    // 单击 Shift 只影响一个字符
    this.shift = false;
  }

  private pressCombo(combo: ComboDef): void {
    if (!this.ensureConnected()) {
      return;
    }
    this.sendKey(combo.usage, combo.mod);
  }

  private pressPad(label: string): void {
    if (!this.ensureConnected()) {
      return;
    }
    if (label === '⌫') {
      this.sendKey(KEY_BACKSPACE, 0);
      return;
    }
    const usage: number = this.usageOf(label);
    if (usage > 0) {
      this.sendKey(usage, 0);
    }
  }

  // ==================== 触控板 ====================

  private onPadTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.lastX = event.touches[0].x;
      this.lastY = event.touches[0].y;
      this.lastMoveAt = 0;
      return;
    }
    if (event.type !== TouchType.Move) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastMoveAt < 110) {
      return;
    }
    const x: number = event.touches[0].x;
    const y: number = event.touches[0].y;
    const dx: number = x - this.lastX;
    const dy: number = y - this.lastY;
    if (Math.abs(dx) < 14 && Math.abs(dy) < 14) {
      return;
    }
    if (!this.ensureConnected()) {
      return;
    }
    let usage: number = KEY_RIGHT;
    if (Math.abs(dx) > Math.abs(dy)) {
      usage = dx > 0 ? KEY_RIGHT : KEY_LEFT;
    } else {
      usage = dy > 0 ? KEY_DOWN : KEY_UP;
    }
    this.sendKey(usage, 0);
    this.lastX = x;
    this.lastY = y;
    this.lastMoveAt = now;
  }

  // ==================== 组件 ====================

  @Builder
  KeyItem(key: KeyDef) {
    Stack() {
      // Toggle 承载：Button/Stack 在页面内容区不吃 systemMaterial
      Toggle({ type: ToggleType.Button,
        isOn: (key.func === 'shift' && this.shift) || (key.func === 'caps' && this.caps) }) {
        Text(this.displayLabel(key))
          .fontSize(this.labelSize(key))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.keyTextColor())
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .padding({ left: 4, right: 4 })
      }
      .width('100%')
      .height('100%')
      .padding(0)
      .borderRadius(7)
      // 功能键（Enter/Esc/F 区/修饰键/空格等）默认浅灰半透明底，字符键保持纯玻璃
      .backgroundColor(key.func.length > 0 ? this.funcKeyBackground() : Color.Transparent)
      // Shift / Caps 激活时 Toggle 置于开启态，激活底色走 selectedColor；
      // 其它键的内部开合状态不接状态变量，必须透明，否则点击后会卡在高亮
      .selectedColor((key.func === 'shift' || key.func === 'caps') ?
        this.activeKeyBackground() : Color.Transparent)
      .systemMaterial(KEY_MATERIAL)
      .onClick(() => {
        this.pressKey(key);
      })
    }
    .width(key.units * this.unit)
    .height('100%')
    .padding(this.gap / 2)
  }

  @Builder
  KeyRow(keys: KeyDef[], tailUnits: number, weight: number) {
    Row() {
      ForEach(keys, (key: KeyDef) => {
        this.KeyItem(key)
      })
      // 行尾留白，保证每行都是 15u，各行的 1u 才等宽
      if (tailUnits > 0) {
        Column()
          .width(tailUnits * this.unit)
          .height('100%')
      }
    }
    .width(15 * this.unit)
    .layoutWeight(weight)
  }

  @Builder
  KeyGridButton(main: string, sub: string, handler: () => void) {
    // Toggle 承载：Button/Stack 在页面内容区不吃 systemMaterial
    Toggle({ type: ToggleType.Button, isOn: false }) {
      Column({ space: 2 }) {
        Text(main)
          .fontSize(sub.length > 0 ? 15 : 17)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.keyTextColor())
          .maxLines(1)
        if (sub.length > 0) {
          Text(sub)
            .fontSize(10)
            .fontColor(this.subTextColor())
            .maxLines(1)
        }
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .layoutWeight(1)
    .height('100%')
    .padding(0)
    .borderRadius(7)
    .backgroundColor(Color.Transparent)
    .selectedColor(Color.Transparent)
    .systemMaterial(KEY_MATERIAL)
    .onClick(() => {
      handler();
    })
  }

  @Builder
  ShortcutPanel() {
    Column({ space: 8 }) {
      ForEach(this.idx3, (rowIndex: number) => {
        Row({ space: 8 }) {
          ForEach(this.idx3, (colIndex: number) => {
            this.KeyGridButton(
              this.combos[rowIndex * 3 + colIndex].title,
              this.combos[rowIndex * 3 + colIndex].hint,
              () => {
                this.pressCombo(this.combos[rowIndex * 3 + colIndex]);
              })
          }, (colIndex: number) => 'c' + rowIndex + '-' + colIndex)
        }
        .width('100%')
        .layoutWeight(1)
      }, (rowIndex: number) => 'cRow' + rowIndex)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  TouchPad() {
    Column({ space: 4 }) {
      Text('触控板')
        .fontSize(14)
        .fontColor(this.subTextColor())
      Text('滑动发送方向键')
        .fontSize(11)
        .fontColor(this.subTextColor())
        .opacity(0.7)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(10)
    .backgroundColor(this.panelBackground())
    .border({ width: 1, color: this.keyBorderColor() })
    .onTouch((event: TouchEvent) => {
      this.onPadTouch(event);
    })
  }

  @Builder
  PadKey(label: string) {
    // Toggle 承载：Text 在页面内容区不吃 systemMaterial
    Toggle({ type: ToggleType.Button, isOn: false }) {
      Text(label)
        .textAlign(TextAlign.Center)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.keyTextColor())
    }
    .layoutWeight(1)
    .height('100%')
    .padding(0)
    .borderRadius(7)
    // 数字键盘的功能键（⌫）默认浅灰玻璃底
    .backgroundColor(label === '⌫' ? '#80E9EEF6' : Color.Transparent)
    .selectedColor(Color.Transparent)
    .systemMaterial(KEY_MATERIAL)
    .onClick(() => {
      this.pressPad(label);
    })
  }

  @Builder
  NumberPad() {
    Column({ space: 8 }) {
      ForEach(this.idx3, (rowIndex: number) => {
        Row({ space: 8 }) {
          ForEach(this.idx3, (colIndex: number) => {
            this.PadKey(this.padKeys[rowIndex * 3 + colIndex])
          }, (colIndex: number) => 'p' + rowIndex + '-' + colIndex)
        }
        .width('100%')
        .layoutWeight(1)
      }, (rowIndex: number) => 'pRow' + rowIndex)

      Row({ space: 8 }) {
        this.PadKey('0')
        this.PadKey('.')
        this.PadKey('⌫')
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 背景层：纯色 + 可选壁纸（壁纸接口已留，默认不设置）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.pageBackground())

      if (this.wallpaperUri.length > 0) {
        Image(this.wallpaperUri)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
        // 壁纸上的可读性遮罩：浅色下压淡一点，既看得见图又不影响按键阅读
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(this.dark ? '#66000000' : '#33FFFFFF')
      }

      Column() {
        // 顶栏：退出 + 连接状态
        Row() {
          Stack() {
            Text('‹')
              .fontSize(28)
              .fontColor(this.keyTextColor())
              .margin({ bottom: 3 })
          }
          .width(42)
          .height(42)
          .borderRadius(21)
          .backgroundColor(this.panelBackground())
          .border({ width: 1, color: this.keyBorderColor() })
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })

          Blank()

          Row({ space: 7 }) {
            Column()
              .width(8)
              .height(8)
              .borderRadius(4)
              .backgroundColor(this.btConnected ? '#22C55E' : '#B6BFCC')
            Text(this.btConnected ?
              (this.btConnectedName.length > 0 ? this.btConnectedName : '已连接') : '未连接')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.btConnected ? '#15803D' : '#4A5563')
              .maxLines(1)
              .constraintSize({ maxWidth: 240 })
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .padding({ left: 13, right: 13, top: 7, bottom: 7 })
          .borderRadius(16)
          .backgroundColor(this.dark ? '#1A2029' : '#F1F4F8')
          .border({ width: 1, color: this.keyBorderColor() })
        }
        .width('100%')
        .height(42)

        // 上排：快捷键 / 触控板 / 数字键盘
        Row({ space: 14 }) {
          Column() {
            this.ShortcutPanel()
          }
          .layoutWeight(31)
          .height('100%')

          Column() {
            this.TouchPad()
          }
          .layoutWeight(41)
          .height('100%')

          Column() {
            this.NumberPad()
          }
          .layoutWeight(28)
          .height('100%')
        }
        .width('100%')
        .height('26%')
        .margin({ top: 12 })

        // 主键盘：外层量宽度算 1u，内层按 15u 固定宽居中
        Column() {
          Column({ space: this.gap }) {
            this.KeyRow(this.rowFunc, 0, 0.8)
            this.KeyRow(this.rowNumber, 0, 1)
            this.KeyRow(this.rowTop, 0, 1)
            this.KeyRow(this.rowHome, 0, 1)
            this.KeyRow(this.rowShift, 0, 1)
            this.KeyRow(this.rowBottom, 0, 1)
          }
          .width(15 * this.unit)
          .height('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .margin({ top: 14 })
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          const width: number = Number(newArea.width);
          if (!Number.isNaN(width) && width > 0 && Math.abs(width / 15 - this.unit) > 0.5) {
            this.unit = width / 15;
          }
        })
      }
      .width('100%')
      .height('100%')
      .padding({ left: 20, right: 20, top: 14, bottom: 14 })
    }
    .width('100%')
    .height('100%')
  }
}
