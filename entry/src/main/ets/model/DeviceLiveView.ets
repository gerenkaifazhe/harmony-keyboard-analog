/**
 * 实况窗：应用退到后台后，在系统实况窗里显示"当前已连接 XXX"，并带一个「断开连接」按钮。
 *
 * 说明：
 * - 实况窗的场景（event）由系统白名单管理，没有"蓝牙设备连接"这一类，这里用 TIMER
 *   （持续性会话）承载，文案我们自己写。
 * - 实况窗卡片上的按钮只能发起 WantAgent 跳转，不能直接执行代码，所以「断开连接」
 *   的做法是带参数拉起本应用，在 EntryAbility.onNewWant 里执行真正的断开。
 */
import { liveViewManager } from '@kit.LiveViewKit';
import { wantAgent, Want } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const BUNDLE = 'com.example.workbuddypagetest';
const ABILITY = 'EntryAbility';
// 实况窗唯一 id，自己定一个固定值即可
const LIVE_ID = 20261108;
// 持续会话类场景（实况窗场景需要权益，没有设备连接类场景）
const SCENE = 'TIMER';
const ICON = 'keyboard.png';
// 按钮点击后回传的动作参数
export const LIVE_ACTION = 'liveAction';
export const ACTION_DISCONNECT = 'disconnect';

export class DeviceLiveView {
  private static sequence: number = 1;
  private static showing: boolean = false;

  private static nextSequence(): number {
    DeviceLiveView.sequence = DeviceLiveView.sequence >= 2147483646 ? 1 : DeviceLiveView.sequence + 1;
    return DeviceLiveView.sequence;
  }

  static isShowing(): boolean {
    return DeviceLiveView.showing;
  }

  /** 构造可以拉起本应用的 WantAgentInfo（带上动作参数） */
  private static agentInfo(action: string, requestCode: number): wantAgent.WantAgentInfo {
    const info: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: BUNDLE,
          abilityName: ABILITY,
          parameters: {
            liveAction: action
          }
        } as Want
      ],
      actionType: wantAgent.OperationType.START_ABILITIES,
      requestCode: requestCode,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    return info;
  }

  /** 创建实况窗：当前已连接 XXX + 断开连接按钮 */
  static async show(deviceName: string): Promise<void> {
    const name: string = deviceName.length > 0 ? deviceName : '蓝牙设备';
    try {
      const openAgent = await wantAgent.getWantAgent(DeviceLiveView.agentInfo('open', 1001));
      const disconnectAgent =
        await wantAgent.getWantAgent(DeviceLiveView.agentInfo(ACTION_DISCONNECT, 1002));

      const liveView: liveViewManager.LiveView = {
        id: LIVE_ID,
        event: SCENE,
        sequence: DeviceLiveView.nextSequence(),
        isMute: true,
        liveViewData: {
          primary: {
            title: '蓝牙键盘',
            content: [{ text: '当前已连接 ' + name }],
            keepTime: 0,
            clickAction: openAgent,
            extensionData: {
              type: liveViewManager.ExtensionType.EXTENSION_TYPE_COMMON_TEXT,
              text: '键盘模拟中'
            },
            layoutData: {
              layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_PICKUP,
              title: '已连接设备',
              content: name,
              // 强调文本模板的必填项，右侧描述图
              descPic: ICON,
              isServiceButtonsDisplayed: true,
              serviceButtons: [
                {
                  name: '断开连接',
                  clickAction: disconnectAgent
                }
              ]
            }
          },
          capsule: {
            type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT,
            status: 1,
            icon: ICON,
            title: '蓝牙键盘',
            content: '已连接 ' + name,
            // 格式 #ARGB，长度 9
            backgroundColor: '#FF23A183'
          }
        }
      };

      const result: liveViewManager.LiveViewResult = await liveViewManager.startLiveView(liveView);
      DeviceLiveView.showing = true;
      hilog.info(DOMAIN, 'LiveView', 'startLiveView ok: %{public}s', JSON.stringify(result));
    } catch (err) {
      const e = err as BusinessError;
      DeviceLiveView.showing = false;
      hilog.error(DOMAIN, 'LiveView', 'startLiveView failed: %{public}d %{public}s', e.code, e.message);
      // 1003500005 = 实况窗权益未开通。降级成普通通知，功能不至于不可用
      if (e.code === 1003500005) {
        await DeviceLiveView.publishNotice(name);
      }
    }
  }

  /**
   * 降级方案：普通通知，同样带「断开连接」按钮。
   * 通知不依赖实况窗权益，任何应用都能发，只是展示形态不同。
   */
  private static async publishNotice(name: string): Promise<void> {
    try {
      const openAgent = await wantAgent.getWantAgent(DeviceLiveView.agentInfo('open', 1001));
      const disconnectAgent =
        await wantAgent.getWantAgent(DeviceLiveView.agentInfo(ACTION_DISCONNECT, 1002));

      const request: notificationManager.NotificationRequest = {
        id: LIVE_ID,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_LONG_TEXT,
          longText: {
            title: '蓝牙键盘',
            text: '当前已连接 ' + name,
            briefText: '已连接 ' + name,
            expandedTitle: '蓝牙键盘 · 键盘模拟中',
            additionalText: '点「断开连接」可立即断开',
            longText: '当前已连接 ' + name
          }
        },
        actionButtons: [
          {
            title: '断开连接',
            wantAgent: disconnectAgent
          }
        ],
        wantAgent: openAgent
      };
      await notificationManager.publish(request);
      DeviceLiveView.showing = true;
      hilog.info(DOMAIN, 'LiveView', 'fallback notification published');
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, 'LiveView', 'publish notification failed: %{public}d %{public}s',
        e.code, e.message);
    }
  }

  /** 更新实况窗里显示的设备名（切换设备时用） */
  static async update(deviceName: string): Promise<void> {
    if (!DeviceLiveView.showing) {
      return;
    }
    await DeviceLiveView.show(deviceName);
  }

  /** 结束实况窗 */
  static async hide(): Promise<void> {
    if (!DeviceLiveView.showing) {
      return;
    }
    DeviceLiveView.showing = false;
    try {
      const liveView: liveViewManager.LiveView = {
        id: LIVE_ID,
        event: SCENE,
        sequence: DeviceLiveView.nextSequence(),
        liveViewData: {
          primary: {
            title: '蓝牙键盘',
            content: [{ text: '已断开连接' }],
            keepTime: 0
          },
          capsule: {
            type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT,
            status: -1,
            icon: ICON,
            title: '蓝牙键盘'
          }
        }
      };
      await liveViewManager.stopLiveView(liveView);
      hilog.info(DOMAIN, 'LiveView', 'stopLiveView ok');
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, 'LiveView', 'stopLiveView failed: %{public}d %{public}s', e.code, e.message);
    }
    // 如果走的是通知降级，这里把通知也收掉
    try {
      await notificationManager.cancel(LIVE_ID);
    } catch (err) {
      // 没有对应通知时会失败，忽略
    }
  }
}
