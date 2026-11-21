import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { KeyboardBridge } from '../model/KeyboardBridge';
import { ACTION_DISCONNECT, DeviceLiveView, LIVE_ACTION } from '../model/DeviceLiveView';

const DOMAIN = 0x0000;
// 状态栏 / 导航条上的图标文字颜色（浅色背景用深色）
const BAR_CONTENT_COLOR = '#1A2233';
// 状态栏必须是全透明：内容要能从它下面穿过去，这才是沉浸
const STATUS_BAR_BG = '#00000000';
// 导航条不接受全透明，会给一块白色底，只能填成和页面一样的颜色
const NAV_BAR_BG = '#F4F6FB';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    this.handleLiveViewAction(want);
  }

  /** 应用已在运行时，从实况窗按钮再次拉起会走到这里 */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onNewWant');
    this.handleLiveViewAction(want);
  }

  /** 实况窗卡片上的按钮只能带参数拉起应用，真正的动作在这里执行 */
  private handleLiveViewAction(want: Want): void {
    const params: Record<string, Object> | undefined = want.parameters;
    if (!params) {
      return;
    }
    const action: string = params[LIVE_ACTION] as string;
    if (action === ACTION_DISCONNECT) {
      hilog.info(DOMAIN, 'testTag', 'live view: disconnect requested');
      KeyboardBridge.getInstance().disconnectFromLiveView().catch(() => {
      });
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
    // 注销 HID 注册、释放蓝牙资源
    KeyboardBridge.getInstance().destroy();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    // 蓝牙键盘：加载历史设备与"主动回连"配置，接管服务回调。这里不主动开启模拟
    try {
      const prefs: preferences.Preferences =
        preferences.getPreferencesSync(this.context, { name: 'bt_keyboard_prefs' });
      KeyboardBridge.getInstance().init(prefs);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to init keyboard bridge. Cause: %{public}s',
        JSON.stringify(err));
    }

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      // 页面加载完成后再切全屏：启动页先正常淡出，避免它和全屏切换叠在一起
      this.setupImmersive(windowStage);
    });

    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 沉浸式：窗口全屏 + 系统栏底色与页面同色、图标压深色。
   * 页面拿到避让区高度后自己补内边距，所以左侧列表可以一路滚到屏幕底边。
   */
  private setupImmersive(windowStage: window.WindowStage): void {
    try {
      const win = windowStage.getMainWindowSync();
      // 内容铺满整屏：左侧列表要能滚到屏幕最底部（手势条底下）
      win.setWindowLayoutFullScreen(true).catch((e: BusinessError) => {
        hilog.error(DOMAIN, 'testTag', 'setWindowLayoutFullScreen failed: %{public}s', JSON.stringify(e));
      });
      win.setWindowSystemBarProperties({
        statusBarColor: STATUS_BAR_BG,
        statusBarContentColor: BAR_CONTENT_COLOR,
        navigationBarColor: NAV_BAR_BG,
        navigationBarContentColor: BAR_CONTENT_COLOR
      }).catch((e: BusinessError) => {
        hilog.error(DOMAIN, 'testTag', 'setWindowSystemBarProperties failed: %{public}s', JSON.stringify(e));
      });
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'setupImmersive failed: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    // 系统会在后台回收 HID 注册，回到前台时重新注册并按设定回连
    KeyboardBridge.getInstance().onForeground();
    // 回到前台就不需要实况窗了
    DeviceLiveView.hide().catch(() => {
    });
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    // 先取设备名，再通知桥接层（桥接层里的动作可能会改写连接状态）
    const name: string = KeyboardBridge.getInstance().getConnectedDeviceName();
    KeyboardBridge.getInstance().onBackground();
    // 退到后台且仍连着设备时，上实况窗
    if (name.length > 0) {
      DeviceLiveView.show(name).catch(() => {
      });
    }
  }
}
