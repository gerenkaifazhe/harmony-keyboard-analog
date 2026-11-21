import { curves, LengthMetrics, uiMaterial, window } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationTitleMode, hdsMaterial, ScrollEffectType } from '@kit.UIDesignKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CardDetail, CardFace } from '../components/CardFace';
import { CardItem, CardRow, CARD_ROWS, getCardById, HistoryDevice, LOCAL_BT_NAME_PLACEHOLDER } from '../model/CardData';

// ---- 官方沉浸光感玻璃底栏（Tabs + barFloatingStyle + systemMaterial，效果全部由系统渲染）----
const BAR_HEIGHT = 58;   // 胶囊栏高
const BAR_BOTTOM = 24;   // 距屏幕底部的基础间距，再叠加手势条高度
const BAR_WIDTH = 200;   // 窄胶囊宽度：只包住两个页签
// 底栏本体占的高度（栏高 + 底部间距），滚动内容和右侧画布都要在这里让位
const BAR_BLOCK = BAR_HEIGHT + BAR_BOTTOM;

/** 相对根容器的一块矩形（vp） */
class RectInfo {
  x: number = 0;
  y: number = 0;
  w: number = 0;
  h: number = 0;
}

@Entry
@Component
struct Index {
  // 当前展开的卡片 id / 正在缩回列表的卡片 id
  @State activeId: string = '';
  @State exitingId: string = '';

  // 正在放大中：动画结束前不再受理新的开卡，避免两层卡片互相打断
  private flying: boolean = false;
  // 记下每张缩略卡的位置：卡片飞出后瓦片不再参与布局时，也能算回收起的落点
  private tileRects: Map<string, RectInfo> = new Map();

  // 主卡片：位置尺寸 + 整体显隐 + 缩略内容透明度 + 详情内容透明度 + 抬升层透明度
  @State heroX: number = 0;
  @State heroY: number = 0;
  @State heroW: number = 0;
  @State heroH: number = 0;
  @State heroR: number = 22;
  @State heroA: number = 0;
  @State heroP: number = 0;
  @State heroD: number = 0;
  @State heroE: number = 0;

  // 退场卡片：同上
  @State exitX: number = 0;
  @State exitY: number = 0;
  @State exitW: number = 0;
  @State exitH: number = 0;
  @State exitR: number = 22;
  @State exitA: number = 0;
  @State exitP: number = 0;
  @State exitD: number = 0;
  @State exitE: number = 0;

  // 沉浸式内边距（vp）：窗口全屏后自己补，列表才能一路滚到屏幕底边
  @State padTop: number = 24;
  @State padPanelBottom: number = 20;
  @State scrollBottomPad: number = 8;
  // 手势条高度：悬浮胶囊要往上让开它
  @State bottomAvoid: number = 0;

  // 底栏页签索引：0 主页 / 1 个人
  @State currentTabIndex: number = 0;

  // 个人页要用的蓝牙状态（KeyboardBridge 写入 AppStorage，这里只读订阅）
  @StorageProp('btLocalName') btLocalName: string = '';
  @StorageProp('btConnected') btConnected: boolean = false;
  @StorageProp('btRunning') btRunning: boolean = false;
  @StorageProp('btHistoryDevices') btHistoryDevices: HistoryDevice[] = [];
  // 每张卡片各自的背景壁纸（飞行层统一画，保证放大/缩小全程同一浓度）
  @StorageProp('cardWallpaperEntries') cardWallpaperEntries: string[] = [];

  // 主页列表的滚动控制器：标题栏的渐变模糊/材质跟着它滚动
  private listScroller: Scroller = new Scroller();

  /** 取某张卡片的壁纸，没设过返回空串 */
  private wallpaperOf(cardId: string): string {
    const prefix: string = cardId + '|';
    for (let i = 0; i < this.cardWallpaperEntries.length; i++) {
      const entry: string = this.cardWallpaperEntries[i];
      if (entry.startsWith(prefix)) {
        return entry.substring(prefix.length);
      }
    }
    return '';
  }

  /** #RRGGBB 补上透明度，拼成 #AARRGGBB（与卡片内的蒙版浓度保持一致） */
  private withAlpha(color: string, alpha: string): string {
    return '#' + alpha + color.substring(1);
  }

  private exitSeq: number = 0;
  private DUR: number = 460;
  private R_TILE: number = 22;
  private R_PANEL: number = 28;
  // 阴影：底色层永远用缩略图那套参数（交接时严丝合缝），
  // 展开后需要的重阴影挂在抬升层上，靠透明度渐入渐出，不依赖 shadow 能否做属性动画
  private SH_COLOR: string = '#21202A45';
  private SH_R_TILE: number = 16;
  private SH_Y_TILE: number = 6;
  private SH_R_PANEL: number = 34;
  private SH_Y_PANEL: number = 16;
  private flyCurve: ICurve = curves.cubicBezierCurve(0.22, 1, 0.36, 1);

  // ------------------------------------------------------------------
  // 几何
  // ------------------------------------------------------------------

  aboutToAppear(): void {
    this.applySafeArea();
  }

  // 从键盘页（完全沉浸）返回时兜底恢复系统栏。键盘页自己也会恢复，这里是双保险
  onPageShow(): void {
    this.restoreSystemBars();
  }

  private restoreSystemBars(): void {
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

  /**
   * 窗口是全屏的，内容会铺到状态栏和手势条底下。
   * 这里读出避让区：顶部让标题避开状态栏，左侧列表只给滚动内容留底部余量，
   * 列表视口本身一直延伸到屏幕最底边。
   */
  private applySafeArea(): void {
    const host = this.getUIContext().getHostContext();
    if (!host) {
      return;
    }
    window.getLastWindow(host).then((win: window.Window) => {
      try {
        const sysArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        const indicatorArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        const ui = this.getUIContext();
        const topVp = ui.px2vp(sysArea.topRect.height);
        const bottomVp = ui.px2vp(Math.max(sysArea.bottomRect.height, indicatorArea.bottomRect.height));
        this.padTop = 24 + topVp;
        this.padPanelBottom = 20 + bottomVp;
        this.scrollBottomPad = 8 + bottomVp;
        this.bottomAvoid = bottomVp;
      } catch (err) {
        // 读不到避让区就退回非全屏布局，宁可少一截沉浸，也不能让标题被状态栏压住
        win.setWindowLayoutFullScreen(false).catch(() => {
        });
      }
    }).catch((e: BusinessError) => {
      console.error('applySafeArea failed: ' + JSON.stringify(e));
    });
  }

  /** 读取组件相对根容器的矩形（getRectangleById 返回 px，这里统一转 vp） */
  private rectOf(id: string): RectInfo | null {
    try {
      const ctx = this.getUIContext();
      const utils = ctx.getComponentUtils();
      const root = utils.getRectangleById('root-stack');
      const target = utils.getRectangleById(id);
      const r = new RectInfo();
      r.x = ctx.px2vp(target.windowOffset.x - root.windowOffset.x);
      r.y = ctx.px2vp(target.windowOffset.y - root.windowOffset.y);
      r.w = ctx.px2vp(target.size.width);
      r.h = ctx.px2vp(target.size.height);
      return r;
    } catch (err) {
      return null;
    }
  }

  private isGhost(id: string): boolean {
    return id === this.activeId || id === this.exitingId;
  }

  // ------------------------------------------------------------------
  // 动效
  // ------------------------------------------------------------------

  /** 把当前展开的卡片快照到退场层，返回它要缩回去的目标位置 */
  private prepareExit(): RectInfo | null {
    if (this.activeId === '') {
      return null;
    }
    let back: RectInfo | null = this.rectOf('tile-' + this.activeId);
    if (back === null) {
      const cached: RectInfo | undefined = this.tileRects.get(this.activeId);
      if (cached !== undefined) {
        back = cached;
      }
    }
    this.exitX = this.heroX;
    this.exitY = this.heroY;
    this.exitW = this.heroW;
    this.exitH = this.heroH;
    this.exitR = this.heroR;
    this.exitP = this.heroP;
    this.exitD = this.heroD;
    this.exitE = this.heroE;
    this.exitA = 1;
    this.exitingId = this.activeId;
    // 主卡片立刻让位，由退场层无缝接管，肉眼看不到替换
    this.activeId = '';
    this.heroA = 0;
    // 连落点都算不出来（比如极早期的打断）：直接把退场层收掉，
    // 否则它会停在中途，画面上留下半空的卡片
    if (back === null) {
      this.exitA = 0;
      this.exitP = 0;
      this.exitD = 0;
      this.exitE = 0;
      this.exitW = 0;
      this.exitH = 0;
      this.exitingId = '';
    }
    return back;
  }

  /** 打断正在回缩的卡片（用户又点了它），避免两层同时飞 */
  private cancelExit(): void {
    if (this.exitingId === '') {
      return;
    }
    this.exitSeq++;
    this.exitA = 0;
    this.exitP = 0;
    this.exitD = 0;
    this.exitE = 0;
    this.exitW = 0;
    this.exitH = 0;
    this.exitingId = '';
  }

  private runExit(back: RectInfo): void {
    const seq = ++this.exitSeq;
    const end: RectInfo = back;
    this.getUIContext().animateTo({
      duration: this.DUR,
      curve: this.flyCurve,
      onFinish: () => {
        if (seq !== this.exitSeq) {
          return;
        }
        this.exitA = 0;
        this.exitP = 0;
        this.exitD = 0;
        this.exitE = 0;
        // 收成 0 尺寸：退场层正好压在缩略图上，必须先让开，否则会挡住这张卡片的点击
        this.exitW = 0;
        this.exitH = 0;
        this.exitingId = '';
      }
    }, () => {
      this.exitX = end.x;
      this.exitY = end.y;
      this.exitW = end.w;
      this.exitH = end.h;
      this.exitR = this.R_TILE;
      this.exitE = 0;
    });
    // 内容先退回缩略形态，卡片本体继续往回缩
    this.getUIContext().animateTo({ duration: 140, curve: Curve.EaseIn }, () => {
      this.exitD = 0;
      this.exitP = 1;
    });
  }

  private openCard(item: CardItem): void {
    if (this.activeId === item.id) {
      return;
    }
    // 上一张还在放大：这一下点击先丢掉，避免两张卡同时飞
    if (this.flying) {
      return;
    }
    // 这张卡片可能还在往回缩，先把它打断
    this.cancelExit();
    const from = this.rectOf('tile-' + item.id);
    const to = this.rectOf('detail-panel');
    if (from === null || to === null) {
      return;
    }
    const start: RectInfo = from;
    const end: RectInfo = to;
    // 记住这张卡的位置，之后它再飞回来时即使瓦片不参与布局也有落点
    this.tileRects.set(item.id, start);
    const back = this.prepareExit();

    // 新卡片先精确落在自己缩略图的位置上，形态与缩略图完全一致
    this.heroX = start.x;
    this.heroY = start.y;
    this.heroW = start.w;
    this.heroH = start.h;
    this.heroR = this.R_TILE;
    this.heroP = 1;
    this.heroD = 0;
    this.heroE = 0;
    this.heroA = 1;
    this.activeId = item.id;
    this.flying = true;
    const d: number = this.DUR;
    // 兜底解锁：动画被打断时 onFinish 可能不触发，不能把锁留在那儿
    setTimeout(() => {
      this.flying = false;
    }, d + 120);
    // 等初始状态真正上屏一帧之后，再让两张卡同帧启停，交接才连得上
    setTimeout(() => {
      if (back !== null) {
        const b: RectInfo = back;
        this.runExit(b);
      }
      this.getUIContext().animateTo({
        duration: d,
        curve: this.flyCurve,
        onFinish: () => {
          this.flying = false;
        }
      }, () => {
        this.heroX = end.x;
        this.heroY = end.y;
        this.heroW = end.w;
        this.heroH = end.h;
        this.heroR = this.R_PANEL;
        this.heroE = 1;
      });
      // 缩略内容先退场
      this.getUIContext().animateTo({
        duration: Math.round(d * 0.30),
        delay: Math.round(d * 0.20),
        curve: Curve.EaseIn
      }, () => {
        this.heroP = 0;
      });
      // 详情内容后登场：中间只留底色，避免两层文字叠在一起发糊
      this.getUIContext().animateTo({
        duration: Math.round(d * 0.38),
        delay: Math.round(d * 0.50),
        curve: Curve.EaseOut
      }, () => {
        this.heroD = 1;
      });
    }, 32);
  }

  private closeCard(): void {
    const back = this.prepareExit();
    if (back === null) {
      return;
    }
    setTimeout(() => {
      this.runExit(back);
    }, 32);
  }

  /** 窗口尺寸变化（旋转、分屏）时重新贴合右侧画布 */
  private syncHeroToPanel(): void {
    if (this.activeId === '') {
      return;
    }
    const to = this.rectOf('detail-panel');
    if (to === null) {
      return;
    }
    this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
      this.heroX = to.x;
      this.heroY = to.y;
      this.heroW = to.w;
      this.heroH = to.h;
    });
  }

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------

  /** 底栏页签：图标 + 文字，选中态跟随页面主色，玻璃背板由系统渲染 */
  @Builder
  TabBarBuilder(index: number, icon: Resource, title: string) {
    Column({ space: 3 }) {
      SymbolGlyph(icon)
        .fontSize(21)
        .fontColor([this.currentTabIndex === index ? '#3B5BDB' : '#5A6570'])
      Text(title)
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        // 固定行高：胶囊只有 58vp，行高跟着系统字体缩放会让文字顶到胶囊下沿
        .lineHeight(15)
        .fontColor(this.currentTabIndex === index ? '#3B5BDB' : '#5A6570')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  /** 官方沉浸光感材质：ULTRA_THIN 超薄通透 + 投影 + 交互形变 + 点光源 */
  private buildFloatingBarStyle(): FloatingTabBarStyle {
    return {
      adaptToHandedness: true,                                 // 适配左右手习惯
      barSideMargin: 18,                                       // 左右边距
      barBottomMargin: BAR_BOTTOM + this.bottomAvoid,          // 底部间距 + 手势条避让
      // 窄胶囊宽度：只包住页签（FloatingTabBarWidth 不支持百分比，用固定值）
      barWidth: {
        smallBarWidth: BAR_WIDTH,
        mediumBarWidth: BAR_WIDTH,
        largeBarWidth: BAR_WIDTH
      },
      maskHeight: 92,                                          // 底部渐隐遮罩高度
      systemMaterial: new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
        applyShadow: true,
        interactive: true,
        lightEffect: { color: Color.White }
      })
    };
  }

  /** 个人页里的一行信息：左标签右值 */
  @Builder
  InfoRow(label: string, value: string, valueColor: string) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor('#8A94A6')
      Text(value)
        .fontSize(14)
        .fontColor(valueColor)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
        .layoutWeight(1)
        .margin({ left: 16 })
    }
    .width('100%')
    .height(46)
  }

  /** 个人页：本机蓝牙名 + 连接/模拟状态 + 应用信息 */
  @Builder
  ProfilePage() {
    Scroll() {
      Column() {
        Text('个人')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1A2233')
        Text('本机信息与蓝牙状态')
          .fontSize(12)
          .fontColor('#8A94A6')
          .margin({ top: 5 })

        // 本机名片
        Row() {
          Column() {
            Text('本机蓝牙名称')
              .fontSize(12)
              .fontColor('#8A94A6')
            Text(this.btLocalName.length > 0 ? this.btLocalName : LOCAL_BT_NAME_PLACEHOLDER)
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .fontColor('#1A2233')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 6 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Text(this.btConnected ? '已连接' : (this.btRunning ? '等待连接' : '未开启'))
            .fontSize(12)
            .fontColor(Color.White)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(12)
            .backgroundColor(this.btConnected ? '#23A183' : '#C2CAD8')
            .margin({ left: 12 })
        }
        .width('100%')
        .padding(20)
        .borderRadius(20)
        .backgroundColor('#FFFFFF')
        .margin({ top: 18 })

        // 应用信息
        Column() {
          this.InfoRow('应用名称', '灵感卡片', '#1A2233')
          Divider().color('#EEF2F8')
          this.InfoRow('版本', '1.0.0', '#1A2233')
          Divider().color('#EEF2F8')
          this.InfoRow('键盘模拟', this.btRunning ? '运行中' : '未开启',
            this.btRunning ? '#23A183' : '#1A2233')
          Divider().color('#EEF2F8')
          this.InfoRow('连接历史', this.btHistoryDevices.length.toString() + ' 台设备', '#1A2233')
        }
        .width('100%')
        .padding({ left: 20, right: 20 })
        .borderRadius(20)
        .backgroundColor('#FFFFFF')
        .margin({ top: 14 })

        // 说明
        Column() {
          Text('关于底栏')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#1A2233')
          Text('底栏是系统沉浸光感玻璃材质，点按或拖动高亮块可在「主页 / 个人」之间切换；' +
            '键盘页从「蓝牙键盘」卡片的「进入键盘」进入。')
            .fontSize(13)
            .lineHeight(21)
            .fontColor('#8A94A6')
            .margin({ top: 8 })
        }
        .width('100%')
        .padding(20)
        .borderRadius(20)
        .backgroundColor('#FFFFFF')
        .margin({ top: 14 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({
        left: 26,
        right: 26,
        top: this.padTop,
        bottom: this.padPanelBottom + BAR_BLOCK
      })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.TopStart)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  // ---- 主页：原卡片布局 ----
  @Builder
  HomePage() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row() {
        // ---------------- 左：官方沉浸光感标题栏 + 可滚动列表 ----------------
        // 光感标题栏只包左栏：右侧顶部不是标题栏，不能套这层材质
        Column() {
          HdsNavigation() {
            Scroll(this.listScroller) {
              Column({ space: 14 }) {
                ForEach(CARD_ROWS, (row: CardRow) => {
                  Row({ space: 14 }) {
                    ForEach(row.items, (item: CardItem) => {
                      Stack() {
                        // 卡片被"取走"时留下的浅色占位，撑住布局，列表不跳动
                        Column()
                          .width('100%')
                          .height('100%')
                          .backgroundColor('#E9EEF7')
                        CardFace({ cardId: item.id })
                          .width('100%')
                          .height('100%')
                          .opacity(this.isGhost(item.id) ? 0 : 1)
                      }
                      .layoutWeight(1)
                      .height('100%')
                      .borderRadius(this.R_TILE)
                      .clip(true)
                      .shadow({
                        radius: this.SH_R_TILE,
                        color: this.SH_COLOR,
                        offsetX: 0,
                        offsetY: this.SH_Y_TILE
                      })
                      .id('tile-' + item.id)
                      .onClick(() => {
                        // 点自己原来的位置 = 把卡片收回来
                        if (this.activeId === item.id) {
                          this.closeCard();
                        } else {
                          this.openCard(item);
                        }
                      })
                    }, (item: CardItem) => item.id)
                  }
                  .width('100%')
                  .height(row.height)
                }, (row: CardRow, rowIndex: number) => 'row-' + rowIndex)
              }
              .width('100%')
              .padding({
                left: 26,
                right: 14,
                top: 112,
                // 底部让开悬浮底栏，最后一行能滚到胶囊上方
                bottom: this.scrollBottomPad + BAR_BLOCK
              })
            }
            .width('100%')
            .height('100%')
            .align(Alignment.TopStart)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
          }
          .titleBar({
            content: {
              // 只留主标题：标题栏放两行会把副标题压到玻璃渐隐边上糊掉，
              // 右侧画布空态里已有"点击左侧任意卡片，展开到这里"的引导
              title: {
                mainTitle: '灵感卡片'
              }
            },
            // 标题栏铺满左栏，标题文字靠这个内边距和卡片左边缘对齐
            padding: { start: LengthMetrics.vp(26), end: LengthMetrics.vp(0) },
            style: {
              // 浅色页面用深色标题，不跟着材质走白色
              originalStyle: {
                contentStyle: {
                  titleStyle: {
                    mainTitleColor: '#1A2233'
                  }
                }
              },
              scrollEffectStyle: {
                contentStyle: {
                  titleStyle: {
                    mainTitleColor: '#1A2233'
                  }
                }
              },
              scrollEffectOpts: {
                enableScrollEffect: true,
                // 沉浸渐变模糊：从全透明渐变到模糊，过渡带更大、更通透
                scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
                // 列表很短，让模糊在前 48vp 内就吃满，滚一点就能看出材质
                blurEffectiveStartOffset: LengthMetrics.vp(0),
                blurEffectiveEndOffset: LengthMetrics.vp(48)
              },
              // 沉浸光感材质：类型和强度都交给系统按设备能力选档
              systemMaterialEffect: {
                materialType: hdsMaterial.MaterialType.ADAPTIVE,
                materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
              }
            },
            avoidLayoutSafeArea: false,
            enableComponentSafeArea: false
          })
          // 标题栏的透明度/模糊度跟着这个列表的滚动走
          .bindToScrollable([this.listScroller])
          .titleMode(HdsNavigationTitleMode.FULL)
          .hideBackButton(true)
          // 标题栏本身由上面的浮层渲染，这里只保留滚动联动，避免两层材质叠在一起
          .hideTitleBar(true)
          .mode(NavigationMode.Stack)
          .width('100%')
          .height('100%')
        }
        .width('54%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)

        // ---------------- 右：固定不动的详情画布 ----------------
        Column() {
          Stack({ alignContent: Alignment.Center }) {
            if (this.activeId === '') {
              Column() {
                Stack() {
                  Text('↘')
                    .fontSize(18)
                    .fontColor('#9AA8C0')
                }
                .width(46)
                .height(46)
                .borderRadius(23)
                .backgroundColor('#E4EAF4')

                Text('详情画布')
                  .fontSize(14)
                  .fontColor('#9AA5B8')
                  .margin({ top: 14 })
                Text('点击左侧任意卡片，展开到这里')
                  .fontSize(12)
                  .fontColor('#B6BFCF')
                  .margin({ top: 6 })
              }
            }
          }
          .width('100%')
          .height('100%')
          .borderRadius(this.R_PANEL)
          .backgroundColor('#FAFBFE')
          .border({ width: 1.5, color: '#DCE3EF', style: BorderStyle.Dashed, radius: this.R_PANEL })
          .id('detail-panel')
        }
        .layoutWeight(1)
        .height('100%')
        // 底部再让开悬浮胶囊：画布落在玻璃底栏上方，按钮不会被挡住
        .padding({ left: 14, top: this.padTop, bottom: this.padPanelBottom + BAR_BLOCK, right: 26 })
      }
      .width('100%')
      .height('100%')

      // ============== 飞行层（直接挂在根 Stack 上，动画属性全部在顶层） ==============

      // 退场 · 抬升层
      Column()
        .width(this.exitW)
        .height(this.exitH)
        .borderRadius(this.exitR)
        .clip(true)
        .translate({ x: this.exitX, y: this.exitY })
        .opacity(this.exitE)
        .shadow({ radius: this.SH_R_PANEL, color: this.SH_COLOR, offsetX: 0, offsetY: this.SH_Y_PANEL })
        .linearGradient({
          angle: 135,
          colors: [[getCardById(this.exitingId).c1, 0.0], [getCardById(this.exitingId).c2, 1.0]]
        })
        .visibility(this.exitA > 0 ? Visibility.Visible : Visibility.Hidden)
        .hitTestBehavior(HitTestMode.None)

      // 退场 · 背景：渐变打底，设了壁纸就在上面叠「图 + 同色蒙版」
      // 三层都是页面根 Stack 的同级节点，且全程 opacity 不变 → 收起时不会出现明暗跳变
      Column()
        .width(this.exitW)
        .height(this.exitH)
        .borderRadius(this.exitR)
        .clip(true)
        .translate({ x: this.exitX, y: this.exitY })
        .opacity(this.exitA)
        .shadow({ radius: this.SH_R_TILE, color: this.SH_COLOR, offsetX: 0, offsetY: this.SH_Y_TILE })
        .linearGradient({
          angle: 135,
          colors: [[getCardById(this.exitingId).c1, 0.0], [getCardById(this.exitingId).c2, 1.0]]
        })
        .visibility(this.exitA > 0 ? Visibility.Visible : Visibility.Hidden)
        .hitTestBehavior(HitTestMode.None)
      if (this.wallpaperOf(this.exitingId).length > 0) {
        Image(this.wallpaperOf(this.exitingId))
          .width(this.exitW)
          .height(this.exitH)
          .objectFit(ImageFit.Cover)
          .borderRadius(this.exitR)
          .clip(true)
          .translate({ x: this.exitX, y: this.exitY })
          .opacity(this.exitA)
          .visibility(this.exitA > 0 ? Visibility.Visible : Visibility.Hidden)
          .hitTestBehavior(HitTestMode.None)
        Column()
          .width(this.exitW)
          .height(this.exitH)
          .borderRadius(this.exitR)
          .clip(true)
          .translate({ x: this.exitX, y: this.exitY })
          .opacity(this.exitA)
          .linearGradient({
            angle: 135,
            colors: [
              [this.withAlpha(getCardById(this.exitingId).c1, '59'), 0.0],
              [this.withAlpha(getCardById(this.exitingId).c2, 'A6'), 1.0]
            ]
          })
          .visibility(this.exitA > 0 ? Visibility.Visible : Visibility.Hidden)
          .hitTestBehavior(HitTestMode.None)
      }

      // 退场 · 缩略态（只画内容）
      CardFace({ cardId: this.exitingId, showBackground: false })
        .width(this.exitW)
        .height(this.exitH)
        .borderRadius(this.exitR)
        .clip(true)
        .translate({ x: this.exitX, y: this.exitY })
        .opacity(this.exitA * this.exitP)
        .visibility(this.exitA > 0 ? Visibility.Visible : Visibility.Hidden)
        .hitTestBehavior(HitTestMode.None)

      // 退场 · 详情态（只画内容）
      CardDetail({ cardId: this.exitingId, showBackground: false })
        .width(this.exitW)
        .height(this.exitH)
        .borderRadius(this.exitR)
        .clip(true)
        .translate({ x: this.exitX, y: this.exitY })
        .opacity(this.exitA * this.exitD)
        .visibility(this.exitA > 0 ? Visibility.Visible : Visibility.Hidden)
        .hitTestBehavior(HitTestMode.None)

      // 主卡片 · 抬升层
      Column()
        .width(this.heroW)
        .height(this.heroH)
        .borderRadius(this.heroR)
        .clip(true)
        .translate({ x: this.heroX, y: this.heroY })
        .opacity(this.heroE)
        .shadow({ radius: this.SH_R_PANEL, color: this.SH_COLOR, offsetX: 0, offsetY: this.SH_Y_PANEL })
        .linearGradient({
          angle: 135,
          colors: [[getCardById(this.activeId).c1, 0.0], [getCardById(this.activeId).c2, 1.0]]
        })
        .visibility(this.heroA > 0 ? Visibility.Visible : Visibility.Hidden)

      // 主卡片 · 背景：渐变打底，设了壁纸就在上面叠「图 + 同色蒙版」
      Column()
        .width(this.heroW)
        .height(this.heroH)
        .borderRadius(this.heroR)
        .clip(true)
        .translate({ x: this.heroX, y: this.heroY })
        .opacity(this.heroA)
        .shadow({ radius: this.SH_R_TILE, color: this.SH_COLOR, offsetX: 0, offsetY: this.SH_Y_TILE })
        .linearGradient({
          angle: 135,
          colors: [[getCardById(this.activeId).c1, 0.0], [getCardById(this.activeId).c2, 1.0]]
        })
        .visibility(this.heroA > 0 ? Visibility.Visible : Visibility.Hidden)
      if (this.wallpaperOf(this.activeId).length > 0) {
        Image(this.wallpaperOf(this.activeId))
          .width(this.heroW)
          .height(this.heroH)
          .objectFit(ImageFit.Cover)
          .borderRadius(this.heroR)
          .clip(true)
          .translate({ x: this.heroX, y: this.heroY })
          .opacity(this.heroA)
          .visibility(this.heroA > 0 ? Visibility.Visible : Visibility.Hidden)
        Column()
          .width(this.heroW)
          .height(this.heroH)
          .borderRadius(this.heroR)
          .clip(true)
          .translate({ x: this.heroX, y: this.heroY })
          .opacity(this.heroA)
          .linearGradient({
            angle: 135,
            colors: [
              [this.withAlpha(getCardById(this.activeId).c1, '59'), 0.0],
              [this.withAlpha(getCardById(this.activeId).c2, 'A6'), 1.0]
            ]
          })
          .visibility(this.heroA > 0 ? Visibility.Visible : Visibility.Hidden)
      }

      // 主卡片 · 缩略态（只画内容）
      CardFace({ cardId: this.activeId, showBackground: false })
        .width(this.heroW)
        .height(this.heroH)
        .borderRadius(this.heroR)
        .clip(true)
        .translate({ x: this.heroX, y: this.heroY })
        .opacity(this.heroA * this.heroP)
        .visibility(this.heroA > 0 ? Visibility.Visible : Visibility.Hidden)
        .hitTestBehavior(this.heroP > 0.6 ? HitTestMode.Default : HitTestMode.None)

      // 主卡片 · 详情态（只画内容）
      CardDetail({
        cardId: this.activeId,
        showClose: true,
        showBackground: false,
        onClose: () => {
          this.closeCard();
        }
      })
        .width(this.heroW)
        .height(this.heroH)
        .borderRadius(this.heroR)
        .clip(true)
        .translate({ x: this.heroX, y: this.heroY })
        .opacity(this.heroA * this.heroD)
        .visibility(this.heroA > 0 ? Visibility.Visible : Visibility.Hidden)
        .hitTestBehavior(this.heroD > 0.6 ? HitTestMode.Default : HitTestMode.None)

      // ---------------- 标题栏浮层 ----------------
      // 层级放在所有飞行层之上：卡片从列表飞到右侧时从它下面穿过，不会盖住标题栏。
      // 只占左栏宽度，右侧画布顶部依然没有这层材质。
      HdsNavigation() {
        // 只借导航的标题栏，内容留空
        Column()
          .width('100%')
          .height('100%')
      }
      .titleBar({
        content: {
          title: {
            mainTitle: '灵感卡片'
          }
        },
        padding: { start: LengthMetrics.vp(26), end: LengthMetrics.vp(0) },
        style: {
          originalStyle: {
            contentStyle: {
              titleStyle: {
                mainTitleColor: '#1A2233'
              }
            }
          },
          scrollEffectStyle: {
            contentStyle: {
              titleStyle: {
                mainTitleColor: '#1A2233'
              }
            }
          },
          scrollEffectOpts: {
            enableScrollEffect: true,
            scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
            blurEffectiveStartOffset: LengthMetrics.vp(0),
            blurEffectiveEndOffset: LengthMetrics.vp(48)
          },
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.ADAPTIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          }
        },
        avoidLayoutSafeArea: false,
        enableComponentSafeArea: false
      })
      .bindToScrollable([this.listScroller])
      .titleMode(HdsNavigationTitleMode.FULL)
      .hideBackButton(true)
      .mode(NavigationMode.Stack)
      .width('54%')
      .height('100%')
      // 只负责显示，点击穿透给下面的卡片
      .hitTestBehavior(HitTestMode.Transparent)
      .zIndex(9)
    }
    .id('root-stack')
    .width('100%')
    .height('100%')
    // 根容器也铺一层底色：状态栏/导航条里"窗口自己的"那部分也一起盖掉
    .backgroundColor('#F4F6FB')
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.syncHeroToPanel();
    })
  }

  build() {
    Tabs({ barPosition: BarPosition.End, index: this.currentTabIndex }) {
      TabContent() {
        this.HomePage()
      }
      .tabBar(this.TabBarBuilder(0, $r('sys.symbol.house'), '主页'))

      TabContent() {
        this.ProfilePage()
      }
      .tabBar(this.TabBarBuilder(1, $r('sys.symbol.person'), '个人'))
    }
    // 内容铺到胶囊底下，玻璃才透得出后面的列表；页签栏的模糊、投影、点光源全由系统渲染
    .barOverlap(true)
    .barHeight(BAR_HEIGHT)
    .barFloatingStyle(this.buildFloatingBarStyle())
    .onChange((index: number) => {
      this.currentTabIndex = index;
    })
    .width('100%')
    .height('100%')
    .backgroundColor('#F4F6FB')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
