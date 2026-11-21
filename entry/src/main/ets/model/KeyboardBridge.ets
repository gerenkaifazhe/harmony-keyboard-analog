/**
 * 蓝牙键盘与界面之间的桥。
 *
 * 为什么需要这一层：
 * 1. CardDetail 在页面里有多份实例（飞行层每层一份），而按位订阅的 callback 只允许一个。
 *    这里统一持有唯一回调，把状态写进 AppStorage，各层用 @StorageProp 只读订阅，互不干扰。
 * 2. 把"历史设备 / 已配对设备 / 主动回连设备"整理成可直接渲染的列表。
 */
import { access, connection, constant } from '@kit.ConnectivityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BluetoothKeyboardService, KeyboardServiceState } from '../service/BluetoothKeyboardService';
import { HistoryDevice } from './CardData';
import { DeviceLiveView } from './DeviceLiveView';

const DOMAIN = 0x0000;
// 主动回连设备（只存一个地址，天然满足"只能有一个"）
const KEY_AUTO_RECONNECT = 'auto_reconnect_address';
// 键盘页壁纸的沙箱路径
const KEY_WALLPAPER = 'keyboard_wallpaper_uri';
// 展开卡片背景壁纸的沙箱路径（旧：全局一张，保留兼容读取）
const KEY_CARD_WALLPAPER = 'card_wallpaper_uri';
// 每张卡片各自的壁纸，元素格式 "c2|file://..."
const KEY_CARD_WALLPAPERS = 'card_wallpaper_entries';
// 开启模拟后等 HID 注册生效，再去主动回连，太早会报 App not register
const REGISTER_SETTLE_MS = 800;

export class KeyboardBridge {
  private static instance: KeyboardBridge | null = null;
  private service: BluetoothKeyboardService = BluetoothKeyboardService.getInstance();
  private prefs: preferences.Preferences | null = null;
  private autoAddress: string = '';
  private inited: boolean = false;
  // 每张卡片的壁纸，元素格式 "c2|file://..."
  private cardEntries: string[] = [];
  // 本机蓝牙设备名（系统蓝牙名）：首页第一张大卡片的标题用它
  private localName: string = '';
  // 蓝牙开关变化：开着蓝牙才能读到本机名称，关掉后要清空
  private onBtStateChange = (): void => {
    this.refreshLocalName();
  };

  static getInstance(): KeyboardBridge {
    if (!KeyboardBridge.instance) {
      KeyboardBridge.instance = new KeyboardBridge();
    }
    return KeyboardBridge.instance;
  }

  /**
   * Ability 启动时调用一次：加载持久化数据、接管服务回调、把初始状态写进 AppStorage
   */
  init(prefs: preferences.Preferences): void {
    this.prefs = prefs;
    // 多实例启动时 Ability 会重复调用，服务只初始化一次，避免重复注册蓝牙监听
    if (this.inited) {
      this.publish(this.service.getIsConnected());
      return;
    }
    this.inited = true;
    this.service.init(prefs);

    // 本机蓝牙名：要在页面渲染前就准备好，首页第一张大卡片的标题直接取它
    this.refreshLocalName();
    this.watchBluetoothState();

    try {
      const saved = prefs.getSync(KEY_AUTO_RECONNECT, '') as string;
      if (saved.length > 0) {
        this.autoAddress = saved;
        this.service.setPreferredHost(saved);
      }
    } catch (err) {
      hilog.warn(DOMAIN, 'BTKeyboard', '读取主动回连设备失败: %{public}s',
        (err as BusinessError).message);
    }

    // 键盘页壁纸：读回来写进 AppStorage，重启后仍然生效
    try {
      const wallpaper = prefs.getSync(KEY_WALLPAPER, '') as string;
      AppStorage.setOrCreate('wallpaperUri', wallpaper);
      // 每张卡片各自的壁纸（string[] 比 JSON 更稳，不涉及运行时解析）
      const entries = prefs.getSync(KEY_CARD_WALLPAPERS, [] as string[]) as string[];
      this.cardEntries = entries !== undefined && entries !== null ? entries : [];
      AppStorage.setOrCreate('cardWallpaperEntries', this.cardEntries);
    } catch (err) {
      hilog.warn(DOMAIN, 'BTKeyboard', '读取壁纸失败: %{public}s',
        (err as BusinessError).message);
    }

    this.service.setCallback({
      onStateChange: (state: KeyboardServiceState, message?: string) => {
        AppStorage.setOrCreate('btRunning', state === KeyboardServiceState.RUNNING);
        AppStorage.setOrCreate('btStarting', state === KeyboardServiceState.STARTING);
        if (message !== undefined && message.length > 0) {
          AppStorage.setOrCreate('btMessage', message);
        }
        if (state === KeyboardServiceState.STOPPED) {
          AppStorage.setOrCreate('btMessage', '');
        }
        this.publish(this.service.getIsConnected());
      },
      onConnectionChange: (connected: boolean) => {
        this.publish(connected);
      }
    });

    AppStorage.setOrCreate('btRunning', this.service.getState() === KeyboardServiceState.RUNNING);
    AppStorage.setOrCreate('btStarting', this.service.getState() === KeyboardServiceState.STARTING);
    AppStorage.setOrCreate('btMessage', '');
    this.publish(this.service.getIsConnected());
  }

  // ==================== 供界面调用 ====================

  /** 开始模拟蓝牙键盘 */
  async start(): Promise<void> {
    await this.service.start();
    // 走到这里蓝牙权限通常刚授予，本机名称这时才读得到，补一次刷新
    this.refreshLocalName();
    this.publish(this.service.getIsConnected());
  }

  /** 停止模拟 */
  async stop(): Promise<void> {
    await this.service.stop();
    this.publish(false);
  }

  /**
   * 点击历史设备：主动申请回连。
   * 模拟尚未开启时先把它开起来，再把连接请求发出去。
   * @returns 空字符串表示已发起；否则是失败原因
   */
  async connect(address: string): Promise<string> {
    if (address.length === 0) {
      return '设备地址无效';
    }
    if (this.service.getState() !== KeyboardServiceState.RUNNING) {
      await this.service.start();
      await this.wait(REGISTER_SETTLE_MS);
    }
    const message: string = this.service.connectToHost(address);
    this.publish(this.service.getIsConnected());
    return message;
  }

  /**
   * 设置/取消"主动回连"设备。只保留一个：打开新的会顶掉旧的。
   */
  setAutoReconnect(address: string, on: boolean): void {
    this.autoAddress = on ? address : '';
    this.service.setPreferredHost(this.autoAddress);
    if (this.prefs) {
      try {
        this.prefs.putSync(KEY_AUTO_RECONNECT, this.autoAddress);
        this.prefs.flushSync();
      } catch (err) {
        hilog.warn(DOMAIN, 'BTKeyboard', '保存主动回连设备失败: %{public}s',
          (err as BusinessError).message);
      }
    }
    this.publish(this.service.getIsConnected());
  }

  getAutoReconnectAddress(): string {
    return this.autoAddress;
  }

  getIsConnected(): boolean {
    return this.service.getIsConnected();
  }

  /** 手动刷新设备列表（重新读一次已配对设备） */
  refreshDevices(): void {
    this.publish(this.service.getIsConnected());
  }

  /** 设置键盘页壁纸（传空字符串恢复纯色），并持久化 */
  setWallpaper(uri: string): void {
    AppStorage.setOrCreate('wallpaperUri', uri);
    if (this.prefs) {
      try {
        this.prefs.putSync(KEY_WALLPAPER, uri);
        this.prefs.flushSync();
      } catch (err) {
        hilog.warn(DOMAIN, 'BTKeyboard', '保存壁纸失败: %{public}s',
          (err as BusinessError).message);
      }
    }
  }

  /** 设置某张卡片的背景壁纸（传空字符串恢复该卡片原本的渐变） */
  setCardWallpaper(cardId: string, uri: string): void {
    const prefix: string = cardId + '|';
    const next: string[] = this.cardEntries.filter((item: string) => !item.startsWith(prefix));
    if (uri.length > 0) {
      next.push(prefix + uri);
    }
    this.cardEntries = next;
    // 整体替换数组，订阅方才会收到变更
    AppStorage.setOrCreate('cardWallpaperEntries', next);
    if (this.prefs) {
      try {
        this.prefs.putSync(KEY_CARD_WALLPAPERS, next);
        this.prefs.flushSync();
      } catch (err) {
        hilog.warn(DOMAIN, 'BTKeyboard', '保存卡片壁纸失败: %{public}s',
          (err as BusinessError).message);
      }
    }
  }

  /**
   * 读取系统里本机的蓝牙设备名，写进 AppStorage 供首页主卡片标题显示。
   *
   * 名称不写死：来自 connection.getLocalName()，用户在系统设置里改了名字、
   * 或者蓝牙刚被打开，下一次刷新就会跟着变。读不到（蓝牙关闭、权限未授予）
   * 时写空串，界面回退到占位文案，不会顶着上一次的旧名字。
   */
  refreshLocalName(): void {
    let name: string = '';
    try {
      const local: string = connection.getLocalName();
      if (local !== undefined && local !== null) {
        name = local.trim();
      }
    } catch (err) {
      hilog.warn(DOMAIN, 'BTKeyboard', '读取本机蓝牙名称失败: %{public}s',
        (err as BusinessError).message);
    }
    if (name === this.localName) {
      return;
    }
    this.localName = name;
    AppStorage.setOrCreate('btLocalName', name);
  }

  /** 当前连接的主机名；未连接返回空串 */
  getConnectedDeviceName(): string {
    if (!this.service.getIsConnected()) {
      return '';
    }
    const last: string = this.service.getLastHostAddress();
    return last.length > 0 ? this.resolveName(last) : '蓝牙设备';
  }

  /** 从实况窗的「断开连接」按钮进来：停止模拟并收起实况窗 */
  async disconnectFromLiveView(): Promise<void> {
    await this.service.stop();
    this.publish(false);
    await DeviceLiveView.hide();
  }

  /** 应用回前台：HID 注册会被系统回收，需要重新注册并回连 */
  onForeground(): void {
    // 用户可能刚在系统设置里改了设备名或授予了权限，回到前台重新读一次
    this.refreshLocalName();
    this.service.notifyForeground();
  }

  onBackground(): void {
    this.service.notifyBackground();
  }

  destroy(): void {
    try {
      access.off('stateChange', this.onBtStateChange);
    } catch (_) {
      // 未注册成功时忽略
    }
    this.service.destroy();
  }

  // ==================== 内部 ====================

  /** 监听蓝牙开关：应用先启动、用户后开蓝牙时，本机名称要跟着补上 */
  private watchBluetoothState(): void {
    try {
      access.on('stateChange', this.onBtStateChange);
    } catch (err) {
      hilog.warn(DOMAIN, 'BTKeyboard', '监听蓝牙状态失败: %{public}s',
        (err as BusinessError).message);
    }
  }

  private wait(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /** 把当前状态整体推给 AppStorage，界面各层会自动刷新 */
  private publish(connected: boolean): void {
    const last: string = this.service.getLastHostAddress();
    AppStorage.setOrCreate('btConnected', connected);
    AppStorage.setOrCreate('btConnectedAddress', connected ? last : '');
    AppStorage.setOrCreate('btConnectedName',
      connected && last.length > 0 ? this.resolveName(last) : '');
    AppStorage.setOrCreate('btAutoAddress', this.autoAddress);
    const history: HistoryDevice[] = this.buildHistory();
    AppStorage.setOrCreate('btHistoryDevices', history);
    AppStorage.setOrCreate('btMyDevices', this.buildMyDevices(history));
  }

  /**
   * 连接历史：本机作为蓝牙 HID 设备时，被主机连过的记录，最新的在前。
   * 不能混入 getPairedDevices()：那是平板作为中心设备配对的外设，
   * 和 HID 主机的语义完全不同。
   */
  private buildHistory(): HistoryDevice[] {
    const history: string[] = this.service.getHistoryDevices();
    const list: HistoryDevice[] = [];
    for (let i = 0; i < history.length; i++) {
      const addr: string = history[i];
      if (addr === undefined || addr === null || addr.length === 0) {
        continue;
      }
      list.push(new HistoryDevice(addr, this.resolveName(addr), addr === this.autoAddress));
    }
    return list;
  }

  /**
   * 我的设备：平板已配对的设备里，属于电脑 / 手机（平板的 CoD 归在计算机类）的那部分。
   * - 已出现在连接历史里的不再重复展示
   * - 类型识别不出的直接跳过（识别不出就没法保证它是电脑/手机）
   * - 外设类（鼠标、键盘、耳机等）不展示
   */
  private buildMyDevices(history: HistoryDevice[]): HistoryDevice[] {
    let paired: string[] = [];
    try {
      paired = connection.getPairedDevices();
    } catch (err) {
      hilog.warn(DOMAIN, 'BTKeyboard', '读取已配对设备失败: %{public}s',
        (err as BusinessError).message);
      return [];
    }
    const list: HistoryDevice[] = [];
    for (let i = 0; i < paired.length; i++) {
      const addr: string = paired[i];
      if (addr === undefined || addr === null || addr.length === 0) {
        continue;
      }
      if (history.some((item: HistoryDevice) => item.id === addr)) {
        continue;
      }
      if (!this.isComputerOrPhone(addr)) {
        continue;
      }
      list.push(new HistoryDevice(addr, this.resolveName(addr), addr === this.autoAddress));
    }
    return list;
  }

  /** 只保留电脑、手机（平板的 CoD 通常也归在计算机类），其余类型跳过 */
  private isComputerOrPhone(address: string): boolean {
    try {
      const deviceClass: connection.DeviceClass = connection.getRemoteDeviceClass(address);
      return deviceClass.majorClass === constant.MajorClass.MAJOR_COMPUTER
        || deviceClass.majorClass === constant.MajorClass.MAJOR_PHONE;
    } catch (err) {
      return false;
    }
  }

  /** 左滑删除一台设备：清历史、必要时清主动回连，然后整体刷新 */
  removeDevice(address: string): void {
    if (address.length === 0) {
      return;
    }
    this.service.removeHistory(address);
    if (this.autoAddress === address) {
      // 删掉的正好是"主动回连"设备，配置一并清掉
      this.autoAddress = '';
      this.service.setPreferredHost('');
      if (this.prefs) {
        try {
          this.prefs.putSync(KEY_AUTO_RECONNECT, '');
          this.prefs.flushSync();
        } catch (err) {
          hilog.warn(DOMAIN, 'BTKeyboard', '清除主动回连设备失败: %{public}s',
            (err as BusinessError).message);
        }
      }
    }
    this.publish(this.service.getIsConnected());
  }

  /** 查对端设备名；查不到（未配对 / 不在范围内）时回退显示地址 */
  private resolveName(address: string): string {
    try {
      const name: string = connection.getRemoteDeviceName(address);
      if (name !== undefined && name !== null && name.length > 0) {
        return name;
      }
    } catch (err) {
      // 忽略，回退显示地址
    }
    return address;
  }
}
