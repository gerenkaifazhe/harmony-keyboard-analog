/**
 * 蓝牙键盘模拟服务
 *
 * 方案一：Classic Bluetooth HID Device（优先）
 * 方案二：BLE GATT Server HID over GATT（降级方案）
 */
import { hid, access, ble, connection, common as btCommon, constant, baseProfile } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';

// console.info 在真机上不会写入 hilog 缓冲区，必须用 hilog 才能通过 hdc shell hilog 抓到
function logInfo(msg: string): void {
  hilog.info(0x0000, 'BTKeyboard', '%{public}s', msg);
}
function logWarn(msg: string): void {
  hilog.warn(0x0000, 'BTKeyboard', '%{public}s', msg);
}
function logError(msg: string): void {
  hilog.error(0x0000, 'BTKeyboard', '%{public}s', msg);
}

const KEY_LAST_HOST_ADDRESS = 'last_hid_host_address';
// 历史连接过的主机地址列表（用分隔符拼接后存为字符串）
const KEY_HOST_HISTORY = 'hid_host_history';
const HISTORY_SEPARATOR = '|';
const MAX_HISTORY = 5;
// 主动回连的超时时间，超时后清掉半开连接，保持注册等待主机主动连接
const CONNECT_TIMEOUT_MS = 8000;
// 重新配对的超时时间，超时后提示用户手动处理（仅用于本端未配对时的补配对）
const PAIR_TIMEOUT_MS = 15000;

// ============ HID 报告描述符（标准键盘） ============
const HID_KEYBOARD_REPORT_DESCRIPTOR: Uint8Array = new Uint8Array([
  0x05, 0x01, 0x09, 0x06, 0xA1, 0x01,
  0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7,
  0x15, 0x00, 0x25, 0x01, 0x75, 0x01,
  0x95, 0x08, 0x81, 0x02,
  0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
  0x95, 0x06, 0x75, 0x08, 0x15, 0x00,
  0x25, 0x65, 0x05, 0x07, 0x19, 0x00,
  0x29, 0x65, 0x81, 0x00,
  0xC0
]);

// BLE HID Service UUIDs
const HID_SERVICE_UUID = '00001812-0000-1000-8000-00805F9B34FB';
const REPORT_UUID = '00002A4D-0000-1000-8000-00805F9B34FB';
const REPORT_MAP_UUID = '00002A4B-0000-1000-8000-00805F9B34FB';
const HID_INFO_UUID = '00002A4A-0000-1000-8000-00805F9B34FB';
const HID_CONTROL_POINT_UUID = '00002A4C-0000-1000-8000-00805F9B34FB';
const PROTOCOL_MODE_UUID = '00002A4E-0000-1000-8000-00805F9B34FB';
const CCCD_UUID = '00002902-0000-1000-8000-00805F9B34FB';
const REPORT_REF_UUID = '00002908-0000-1000-8000-00805F9B34FB';

export enum KeyboardServiceState {
  STOPPED = 'stopped',
  STARTING = 'starting',
  RUNNING = 'running',
  ERROR = 'error'
}

export enum KeyboardMode {
  CLASSIC_BT = 'classic_bt',
  BLE = 'ble',
  NONE = 'none'
}

export interface KeyboardServiceCallback {
  onStateChange?: (state: KeyboardServiceState, message?: string) => void;
  onConnectionChange?: (connected: boolean) => void;
  onModeChange?: (mode: KeyboardMode) => void;
}

export class BluetoothKeyboardService {
  private static instance: BluetoothKeyboardService | null = null;
  private state: KeyboardServiceState = KeyboardServiceState.STOPPED;
  private callback: KeyboardServiceCallback | null = null;
  private isConnected: boolean = false;
  private activeMode: KeyboardMode = KeyboardMode.NONE;
  private hidProfile: hid.HidDeviceProfile | null = null;
  private gattServer: ble.GattServer | null = null;
  private prefs: preferences.Preferences | null = null;
  private lastHostAddress: string = '';
  // 用户指定"主动回连"的设备地址（为空时回落到 lastHostAddress）
  private preferredHostAddress: string = '';
  private historyAddresses: string[] = [];
  private started: boolean = false;
  private needsRecovery: boolean = false;
  private connecting: boolean = false;
  private connectTimer: number = -1;
  // 正在重新配对的目标地址（空表示没有进行中的配对）
  private pendingPairAddress: string = '';
  // 重新配对的超时定时器
  private pairTimer: number = -1;

  private constructor() {
  }

  /**
   * 单例：Index 页面与 EntryAbility 共用同一实例，保证关闭应用时能统一注销
   */
  static getInstance(): BluetoothKeyboardService {
    if (!BluetoothKeyboardService.instance) {
      BluetoothKeyboardService.instance = new BluetoothKeyboardService();
    }
    return BluetoothKeyboardService.instance;
  }

  /**
   * 初始化持久化存储，加载上次连接过的主机地址
   */
  init(prefs: preferences.Preferences): void {
    this.prefs = prefs;
    connection.on('bondStateChange', (data: connection.BondStateParam) => {
      this.handleBondStateChange(data);
    });
    try {
      const saved = prefs.getSync(KEY_LAST_HOST_ADDRESS, '') as string;
      if (saved.length > 0) {
        this.lastHostAddress = saved;
        logInfo(`[BTKeyboard] 已加载上次连接的主机: ${saved}`);
      }

      const savedHistory = prefs.getSync(KEY_HOST_HISTORY, '') as string;
      if (savedHistory.length > 0) {
        this.historyAddresses = savedHistory.split(HISTORY_SEPARATOR)
          .filter((item: string) => item.length > 0);
      }
    } catch (err) {
      logWarn(`[BTKeyboard] 读取持久化数据失败: ${(err as BusinessError).message}`);
    }
    if (this.lastHostAddress.length > 0 &&
      this.historyAddresses.indexOf(this.lastHostAddress) < 0) {
      this.recordHistory(this.lastHostAddress);
    }
  }

  /**
   * 获取历史连接过的主机地址列表（最新的在前）
   */
  getHistoryDevices(): string[] {
    return this.historyAddresses;
  }

  getLastHostAddress(): string {
    return this.lastHostAddress;
  }

  getState(): KeyboardServiceState { return this.state; }
  getIsConnected(): boolean { return this.isConnected; }
  getActiveMode(): KeyboardMode { return this.activeMode; }

  setCallback(callback: KeyboardServiceCallback): void {
    this.callback = callback;
  }

  /**
   * 指定"主动回连"的目标设备。设置后，注册成功时会优先回连它而不是最后连接过的设备。
   * 传空字符串表示取消指定，回落到 lastHostAddress 的行为。
   */
  setPreferredHost(address: string): void {
    this.preferredHostAddress = address;
    logInfo(`[BTKeyboard] 主动回连目标: ${address.length > 0 ? address : '(未指定)'}`);
  }

  // ==================== 启动 ====================

  async start(): Promise<void> {
    if (this.state === KeyboardServiceState.RUNNING ||
      this.state === KeyboardServiceState.STARTING) {
      return;
    }

    this.started = true;
    this.updateState(KeyboardServiceState.STARTING, '正在启动蓝牙键盘...');

    try {
      // 蓝牙已经开着时这个接口会抛 2900099（Bluetooth switch state is turn on），
      // 不能让它打断整个启动流程，否则永远不会走到 HID 注册
      try {
        access.enableBluetooth();
      } catch (enableErr) {
        logInfo(`[BTKeyboard] enableBluetooth 返回 ${(enableErr as BusinessError).code}，继续注册`);
      }

      const btResult = await this.tryClassicBtHid();
      if (btResult) {
        this.activeMode = KeyboardMode.CLASSIC_BT;
        this.callback?.onModeChange?.(KeyboardMode.CLASSIC_BT);
        this.updateState(KeyboardServiceState.RUNNING, '蓝牙键盘已开放（经典蓝牙），等待连接...');
        return;
      }

      // 名额被占 / 蓝牙没开 / 不在前台这类错误已经给出明确提示，再降级只会把原因盖掉
      if (this.state === KeyboardServiceState.ERROR) {
        return;
      }

      const bleResult = await this.tryBleHid();
      if (bleResult) {
        this.activeMode = KeyboardMode.BLE;
        this.callback?.onModeChange?.(KeyboardMode.BLE);
        this.updateState(KeyboardServiceState.RUNNING, '蓝牙键盘已开放（BLE），等待连接...');
        return;
      }

      this.updateState(KeyboardServiceState.ERROR, '当前设备不支持蓝牙键盘模拟功能');
    } catch (err) {
      const error = err as BusinessError;
      let errorMsg = error.message;
      if (error.code === 201) errorMsg = '权限不足，请在设置中授予蓝牙权限';
      else if (error.code === 801) errorMsg = '当前设备不支持蓝牙键盘模式（硬件限制）';
      logError(`[BTKeyboard] ${error.code}: ${error.message}`);
      this.updateState(KeyboardServiceState.ERROR, `启动失败: ${errorMsg}`);
    }
  }

  // ==================== 停止 ====================

  async stop(): Promise<void> {
    this.started = false;
    this.connecting = false;
    this.pendingPairAddress = '';
    this.clearConnectTimer();
    this.clearPairTimer();
    try {
      if (this.activeMode === KeyboardMode.CLASSIC_BT) this.stopClassicBt();
      else if (this.activeMode === KeyboardMode.BLE) this.stopBle();
    } catch (err) {
      logError(`[BTKeyboard] Stop error: ${err}`);
    } finally {
      this.isConnected = false;
      this.activeMode = KeyboardMode.NONE;
      this.updateState(KeyboardServiceState.STOPPED, '蓝牙键盘已停止');
    }
  }

  // ==================== Classic Bluetooth HID ====================

  private tryClassicBtHid(): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      try {
        // 上一次的注册如果走了异常路径没清掉，会占着自己唯一的名额（2903051），先释放
        this.stopClassicBt();

        const profile = hid.createHidDeviceProfile();
        if (!profile) { resolve(false); return; }
        this.hidProfile = profile;

        // 先订阅连接状态，确保注册后主机的连接/断开都能被感知
        profile.on('connectionStateChange', (data: baseProfile.StateChangeParam) => {
          this.handleConnectionChange(data);
        });

        // 让本机可被主机发现（可连接 + 可发现），duration 0 表示一直保持；
        // 失败不影响注册流程
        try {
          connection.setBluetoothScanMode(
            connection.ScanMode.SCAN_MODE_CONNECTABLE_GENERAL_DISCOVERABLE, 0);
        } catch (_) { /**/ }

        const sdp: hid.HidDeviceSdp = {
          name: 'HarmonyOS Keyboard',
          description: 'HarmonyOS Bluetooth HID Keyboard',
          provider: 'HarmonyOS',
          subclass: hid.Subclass.SUBCLASS_KEYBOARD,
          descriptors: HID_KEYBOARD_REPORT_DESCRIPTOR
        };

        const qos: hid.HidDeviceQos = {
          serviceType: hid.ServiceType.SERVICE_BEST_EFFORT,
          tokenRate: 0, tokenBucketSize: 0, peakBandwidth: 0,
          latency: -1, delayVariation: -1
        };

        resolve(this.registerHid(profile, sdp, qos, false));
      } catch (err) {
        this.reportHidError(err as BusinessError);
        resolve(false);
      }
    });
  }

  /**
   * 注册 HID 设备。
   *
   * 系统同一时间只允许一个应用持有 HID 设备能力，2903051（Any app has been registered）表示
   * 名额已被占用。最常见的原因是本应用上次异常退出（进程被杀、崩溃）留下的残留注册，
   * 所以先 unregister 清掉再重试一次；重试仍失败才是真的被别的应用占着。
   * 801 表示硬件不支持经典 HID，返回 false 交给 BLE 降级，不当成错误。
   */
  private registerHid(profile: hid.HidDeviceProfile, sdp: hid.HidDeviceSdp,
                      qos: hid.HidDeviceQos, isRetry: boolean): boolean {
    try {
      profile.registerHidDevice(sdp, qos, qos, (success: boolean) => {
        logInfo(`[BTKeyboard] HID 注册状态: ${success}`);
        if (success) {
          // 该回调可能晚于注册返回才触发，此时再补一次回连
          this.autoConnectLastHost();
        } else {
          // 切到后台时系统会自动回收注册并回调 false，这不是错误
          logInfo('[BTKeyboard] HID 注册已解除（可能切到后台），回到前台会自动重新注册');
          this.isConnected = false;
          this.callback?.onConnectionChange?.(false);
          this.updateState(KeyboardServiceState.STOPPED, '');
        }
      });

      // registerHidDevice 正常返回即代表注册成功（失败会抛 BusinessError）。
      // 不能等注册回调，否则 UI 会一直停留在“加载中”。
      this.updateState(KeyboardServiceState.RUNNING, '等待主机连接...');
      // 稍延时回连，避免注册尚未完全生效时报 2903052(App not register)
      setTimeout(() => this.autoConnectLastHost(), 500);
      return true;
    } catch (err) {
      const e = err as BusinessError;
      if (e.code === 801) {
        logWarn('[BTKeyboard] 当前设备不支持经典 HID，尝试 BLE 降级');
        return false;
      }
      if (e.code === 2903051 && !isRetry) {
        logWarn('[BTKeyboard] HID 名额被占用(2903051)，清理本应用残留后重试');
        try {
          profile.unregisterHidDevice();
          logInfo('[BTKeyboard] 已清理残留注册');
        } catch (unregErr) {
          logWarn(`[BTKeyboard] 清理残留注册失败: ${(unregErr as BusinessError).code}`);
        }
        return this.registerHid(profile, sdp, qos, true);
      }
      this.reportHidError(e);
      return false;
    }
  }

  /** 把 HID 注册失败的错误码翻译成用户能看懂的话 */
  private reportHidError(e: BusinessError): void {
    logError(`[BTKeyboard] HID 注册失败: ${e.code} ${e.message}`);
    let message: string = `注册蓝牙键盘失败（错误码 ${e.code}）`;
    if (e.code === 2903051) {
      message = 'HID 能力已被占用：多半是上次异常退出的残留，已尝试清理；仍失败请关闭其他模拟键盘应用或重启蓝牙';
    } else if (e.code === 2903050) {
      message = '应用不在前台，请回到应用后再点开始模拟';
    } else if (e.code === 2900003) {
      message = '蓝牙未开启，请先打开蓝牙';
    } else if (e.code === 201) {
      message = '缺少蓝牙权限，请在系统设置中授予后重试';
    } else if (e.code === 2900099) {
      message = '蓝牙操作失败，请重试';
    }
    this.updateState(KeyboardServiceState.ERROR, message);
  }

  /**
   * 处理 HID 主机的连接状态变化
   */
  private handleConnectionChange(data: baseProfile.StateChangeParam): void {
    // 主动停止时 unregisterHidDevice 还会异步回调一次「断开」，
    // 若不拦住，它会把 STOPPED 覆盖回 RUNNING，按钮就会卡在“停止模拟”
    if (!this.started) {
      this.isConnected = false;
      this.callback?.onConnectionChange?.(false);
      logInfo(`[BTKeyboard] 已停止模拟，忽略连接状态回调: ${data.state}`);
      return;
    }

    this.isConnected = data.state === constant.ProfileConnectionState.STATE_CONNECTED;
    this.callback?.onConnectionChange?.(this.isConnected);

    if (this.isConnected) {
      this.clearConnectTimer();
      this.connecting = false;
      if (data.deviceId) this.saveHostAddress(data.deviceId);
      this.updateState(KeyboardServiceState.RUNNING, '已连接到蓝牙键盘');
    } else if (data.state === constant.ProfileConnectionState.STATE_CONNECTING) {
      this.updateState(KeyboardServiceState.RUNNING, '正在连接主机...');
    } else if (data.state === constant.ProfileConnectionState.STATE_DISCONNECTED) {
      logInfo(`[BTKeyboard] 连接断开，原因: ${data.cause}`);
      this.clearConnectTimer();
      this.connecting = false;
      this.updateState(KeyboardServiceState.RUNNING, '等待连接...');
    }
  }

  /**
   * 发送 HID 输入报告（连接成功后可调用，如发送按键）
   */
  sendReport(reportId: number, reportData: Uint8Array): void {
    if (!this.hidProfile || !this.isConnected) {
      logWarn('[BTKeyboard] 未连接主机，忽略报告发送');
      return;
    }
    try {
      this.hidProfile.sendReport(reportId, reportData);
    } catch (err) {
      const e = err as BusinessError;
      logWarn(`[BTKeyboard] 发送报告失败: ${e.code} ${e.message}`);
    }
  }

  private stopClassicBt(): void {
    if (this.hidProfile) {
      try { this.hidProfile.unregisterHidDevice(); } catch (_) { /**/ }
      this.hidProfile = null;
    }
  }

  // ==================== 自动回连与应用生命周期 ====================

  /**
   * 记住连接成功的主机地址（持久化，下次打开应用自动回连）
   */
  private saveHostAddress(address: string): void {
    this.recordHistory(address);
    if (this.lastHostAddress === address) return;
    this.lastHostAddress = address;
    if (!this.prefs) return;
    try {
      this.prefs.putSync(KEY_LAST_HOST_ADDRESS, address);
      this.prefs.flushSync();
      logInfo(`[BTKeyboard] 已记住连接的主机: ${address}`);
    } catch (err) {
      logWarn(`[BTKeyboard] 保存主机地址失败: ${(err as BusinessError).message}`);
    }
  }

  /**
   * 记录到历史设备列表（去重、最新在前、最多保留 MAX_HISTORY 个）
   */
  private recordHistory(address: string): void {
    if (address.length === 0) return;
    const list: string[] = this.historyAddresses.filter((item: string) => item !== address);
    list.unshift(address);
    this.historyAddresses = list.slice(0, MAX_HISTORY);
    if (!this.prefs) return;
    try {
      this.prefs.putSync(KEY_HOST_HISTORY, this.historyAddresses.join(HISTORY_SEPARATOR));
      this.prefs.flushSync();
    } catch (err) {
      logWarn(`[BTKeyboard] 保存历史设备失败: ${(err as BusinessError).message}`);
    }
  }

  /**
   * 从连接历史中移除一台设备（仅清除应用内记录，不动系统配对）。
   * 若移除的是最近连接的主机，一并清掉 lastHostAddress。
   */
  removeHistory(address: string): void {
    if (address.length === 0) {
      return;
    }
    const list: string[] = this.historyAddresses.filter((item: string) => item !== address);
    if (list.length === this.historyAddresses.length) {
      return;
    }
    this.historyAddresses = list;
    if (!this.prefs) {
      return;
    }
    try {
      this.prefs.putSync(KEY_HOST_HISTORY, this.historyAddresses.join(HISTORY_SEPARATOR));
      if (this.lastHostAddress === address) {
        this.lastHostAddress = '';
        this.prefs.deleteSync(KEY_LAST_HOST_ADDRESS);
      }
      this.prefs.flushSync();
      logInfo(`[BTKeyboard] 已从历史移除设备: ${address}`);
    } catch (err) {
      logWarn(`[BTKeyboard] 移除历史设备失败: ${(err as BusinessError).message}`);
    }
  }

  /**
   * 主动连接指定的历史设备（点击历史设备列表时调用）
   * @returns 空字符串表示已发起连接；否则返回失败原因
   */
  connectToHost(address: string): string {
    if (!this.hidProfile || this.state !== KeyboardServiceState.RUNNING) {
      logWarn('[BTKeyboard] HID 尚未注册，无法发起连接');
      return '键盘模拟尚未就绪，请先开启';
    }
    if (address.length === 0) return '设备地址无效';

    // 本端配对记录失效时，先补配对再回连，而不是直接放弃
    if (!this.isPaired(address)) {
      this.lastHostAddress = address;
      this.startPairing(address);
      return '该设备未处于配对状态，正在重新配对，请在电脑端确认配对';
    }

    const wasConnected: boolean = this.isConnected;
    if (wasConnected) {
      const profile = this.hidProfile;
      try { profile.disconnect(); } catch (_) { /**/ }
      this.isConnected = false;
      this.callback?.onConnectionChange?.(false);
      this.clearConnectTimer();
    }

    this.connecting = false;
    this.saveHostAddress(address);
    this.updateState(KeyboardServiceState.RUNNING, '正在连接主机...');

    if (wasConnected) {
      // 刚断开时稍等再连，避免底层状态未清理干净
      setTimeout(() => this.autoConnectLastHost(address), 500);
    } else {
      this.autoConnectLastHost(address);
    }
    return '';
  }

  /**
   * 判断该地址是否仍处于已配对状态。
   * 未配对说明本端链路密钥已失效，需要先补配对再回连。
   */
  private isPaired(address: string): boolean {
    try {
      return connection.getPairState(address) === connection.BondState.BOND_STATE_BONDED;
    } catch (err) {
      const e = err as BusinessError;
      logWarn(`[BTKeyboard] 查询配对状态失败: ${e.code} ${e.message}`);
      return false;
    }
  }

  /**
   * 主动发起连接。
   * 只有两种情况才会连：手动点了某台设备（target），或用户打开了它的「主动回连」（preferred）。
   * 两者都没有时（比如只是开过模拟、连过一次），不会去连上次的设备，只等主机自己连过来。
   */
  private autoConnectLastHost(target?: string): void {
    let host: string = target !== undefined ? target : '';
    if (host.length === 0) {
      host = this.preferredHostAddress;
    }
    if (host.length === 0 || !this.hidProfile) return;
    // 记录当前目标，连接成功后会以它为准显示/持久化
    this.lastHostAddress = host;
    if (this.isConnected || this.connecting) return;
    if (this.pendingPairAddress.length > 0) return;

    // 只回连已配对设备；本端配对记录失效时先补配对，配对成功后再回连
    const paired: boolean = this.isPaired(this.lastHostAddress);
    logInfo(`[BTKeyboard] 回连目标: ${this.lastHostAddress}, 配对状态: ${paired ? '已配对' : '未配对'}`);
    if (!paired) {
      this.startPairing(this.lastHostAddress);
      return;
    }

    this.connecting = true;
    const profile = this.hidProfile;
    // connectionStateChange 上报的是对端虚拟 MAC 地址，必须按 VIRTUAL 连接，
    // 按 REAL 连接会出现 ACL 已通、HID Profile 一直停留在 CONNECTING 的现象。
    const sent = this.tryConnect(profile, btCommon.BluetoothAddressType.VIRTUAL)
      || this.tryConnect(profile, btCommon.BluetoothAddressType.REAL);
    if (!sent) {
      this.connecting = false;
      this.updateState(KeyboardServiceState.RUNNING, '等待连接...');
      return;
    }

    // 回连超时兜底：卡在 CONNECTING 大概率是两端链路密钥不同步（持久性故障）。
    // 对已配对设备调用 pairDevice 会被系统静默忽略（无 bondStateChange 回调），
    // 循环重试 connect 也无意义，因此只清掉半开连接，保持注册等待主机主动连接。
    this.clearConnectTimer();
    this.connectTimer = setTimeout(() => {
      this.connectTimer = -1;
      if (this.isConnected) return;
      this.connecting = false;
      const current = this.hidProfile;
      if (current) {
        // 清掉半开的连接（HidDeviceProfile.disconnect 为无参接口）
        try { current.disconnect(); } catch (_) { /**/ }
      }
      logWarn('[BTKeyboard] 回连超时，保持注册等待主机主动连接');
      this.updateState(KeyboardServiceState.RUNNING,
        '回连超时，请在电脑端删除本设备后点击历史设备重连');
    }, CONNECT_TIMEOUT_MS);
  }

  /**
   * 以指定地址类型发起连接，返回是否成功发出请求
   */
  private tryConnect(profile: hid.HidDeviceProfile, addressType: btCommon.BluetoothAddressType): boolean {
    const typeText = addressType === btCommon.BluetoothAddressType.VIRTUAL ? '虚拟' : '实际';
    const hostAddress: btCommon.BluetoothAddress = {
      address: this.lastHostAddress,
      addressType: addressType
    };
    try {
      profile.connect(hostAddress);
      logInfo(`[BTKeyboard] 已发起回连（${typeText}地址）: ${this.lastHostAddress}`);
      return true;
    } catch (err) {
      const e = err as BusinessError;
      logWarn(`[BTKeyboard] 回连失败（${typeText}地址）: ${e.code} ${e.message}`);
      return false;
    }
  }

  /**
   * 本端配对记录失效时主动补配对，成功后由 bondStateChange 回调触发回连
   */
  private startPairing(address: string): void {
    if (this.pendingPairAddress.length > 0) {
      logInfo(`[BTKeyboard] 已有进行中的配对: ${this.pendingPairAddress}`);
      return;
    }
    this.pendingPairAddress = address;
    this.updateState(KeyboardServiceState.RUNNING, '正在重新配对...');
    logInfo(`[BTKeyboard] 发起重新配对: ${address}`);
    connection.pairDevice(address).catch((err: BusinessError) => {
      logWarn(`[BTKeyboard] 发起配对失败: ${err.code} ${err.message}`);
      this.clearPairTimer();
      this.pendingPairAddress = '';
      this.updateState(KeyboardServiceState.ERROR,
        '配对发起失败，请在电脑端删除本设备后重新连接');
      return;
    });
    // 配对超时保护：系统对已配对设备可能静默忽略配对请求，避免 UI 永远停留
    this.clearPairTimer();
    this.pairTimer = setTimeout(() => {
      this.pairTimer = -1;
      if (this.pendingPairAddress.length === 0) return;
      logWarn('[BTKeyboard] 重新配对超时，未收到配对结果');
      this.pendingPairAddress = '';
      this.updateState(KeyboardServiceState.RUNNING,
        '重新配对未响应，请在电脑端删除本设备后重连');
    }, PAIR_TIMEOUT_MS);
  }

  private clearPairTimer(): void {
    if (this.pairTimer !== -1) {
      clearTimeout(this.pairTimer);
      this.pairTimer = -1;
    }
  }

  /**
   * 配对状态变化：成功则回连，失败则给出明确原因
   */
  private handleBondStateChange(data: connection.BondStateParam): void {
    if (this.pendingPairAddress.length === 0 || data.deviceId !== this.pendingPairAddress) {
      return;
    }
    if (data.state === connection.BondState.BOND_STATE_BONDED) {
      logInfo('[BTKeyboard] 重新配对成功，开始回连主机');
      this.clearPairTimer();
      const target: string = this.pendingPairAddress;
      this.pendingPairAddress = '';
      this.connecting = false;
      this.autoConnectLastHost(target);
      return;
    }
    if (data.state === connection.BondState.BOND_STATE_INVALID) {
      this.clearPairTimer();
      this.pendingPairAddress = '';
      this.connecting = false;
      const cause = data.cause;
      if (cause === connection.UnbondCause.AUTH_FAILURE ||
        cause === connection.UnbondCause.AUTH_REJECTED) {
        logWarn('[BTKeyboard] 两端密钥不一致，配对被拒绝');
        this.updateState(KeyboardServiceState.ERROR,
          '两端配对密钥不同步，请在电脑端删除本设备后重新打开应用');
      } else if (cause === connection.UnbondCause.REMOTE_DEVICE_DOWN) {
        this.updateState(KeyboardServiceState.ERROR, '电脑端蓝牙未开启或不在连接范围内');
      } else if (cause === connection.UnbondCause.USER_REMOVED) {
        this.updateState(KeyboardServiceState.ERROR, '设备已在电脑端被移除，请重新配对');
      } else {
        this.updateState(KeyboardServiceState.ERROR, `配对失败，原因码: ${cause}`);
      }
    }
  }

  private clearConnectTimer(): void {
    if (this.connectTimer !== -1) {
      clearTimeout(this.connectTimer);
      this.connectTimer = -1;
    }
  }

  /**
   * 应用退到后台：系统会自动取消 HID 注册，此处仅记录恢复标记
   */
  notifyBackground(): void {
    if (!this.started) {
      return;
    }
    this.needsRecovery = true;
    // 不要在这里注销 HID：后台要靠实况窗展示"已连接"，注销就等于断了。
    // 系统会在后台回收注册，回到前台由 notifyForeground 重新注册即可。
    logInfo('[BTKeyboard] 退到后台，保持 HID 注册供实况窗展示');
  }

  /**
   * 应用回到前台：若模拟处于开启状态，重新注册并自动回连上次的主机
   */
  notifyForeground(): void {
    if (!this.needsRecovery || !this.started) {
      this.needsRecovery = false;
      return;
    }
    this.needsRecovery = false;
    logInfo('[BTKeyboard] 应用回到前台，重新注册并回连');
    this.stop().then(() => {
      this.start();
    });
  }

  // ==================== BLE HID over GATT ====================

  private tryBleHid(): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      try {
        const server = ble.createGattServer();
        if (!server) { resolve(false); return; }
        this.gattServer = server;

        server.on('connectionStateChange', (data: ble.BLEConnectionChangeState) => {
          this.isConnected = data.state === 2;
          this.callback?.onConnectionChange?.(this.isConnected);
          this.updateState(KeyboardServiceState.RUNNING,
            this.isConnected ? '已连接到蓝牙键盘（BLE）' : '等待连接（BLE）...');
        });

        const hidService: ble.GattService = {
          serviceUuid: HID_SERVICE_UUID,
          isPrimary: true,
          characteristics: this.buildBleCharacteristics()
        };

        server.addService(hidService);

        // 广播数据：只声明 HID 服务 UUID
        const advData: ble.AdvertiseData = {
          serviceUuids: [HID_SERVICE_UUID],
          manufactureData: [],
          serviceData: []
        };

        const advResponse: ble.AdvertiseData = {
          serviceUuids: [],
          manufactureData: [],
          serviceData: []
        };

        const setting: ble.AdvertiseSetting = {
          interval: 160,
          txPower: 0,
          connectable: true
        };

        ble.startAdvertising(setting, advData, advResponse);
        logInfo('[BTKeyboard] BLE HID advertising started');
        resolve(true);
      } catch (err) {
        logWarn(`[BTKeyboard] BLE HID unavailable: ${(err as BusinessError).code}`);
        resolve(false);
      }
    });
  }

  /**
   * 构建 HID over GATT 特征值
   */
  private buildBleCharacteristics(): ble.BLECharacteristic[] {
    // 1. HID Information (0x2A4A)
    const hidInfo: ble.BLECharacteristic = {
      serviceUuid: HID_SERVICE_UUID,
      characteristicUuid: HID_INFO_UUID,
      characteristicValue: new Uint8Array([0x11, 0x01, 0x00, 0x01]),
      descriptors: []
    };

    // 2. Report Map (0x2A4B)
    const reportMap: ble.BLECharacteristic = {
      serviceUuid: HID_SERVICE_UUID,
      characteristicUuid: REPORT_MAP_UUID,
      characteristicValue: HID_KEYBOARD_REPORT_DESCRIPTOR,
      descriptors: []
    };

    // 3. Protocol Mode (0x2A4E)
    const protocolMode: ble.BLECharacteristic = {
      serviceUuid: HID_SERVICE_UUID,
      characteristicUuid: PROTOCOL_MODE_UUID,
      characteristicValue: new Uint8Array([0x01]),
      descriptors: []
    };

    // 4. HID Control Point (0x2A4C)
    const controlPoint: ble.BLECharacteristic = {
      serviceUuid: HID_SERVICE_UUID,
      characteristicUuid: HID_CONTROL_POINT_UUID,
      characteristicValue: new Uint8Array(0),
      descriptors: []
    };

    // 5. Report (0x2A4D) - 键盘输入报告
    const reportRef: ble.BLEDescriptor = {
      serviceUuid: HID_SERVICE_UUID,
      characteristicUuid: REPORT_UUID,
      descriptorUuid: REPORT_REF_UUID,
      descriptorValue: new Uint8Array([0x00, 0x01])
    };

    const cccd: ble.BLEDescriptor = {
      serviceUuid: HID_SERVICE_UUID,
      characteristicUuid: REPORT_UUID,
      descriptorUuid: CCCD_UUID,
      descriptorValue: new Uint8Array([0x00, 0x00])
    };

    const report: ble.BLECharacteristic = {
      serviceUuid: HID_SERVICE_UUID,
      characteristicUuid: REPORT_UUID,
      characteristicValue: new Uint8Array(8),
      descriptors: [cccd, reportRef]
    };

    return [hidInfo, reportMap, protocolMode, controlPoint, report];
  }

  private stopBle(): void {
    try { ble.stopAdvertising(); } catch (_) { /**/ }
    if (this.gattServer) {
      try { this.gattServer.removeAllServices(); } catch (_) { /**/ }
      this.gattServer = null;
    }
  }

  // ==================== 工具方法 ====================

  private updateState(state: KeyboardServiceState, message?: string): void {
    this.state = state;
    this.callback?.onStateChange?.(state, message);
  }

  destroy(): void {
    this.started = false;
    this.needsRecovery = false;
    this.connecting = false;
    this.pendingPairAddress = '';
    this.preferredHostAddress = '';
    this.clearConnectTimer();
    this.clearPairTimer();
    try { connection.off('bondStateChange'); } catch (_) { /**/ }
    if (this.state === KeyboardServiceState.RUNNING) {
      this.stop();
    } else {
      // 状态不是 RUNNING 也做兜底清理，确保注销模拟、释放蓝牙资源
      this.stopClassicBt();
      this.stopBle();
      this.isConnected = false;
      this.activeMode = KeyboardMode.NONE;
    }
    this.callback = null;
  }
}
