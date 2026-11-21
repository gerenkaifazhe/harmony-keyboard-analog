import { uiMaterial } from '@kit.ArkUI';
import { abilityAccessCtrl, common, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { notificationManager } from '@kit.NotificationKit';
import { CardItem, getCardById, getCardTitle, HistoryDevice } from '../model/CardData';
import { KeyboardBridge } from '../model/KeyboardBridge';

/**
 * 官方沉浸光感材质。注意：组件级 systemMaterial 只在 Navigation 标题栏、底部 TabBar 内生效，
 * 页面内容区的 Text/Row/Button 一律不渲染；Toggle（Slider/Select 同理）是全页面生效的，
 * 所以标签胶囊用 Toggle(ToggleType.Button) 承载，只借它的材质能力。
 */
const GLASS_TAG: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
  style: uiMaterial.ImmersiveStyle.THIN,
  applyShadow: true
});

/**
 * 可点击的材质控件：开启交互形变（所有算力档可见）+ 触摸光感反馈
 * （lightEffect 仅高/中算力设备可见，低算力设备无视觉差异）。
 */
const GLASS_ACTION: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
  style: uiMaterial.ImmersiveStyle.REGULAR,
  applyShadow: true,
  interactive: true,
  lightEffect: {}
});

// Select 本体：超薄通透磨砂（官方示例 11 写法）
const SELECT_MATERIAL: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
  style: uiMaterial.ImmersiveStyle.ULTRA_THIN
});
// 下拉面板：厚重磨砂，保证菜单项可读
const SELECT_MENU_MATERIAL: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
  style: uiMaterial.ImmersiveStyle.THICK
});

/**
 * 缩略态卡片：列表里的样子，也是动画起飞/降落时的样子。
 * 尺寸、圆角、裁剪、阴影全部由父级（页面）设置，组件内部只负责内容。
 */
@Component
export struct CardFace {
  @Prop cardId: string = '';
  // 飞行时背景由页面统一画，本组件只画内容；否则根容器的渐变会把外层背景盖住
  @Prop showBackground: boolean = true;
  // 蓝牙卡片左上角的标签要跟着连接状态走，所以订阅全局状态
  @StorageProp('btConnected') btConnected: boolean = false;
  @StorageProp('btStarting') btStarting: boolean = false;
  // 本机蓝牙设备名：顶部大卡片的标题用它，随系统名称变化自动刷新
  @StorageProp('btLocalName') btLocalName: string = '';
  // 每张卡片各自的背景壁纸，缩略态和展开态共用
  @StorageProp('cardWallpaperEntries') cardWallpaperEntries: string[] = [];

  private card(): CardItem {
    return getCardById(this.cardId);
  }

  /** 取这张卡片自己的壁纸，没有就返回空串（走原本的渐变） */
  private myWallpaper(): string {
    const prefix: string = this.cardId + '|';
    for (let i = 0; i < this.cardWallpaperEntries.length; i++) {
      const entry: string = this.cardWallpaperEntries[i];
      if (entry.startsWith(prefix)) {
        return entry.substring(prefix.length);
      }
    }
    return '';
  }

  /** 给 #RRGGBB 补上透明度，拼成 #AARRGGBB */
  private withAlpha(color: string, alpha: string): string {
    return '#' + alpha + color.substring(1);
  }

  private tagText(): string {
    if (!this.card().isKeyboard) {
      return this.card().tag;
    }
    if (this.btConnected) {
      return '蓝牙已连接';
    }
    return this.btStarting ? '蓝牙连接中' : '蓝牙未连接';
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 缩略态也要显示这张卡的壁纸，蒙版同样调淡
      if (this.showBackground && this.myWallpaper().length > 0) {
        Image(this.myWallpaper())
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 135,
            colors: [
              [this.withAlpha(this.card().c1, '59'), 0.0],
              [this.withAlpha(this.card().c2, 'A6'), 1.0]
            ]
          })
      }

      // 背景光斑
      Column()
        .width('62%')
        .aspectRatio(1)
        .borderRadius('50%')
        .backgroundColor('#FFFFFF')
        .opacity(0.10)
        .position({ x: '56%', y: '-24%' })

      Column()
        .width('38%')
        .aspectRatio(1)
        .borderRadius('50%')
        .backgroundColor('#000000')
        .opacity(0.06)
        .position({ x: '-12%', y: '72%' })

      Column() {
        Row() {
          Toggle({ type: ToggleType.Button, isOn: true }) {
            Text(this.tagText())
              .fontSize(16)
              .fontColor(Color.White)
          }
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(12)
          .backgroundColor(Color.Transparent)
          .selectedColor(Color.Transparent)
          .systemMaterial(GLASS_TAG)
          .hitTestBehavior(HitTestMode.None)
          Blank()
          Text(this.card().index)
            .fontSize(12)
            .fontColor('#99FFFFFF')
            .letterSpacing(1)
        }
        .width('100%')

        Blank()

        Text(getCardTitle(this.card(), this.btLocalName))
          .fontSize(21)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          // 设备名常常是连写的英文/下划线，按任意字符断行才能换到第二行再省略
          .wordBreak(this.card().titleUseLocalBtName ? WordBreak.BREAK_ALL : WordBreak.NORMAL)
        Text(this.card().subtitle)
          .fontSize(12)
          .fontColor('#BFFFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 5 })
      }
      .width('100%')
      .height('100%')
      .padding(16)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .linearGradient({
      angle: 135,
      colors: [
        [this.showBackground ? this.card().c1 : Color.Transparent, 0.0],
        [this.showBackground ? this.card().c2 : Color.Transparent, 1.0]
      ]
    })
  }
}

/**
 * 展开态内容：与缩略态共用同一块渐变背景，只是内容换成了详情。
 * 页面通过给两层叠加不同的 opacity 来做"缩略态 → 详情态"的柔和过渡。
 */
@Component
export struct CardDetail {
  // 这个组件在页面里是复用的，切换卡片时只会改 cardId，所以要监听它重新加载历史
  @Prop @Watch('onCardChanged') cardId: string = '';
  @Prop showClose: boolean = false;
  // 飞行时背景由页面统一画，本组件只画内容
  @Prop showBackground: boolean = true;
  // 连接历史（数量可变）与每项「主动回连」的开关状态，两者下标一一对应
  @State devices: HistoryDevice[] = [];
  @State switches: boolean[] = [];
  // 壁纸入口的固定文案：Select 选中后会自动改显示值，用状态顶回去
  @State wallpaperLabel: string = '更换壁纸';
  // 交替标志：两次复位分别带/不带零宽空格，保证状态值必然变化、必然触发重渲染
  private wallpaperLabelFlip: boolean = false;
  // 蓝牙键盘卡片的真实状态（KeyboardBridge 写入 AppStorage，这里只读订阅）
  @StorageProp('btConnected') btConnected: boolean = false;
  @StorageProp('btConnectedAddress') btConnectedAddress: string = '';
  @StorageProp('btStarting') btStarting: boolean = false;
  @StorageProp('btRunning') btRunning: boolean = false;
  // 连接历史（作为键盘被连过的）与我的设备（平板已配对的电脑/手机/平板）
  @StorageProp('btHistoryDevices') btHistoryDevices: HistoryDevice[] = [];
  @StorageProp('btMyDevices') btMyDevices: HistoryDevice[] = [];
  @StorageProp('btAutoAddress') btAutoAddress: string = '';
  @StorageProp('btMessage') btMessage: string = '';
  // 键盘页壁纸（缩略卡不显示，展开态才用）
  @StorageProp('wallpaperUri') wallpaperUri: string = '';
  // 每张卡片各自的背景壁纸，元素格式 "c2|file://..."
  @StorageProp('cardWallpaperEntries') cardWallpaperEntries: string[] = [];

  /** 取这张卡片自己的壁纸，没有就返回空串（走原本的渐变） */
  private myWallpaper(): string {
    const prefix: string = this.cardId + '|';
    for (let i = 0; i < this.cardWallpaperEntries.length; i++) {
      const entry: string = this.cardWallpaperEntries[i];
      if (entry.startsWith(prefix)) {
        return entry.substring(prefix.length);
      }
    }
    return '';
  }

  /** 给 #RRGGBB 补上透明度，拼成 #AARRGGBB */
  private withAlpha(color: string, alpha: string): string {
    return '#' + alpha + color.substring(1);
  }
  // 本机蓝牙设备名：展开态标题与缩略态保持一致
  @StorageProp('btLocalName') btLocalName: string = '';
  onClose: () => void = () => {
  };
  // 切换卡片时把列表滚回顶部，避免沿用上一张卡片的滚动位置
  private historyScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.loadHistory();
  }

  private onCardChanged(): void {
    this.loadHistory();
    this.resetScroll();
  }

  /** List 节点已经存在时才能滚，首帧还没挂载，用 setTimeout 推到下一轮 */
  private resetScroll(): void {
    setTimeout(() => {
      try {
        this.historyScroller.scrollToIndex(0);
      } catch (err) {
        // 列表此时还不存在（首帧），无需处理
      }
    }, 0);
  }

  private loadHistory(): void {
    const list: HistoryDevice[] = this.card().history;
    const flags: boolean[] = [];
    for (let i = 0; i < list.length; i++) {
      flags.push(list[i].autoReconnect);
    }
    this.devices = list;
    this.switches = flags;
  }

  private card(): CardItem {
    return getCardById(this.cardId);
  }

  private toggleAt(index: number, value: boolean): void {
    const next: boolean[] = [];
    for (let i = 0; i < this.switches.length; i++) {
      next.push(i === index ? value : this.switches[i]);
    }
    this.switches = next;
    // 写回数据源：收起后重新打开这张卡片，开关状态还在
    if (index >= 0 && index < this.devices.length) {
      this.devices[index].autoReconnect = value;
    }
  }

  // ==================== 蓝牙键盘 ====================

  private tagText(): string {
    if (!this.card().isKeyboard) {
      return this.card().tag;
    }
    if (this.btConnected) {
      return '蓝牙已连接';
    }
    return this.btStarting ? '蓝牙连接中' : '蓝牙未连接';
  }

  /** 列表数据源：蓝牙卡片分「连接历史」和「我的设备」两段，其它卡片用示例历史 */
  private listHistoryDevices(): HistoryDevice[] {
    return this.card().isKeyboard ? this.btHistoryDevices : this.devices;
  }

  private listMyDevices(): HistoryDevice[] {
    return this.card().isKeyboard ? this.btMyDevices : [];
  }

  private hasAnyDevice(): boolean {
    return this.listHistoryDevices().length > 0 || this.listMyDevices().length > 0;
  }

  /** 「主动回连」全局只能有一个：蓝牙卡片由全局地址决定，示例卡片用各自的开关 */
  private isSwitchOn(index: number, item: HistoryDevice): boolean {
    if (this.card().isKeyboard) {
      return item.id === this.btAutoAddress;
    }
    return this.switches[index] === true;
  }

  private onToggle(index: number, item: HistoryDevice, value: boolean): void {
    if (this.card().isKeyboard) {
      // 打开某个设备会顶掉之前那个，天然只有一个
      KeyboardBridge.getInstance().setAutoReconnect(item.id, value);
      return;
    }
    this.toggleAt(index, value);
  }

  private deviceHint(item: HistoryDevice): string {
    return item.id === this.btConnectedAddress ? '已连接' : '点击申请回连';
  }

  /** 点击设备：直接向它发起回连 */
  private onDeviceTap(item: HistoryDevice): void {
    if (!this.card().isKeyboard) {
      return;
    }
    KeyboardBridge.getInstance().connect(item.id).then((message: string) => {
      if (message.length > 0) {
        AppStorage.setOrCreate('btMessage', message);
      }
    }).catch(() => {
      AppStorage.setOrCreate('btMessage', '发起连接失败');
    });
  }

  /** 左滑删除：只清应用内的连接历史，不动系统配对 */
  private onRemoveDevice(address: string): void {
    KeyboardBridge.getInstance().removeDevice(address);
    this.getUIContext().getPromptAction().showToast({
      message: '已从连接历史移除',
      duration: 1200
    });
  }

  /** 开始 / 停止模拟 */
  private onSimulate(): void {
    if (!this.card().isKeyboard) {
      return;
    }
    const bridge: KeyboardBridge = KeyboardBridge.getInstance();
    if (this.btRunning) {
      bridge.stop().catch(() => {
      });
      return;
    }
    this.requestBluetoothPermissions().then((granted: boolean) => {
      if (!granted) {
        AppStorage.setOrCreate('btMessage', '蓝牙权限被拒绝，请在系统设置中授予');
        return;
      }
      // 退到后台要展示实况窗/通知，顺手把通知授权要一下
      this.requestNotificationPermission();
      bridge.start().catch(() => {
        AppStorage.setOrCreate('btMessage', '启动蓝牙键盘失败');
      });
    }).catch(() => {
      AppStorage.setOrCreate('btMessage', '权限请求失败');
    });
  }

  /** 请求通知授权：实况窗权益没开通时会降级成通知，需要这个权限 */
  private requestNotificationPermission(): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (!ctx) {
        return;
      }
      notificationManager.requestEnableNotification(ctx).then(() => {
        notificationManager.isNotificationEnabled().then((enabled: boolean) => {
          if (!enabled) {
            this.getUIContext().getPromptAction().showToast({
              message: '请在系统设置中允许通知，退到后台才能看到连接状态',
              duration: 3000
            });
          }
        }).catch(() => {
        });
      }).catch(() => {
        // 系统未放行时提示用户手动开启
        this.getUIContext().getPromptAction().showToast({
          message: '请在系统设置中允许通知，退到后台才能看到连接状态',
          duration: 3000
        });
      });
    } catch (err) {
      // 忽略
    }
  }

  private async requestBluetoothPermissions(): Promise<boolean> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const permissions: Array<Permissions> = [
        'ohos.permission.ACCESS_BLUETOOTH' as Permissions,
        'ohos.permission.DISCOVER_BLUETOOTH' as Permissions
      ];
      const result: PermissionRequestResult = await atManager.requestPermissionsFromUser(ctx, permissions);
      for (let i = 0; i < result.authResults.length; i++) {
        if (result.authResults[i] !== 0) {
          return false;
        }
      }
      return true;
    } catch (err) {
      return false;
    }
  }

  // ==================== 键盘页壁纸 ====================

  /** 壁纸下拉菜单的分发：0/1 卡片壁纸，2/3 键盘壁纸 */
  private onWallpaperAction(index: number): void {
    if (index === 0) {
      this.pickWallpaper(true);
    } else if (index === 1) {
      KeyboardBridge.getInstance().setCardWallpaper(this.cardId, '');
      this.getUIContext().getPromptAction().showToast({
        message: '已恢复卡片默认背景',
        duration: 1600
      });
    } else if (index === 2) {
      this.pickWallpaper(false);
    } else if (index === 3) {
      // 空字符串 = 恢复纯色背景
      KeyboardBridge.getInstance().setWallpaper('');
      this.getUIContext().getPromptAction().showToast({
        message: '已恢复默认键盘壁纸',
        duration: 1600
      });
    }
    // Select 选中后会把按钮文字换成菜单项。同步把状态顶回去：
    // 直接赋相同值（'更换壁纸'→'更换壁纸'）不触发重渲染，所以交替附加零宽空格，
    // 让每次复位的状态值都不同；渲染出来的文字一模一样，也不会出现"文案消失"的空档
    this.wallpaperLabelFlip = !this.wallpaperLabelFlip;
    this.wallpaperLabel = this.wallpaperLabelFlip ? '更换壁纸\u200B' : '更换壁纸';
  }

  /** 选一张图当壁纸：forCard=true 给展开卡片，false 给键盘页 */
  private pickWallpaper(forCard: boolean): void {
    const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
    const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
    options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    options.maxSelectNumber = 1;
    picker.select(options).then((result: photoAccessHelper.PhotoSelectResult) => {
      if (result.photoUris.length === 0) {
        return;
      }
      const uri: string = this.saveWallpaperToSandbox(result.photoUris[0]);
      if (forCard) {
        KeyboardBridge.getInstance().setCardWallpaper(this.cardId, uri);
      } else {
        KeyboardBridge.getInstance().setWallpaper(uri);
      }
      this.getUIContext().getPromptAction().showToast({
        message: forCard ? '卡片壁纸已更新' : '键盘壁纸已更新，进入键盘页查看',
        duration: 1600
      });
    }).catch((e: BusinessError) => {
      console.error('pickWallpaper failed: ' + JSON.stringify(e));
      this.getUIContext().getPromptAction().showToast({
        message: '选择壁纸失败',
        duration: 1600
      });
    });
  }

  /**
   * 选择器返回的 URI 只有临时授权，重启后就失效了，
   * 所以复制一份到应用沙箱再用。
   */
  private saveWallpaperToSandbox(sourceUri: string): string {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (!ctx) {
        return sourceUri;
      }
      const dst: string = ctx.filesDir + '/keyboard_wallpaper_' + Date.now() + '.jpg';
      const srcFile = fileIo.openSync(sourceUri, fileIo.OpenMode.READ_ONLY);
      const dstFile = fileIo.openSync(dst,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.copyFileSync(srcFile.fd, dstFile.fd);
      fileIo.closeSync(srcFile);
      fileIo.closeSync(dstFile);
      return 'file://' + dst;
    } catch (err) {
      console.error('saveWallpaperToSandbox failed: ' + JSON.stringify(err));
      return sourceUri;
    }
  }

  // ==================== 列表项 ====================

  /** 单个设备行：蓝牙卡片走左滑删除，示例卡片不支持 */
  @Builder
  DeviceListItem(item: HistoryDevice, index: number) {
    if (this.card().isKeyboard) {
      ListItem() {
        this.DeviceRow(item, index)
      }
      .swipeAction({
        end: {
          builder: () => {
            this.DeleteButton(item.id)
          },
          // 滑过阈值松手直接删除，和点图标等效
          actionAreaDistance: 56,
          onAction: () => {
            this.onRemoveDevice(item.id);
          }
        }
      })
    } else {
      ListItem() {
        this.DeviceRow(item, index)
      }
    }
  }

  @Builder
  DeviceRow(item: HistoryDevice, index: number) {
    Row() {
      Column() {
        Text(item.name)
          .fontSize(22)
          .fontColor(Color.White)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.card().isKeyboard) {
          Text(this.deviceHint(item))
            .fontSize(13)
            .fontColor(item.id === this.btConnectedAddress ? '#BFFFFFFF' : '#8CFFFFFF')
            .margin({ top: 2 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .onClick(() => {
        // 点设备 = 直接向它申请回连
        this.onDeviceTap(item);
      })

      Text('主动回连')
        .fontSize(16)
        .fontColor('#BFFFFFFF')
        .margin({ right: 14 })
        .onClick(() => {
          // 点文字等同点开关，只有一个能亮
          this.onToggle(index, item, !this.isSwitchOn(index, item));
        })
      ToggleSwitch({
        on: this.isSwitchOn(index, item),
        onChange: (value: boolean) => {
          this.onToggle(index, item, value);
        }
      })
        // 开关整体往左收一点，右侧留白更接近卡片的其它内容
        .margin({ right: 14 })
    }
    .width('100%')
    .height(66)
  }

  @Builder
  DeleteButton(address: string) {
    Image($rawfile('delete.png'))
      .width(36)
      .height(36)
      .margin({ left: 8, top: 15, bottom: 15 })
      .onClick(() => {
        this.onRemoveDevice(address);
      })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 壁纸层：这张卡设了壁纸就盖在渐变上，再压一层同色蒙版保证白字可读
      if (this.showBackground && this.myWallpaper().length > 0) {
        Image(this.myWallpaper())
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 135,
            colors: [
              // 有壁纸时蒙版调淡，让图透出来；恢复壁纸后回到完整渐变
              [this.withAlpha(this.card().c1, '59'), 0.0],
              [this.withAlpha(this.card().c2, 'A6'), 1.0]
            ]
          })
      }

      // 背景光斑
      Column()
        .width('62%')
        .aspectRatio(1)
        .borderRadius('50%')
        .backgroundColor('#FFFFFF')
        .opacity(0.10)
        .position({ x: '56%', y: '-24%' })

      Column()
        .width('38%')
        .aspectRatio(1)
        .borderRadius('50%')
        .backgroundColor('#000000')
        .opacity(0.06)
        .position({ x: '-12%', y: '72%' })

      Column() {
      Row() {
        // 左上角标签：状态点 + 文案，红点未连接 / 绿点已连接
        Toggle({ type: ToggleType.Button, isOn: true }) {
          Row({ space: 8 }) {
            Column()
              .width(9)
              .height(9)
              .borderRadius(4.5)
              .backgroundColor(this.btConnected ? '#4ADE80' : '#FF5A5F')
            Text(this.tagText())
              .fontSize(18)
              .fontColor(Color.White)
              .maxLines(1)
          }
        }
        .padding({ left: 15, right: 15, top: 7, bottom: 7 })
        .borderRadius(14)
        .backgroundColor(Color.Transparent)
        .selectedColor(Color.Transparent)
        .systemMaterial(GLASS_TAG)
        .hitTestBehavior(HitTestMode.None)
        Blank()
        if (this.showClose) {
          // Toggle 承载：Button/Stack 在页面内容区不生效
          Toggle({ type: ToggleType.Button, isOn: false }) {
            Text('✕')
              .fontSize(13)
              .fontColor(this.card().c2)
          }
          .width(30)
          .height(30)
          .padding(0)
          .borderRadius(15)
          .backgroundColor(Color.Transparent)
          .selectedColor(Color.Transparent)
          .systemMaterial(GLASS_ACTION)
          .onClick(() => {
            this.onClose();
          })
        }
      }
      .width('100%')

        // 标题 + 更换壁纸 + 下划线
        Row() {
          if (this.card().titleUseLocalBtName) {
            // 蓝牙名可能很长：只有文本宽度超出滚动区才启动滚动，
            // 滚完一轮停 5 秒再滚下一轮；短文本静止不滚
            Marquee({
              start: true,
              step: 10,
              loop: -1,
              fromStart: true,
              delay: 5000,
              src: getCardTitle(this.card(), this.btLocalName)
            })
              .fontSize(40)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
              .layoutWeight(1)
          } else {
            Text(getCardTitle(this.card(), this.btLocalName))
              .fontSize(40)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          // 更换壁纸入口：官方 Select + 下拉菜单沉浸光感（示例 11 写法）
          Select([
            { value: '更换卡片壁纸' },
            { value: '恢复卡片壁纸' },
            { value: '更换键盘壁纸' },
            { value: '恢复键盘壁纸' }
          ])
            .value(this.wallpaperLabel)
            .selected(-1)
            .font({ size: 14 })
            // 浅色玻璃底上白字看不清，跟底部按钮一样用卡片主色
            .fontColor(this.card().c2)
            .margin({ left: 12 })
            .systemMaterial(SELECT_MATERIAL)
            .menuSystemMaterial(SELECT_MENU_MATERIAL)
            .onSelect((index: number, value: string) => {
              this.onWallpaperAction(index);
            })
        }
        .width('100%')
        .margin({ top: 22 })
        Divider()
          .color('#4DFFFFFF')
          .strokeWidth(1.5)
          .margin({ top: 14 })

        // 第一张卡（蓝牙名卡片）没有设备列表：留白撑开，底部按钮保持在卡片底部
        if (!this.card().titleUseLocalBtName) {
          // 设备列表：数量可变，列表本身可滚动（layoutWeight 吃掉中间剩余高度）
          Row() {
            Text('设备列表')
              .fontSize(20)
              .fontColor('#D9FFFFFF')
            if (this.card().isKeyboard && this.btMessage.length > 0) {
              Text(this.btMessage)
                .fontSize(13)
                .fontColor('#BFFFFFFF')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
                .textAlign(TextAlign.End)
                .margin({ left: 16 })
            } else {
              Blank()
            }
          }
          .width('100%')
          .margin({ top: 26, bottom: 6 })

          if (!this.hasAnyDevice()) {
            Column() {
              Text('暂无历史设备')
                .fontSize(18)
                .fontColor('#8CFFFFFF')
              // 列表空的时候把失败原因完整显示出来，标题旁那行会被截断
              if (this.card().isKeyboard && this.btMessage.length > 0) {
                Text(this.btMessage)
                  .fontSize(13)
                  .lineHeight(20)
                  .fontColor('#BFFFFFFF')
                  .maxLines(4)
                  .textAlign(TextAlign.Center)
                  .padding({ left: 24, right: 24 })
                  .margin({ top: 10 })
              } else if (this.card().isKeyboard) {
                Text('开始模拟后，在电脑上搜索并连接本机')
                  .fontSize(13)
                  .lineHeight(20)
                  .fontColor('#8CFFFFFF')
                  .textAlign(TextAlign.Center)
                  .padding({ left: 24, right: 24 })
                  .margin({ top: 10 })
              }
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          } else {
            List({ scroller: this.historyScroller }) {
              // 连接历史区块：作为键盘被连过的设备，支持左滑删除
              if (this.listHistoryDevices().length > 0) {
                ListItem() {
                  Row() {
                    Text('连接历史')
                      .fontSize(13)
                      .fontColor('#8CFFFFFF')
                    Blank()
                    Text('左滑可移除')
                      .fontSize(11)
                      .fontColor('#66FFFFFF')
                  }
                  .width('100%')
                  .height(34)
                }
                ForEach(this.listHistoryDevices(), (item: HistoryDevice, index: number) => {
                  this.DeviceListItem(item, index)
                }, (item: HistoryDevice) => 'h' + item.id)
              }
              // 我的设备区块：平板已配对的电脑 / 手机，点一下就能申请回连
              if (this.listMyDevices().length > 0) {
                ListItem() {
                  Row() {
                    Text('我的设备')
                      .fontSize(13)
                      .fontColor('#8CFFFFFF')
                    Blank()
                    Text('平板认识的电脑 / 手机')
                      .fontSize(11)
                      .fontColor('#66FFFFFF')
                  }
                  .width('100%')
                  .height(34)
                }
                ForEach(this.listMyDevices(), (item: HistoryDevice, index: number) => {
                  this.DeviceListItem(item, index)
                }, (item: HistoryDevice) => 'm' + item.id)
              }
            }
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .fadingEdge(true)
          }

        } else {
          Blank().layoutWeight(1)
        }

        // 底部两个胶囊按钮
        Row({ space: 16 }) {
          // Toggle 承载：页面内容区的 Button 不吃 systemMaterial
          Toggle({ type: ToggleType.Button, isOn: false }) {
            Text(this.card().isKeyboard && this.btRunning ? '停止模拟' : '开始模拟')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.card().c2)
          }
          .layoutWeight(1)
          .height(56)
          .padding(0)
          .borderRadius(28)
          .backgroundColor(Color.Transparent)
          .selectedColor(Color.Transparent)
          .systemMaterial(GLASS_ACTION)
          .onClick(() => {
            this.onSimulate();
          })
          Toggle({ type: ToggleType.Button, isOn: false }) {
            Text('进入键盘')
              .fontSize(18)
              .fontColor(this.card().c2)
          }
          .layoutWeight(1)
          .height(56)
          .padding(0)
          .borderRadius(28)
          .backgroundColor(Color.Transparent)
          .selectedColor(Color.Transparent)
          .systemMaterial(GLASS_ACTION)
          .onClick(() => {
            this.getUIContext().getRouter().pushUrl({ url: 'pages/KeyboardPage' }).catch(() => {
            });
          })
        }
        .width('100%')
        .margin({ top: 20 })
      }
      .width('100%')
      .height('100%')
      .padding(28)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .linearGradient({
      angle: 135,
      colors: [
        [this.showBackground ? this.card().c1 : Color.Transparent, 0.0],
        [this.showBackground ? this.card().c2 : Color.Transparent, 1.0]
      ]
    })
  }
}

/**
 * 卡片上的小开关：直接用系统 Toggle（Switch 类型），并开启官方沉浸光感材质。
 * systemMaterial 的参数只当"开关标记"用，实际样式（滑块大小、阴影、白色点光源）
 * 由系统按设备算力自适应渲染，不需要额外配色。
 * 状态由父级持有（列表项数量可变，用不了 @Link 的定点绑定），这里只负责显示和回调。
 */
@Component
struct ToggleSwitch {
  @Prop on: boolean = false;
  onChange: (value: boolean) => void = () => {
  };

  build() {
    Toggle({ type: ToggleType.Switch, isOn: this.on })
      // 开启态轨道用半透明白，和卡片上的半透明白胶囊一致；关闭态沿用系统浅色
      .selectedColor('#66FFFFFF')
      .systemMaterial(new uiMaterial.Material())
      .onChange((isOn: boolean) => {
        this.onChange(isOn);
      })
  }
}
