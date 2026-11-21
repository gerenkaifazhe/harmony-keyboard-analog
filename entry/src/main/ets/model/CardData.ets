/**
 * 卡片数据模型
 */

/** 连接历史里的一个设备 */
export class HistoryDevice {
  id: string;
  name: string;
  /** 主动回连开关的初始值 */
  autoReconnect: boolean;

  constructor(id: string, name: string, autoReconnect: boolean) {
    this.id = id;
    this.name = name;
    this.autoReconnect = autoReconnect;
  }
}

export class CardItem {
  id: string;
  index: string;
  title: string;
  subtitle: string;
  tag: string;
  desc: string;
  meta1: string;
  meta2: string;
  c1: string;
  c2: string;
  /** 连接历史：数量可变，空数组时详情页显示"暂无历史设备" */
  history: HistoryDevice[] = [];
  /** 蓝牙键盘卡片：详情页走真实的 HID 模拟逻辑，历史设备来自系统蓝牙 */
  isKeyboard: boolean = false;
  /** 标题用本机蓝牙设备名（从系统蓝牙接口动态读取），而不是这里的 title 常量 */
  titleUseLocalBtName: boolean = false;

  constructor(id: string, index: string, title: string, subtitle: string, tag: string,
              desc: string, meta1: string, meta2: string, c1: string, c2: string) {
    this.id = id;
    this.index = index;
    this.title = title;
    this.subtitle = subtitle;
    this.tag = tag;
    this.desc = desc;
    this.meta1 = meta1;
    this.meta2 = meta2;
    this.c1 = c1;
    this.c2 = c2;
  }
}

export class CardRow {
  items: CardItem[];
  height: number;

  constructor(items: CardItem[], height: number) {
    this.items = items;
    this.height = height;
  }
}

export const EMPTY_CARD: CardItem =
  new CardItem('', '00', '', '', '', '', '', '', '#E8EDF5', '#DDE4EF');

const C1: CardItem = new CardItem('c1', '01', '星河漫游', '深空配色与构图实验',
  '视觉设计', '把夜晚的天空拆成一层层可复用的色阶，用低饱和的蓝紫做底，让高亮的星点点缀其间，形成有呼吸感的视觉节奏。',
  '24 张图片', '昨天更新', '#6C8CFF', '#3B5BDB');
// 页面顶部这张通栏大卡片，标题实时显示本机蓝牙设备名（系统蓝牙接口读取）
C1.titleUseLocalBtName = true;

const C2: CardItem = new CardItem('c2', '02', '蓝牙键盘', '平板即刻变成键盘',
  '外设', '开启模拟后本机注册为标准 HID 键盘，电脑在蓝牙列表里就能搜到并连上来打字。',
  'HID', 'HID over GATT', '#5FD3B2', '#23A183');
// 这一张是真实的蓝牙键盘卡片，详情页用系统蓝牙数据而不是示例历史
C2.isKeyboard = true;

const C3: CardItem = new CardItem('c3', '03', '暖阳', '橘色系插画练习',
  '插画', '用大面积的暖橘和奶油白做出午后阳光的质感，边缘使用颗粒笔刷保留手绘的粗糙感，整体偏安静。',
  '12 张图片', '5 天前', '#FFB366', '#F2762E');

const C4: CardItem = new CardItem('c4', '04', '潮汐', '动效曲线笔记',
  '动效', '记录几种常用的缓动曲线在手势跟随场景下的表现，重点比较弹簧曲线与贝塞尔曲线在收尾阶段的差异。',
  '9 个示例', '1 周前', '#6EC5FF', '#2A86D8');

const C5: CardItem = new CardItem('c5', '05', '苔原', '北方的低矮植物',
  '自然', '苔藓、地衣与碎石构成的微观地貌，颜色集中在橄榄绿与灰褐之间，适合作为中性色的配色参考。',
  '30 张图片', '1 周前', '#9BD25F', '#5C9B2E');

const C6: CardItem = new CardItem('c6', '06', '霓虹夜市', '城市夜色的色彩切片',
  '城市', '高饱和的紫与洋红在湿漉漉的地面上反射，招牌的暖光把画面切成明暗两块，是很典型的赛博感构图。',
  '21 张图片', '2 周前', '#C08BFF', '#7A45D6');

const C7: CardItem = new CardItem('c7', '07', '花火', '夏日祭的瞬间',
  '节庆', '长曝光把烟花的轨迹拉成细线，人群的剪影在画面底部形成稳定的水平线，热闹但不杂乱。',
  '16 张图片', '2 周前', '#FF87A8', '#E14A76');

const C8: CardItem = new CardItem('c8', '08', '琥珀', '金色材质研究',
  '材质', '半透明材质的渲染笔记：折射率、粗糙度与内部散射三者的关系，附带一组可直接复用的参数。',
  '7 个材质', '3 周前', '#FFD166', '#E9A21A');

const C9: CardItem = new CardItem('c9', '09', '静谧书房', '工作空间整理',
  '空间', '原木、亚麻与冷灰的搭配，把视觉重心留在桌面中央的一小块区域，其余部分尽量做减法。',
  '11 张图片', '1 个月前', '#8FA6C4', '#5A6E8C');

export const CARDS: CardItem[] = [C1, C2, C3, C4, C5, C6, C7, C8, C9];

// 连接历史示例数据：每张卡片的设备数量刻意不同，
// 覆盖「不需要滚动」「需要滚动」「一条都没有」三种情况
C1.history = [
  new HistoryDevice('c1-1', 'MatePad Pro 13', true),
  new HistoryDevice('c1-2', 'MateBook X Pro', true),
  new HistoryDevice('c1-3', 'ThinkPad X1 Carbon', false),
  new HistoryDevice('c1-4', 'iMac 27 英寸', true),
  new HistoryDevice('c1-5', 'MacBook Air M2', false),
  new HistoryDevice('c1-6', 'Windows 台式机', true),
  new HistoryDevice('c1-7', 'Studio Display', false),
  new HistoryDevice('c1-8', '小米笔记本 Pro', true),
  new HistoryDevice('c1-9', 'iPad Pro 11', false),
  new HistoryDevice('c1-10', '办公室会议屏', true)
];

// 蓝牙键盘卡片不用示例历史，列表内容来自系统蓝牙（KeyboardBridge 写入 AppStorage）
C2.history = [];

// 这张卡片没有历史设备，用来展示空态
C3.history = [];

C4.history = [
  new HistoryDevice('c4-1', 'MatePad Pro 13', true),
  new HistoryDevice('c4-2', 'Mac mini', true),
  new HistoryDevice('c4-3', 'Dell U2723QE', false),
  new HistoryDevice('c4-4', 'Pixelbook', false),
  new HistoryDevice('c4-5', '卧室一体机', true),
  new HistoryDevice('c4-6', '会议室投影', false)
];

C5.history = [
  new HistoryDevice('c5-1', 'Blackmagic 监看屏', true),
  new HistoryDevice('c5-2', 'MacBook Pro 16', true)
];

C6.history = [
  new HistoryDevice('c6-1', 'MateBook X Pro', true),
  new HistoryDevice('c6-2', 'ROG 幻 16', true),
  new HistoryDevice('c6-3', 'LG UltraFine', false),
  new HistoryDevice('c6-4', 'NUC 迷你主机', false),
  new HistoryDevice('c6-5', 'Studio Display', true),
  new HistoryDevice('c6-6', 'MacBook Air M2', false),
  new HistoryDevice('c6-7', '客厅电视', true)
];

C7.history = [
  new HistoryDevice('c7-1', 'MatePad Pro 13', true)
];

C8.history = [];

C9.history = [
  new HistoryDevice('c9-1', 'iMac 27 英寸', true),
  new HistoryDevice('c9-2', 'MacBook Pro 14', true),
  new HistoryDevice('c9-3', 'ThinkPad X1 Carbon', false),
  new HistoryDevice('c9-4', '打印机工位主机', false),
  new HistoryDevice('c9-5', 'Surface Studio', true)
];

/** 第一行通栏，其余两列排布，和草图一致 */
export const CARD_ROWS: CardRow[] = [
  new CardRow([C1], 196),
  new CardRow([C2, C3], 172),
  new CardRow([C4, C5], 172),
  new CardRow([C6, C7], 172),
  new CardRow([C8, C9], 172)
];

export function getCardById(id: string): CardItem {
  for (let i = 0; i < CARDS.length; i++) {
    if (CARDS[i].id === id) {
      return CARDS[i];
    }
  }
  return EMPTY_CARD;
}

/** 读不到蓝牙名（蓝牙关闭 / 未授予权限）时的占位标题 */
export const LOCAL_BT_NAME_PLACEHOLDER: string = '本机蓝牙设备';

/**
 * 卡片标题：需要显示本机蓝牙名的卡片优先用系统蓝牙名，
 * 读不到时退回占位文案；其余卡片仍用各自的 title 常量。
 */
export function getCardTitle(card: CardItem, localBtName: string): string {
  if (!card.titleUseLocalBtName) {
    return card.title;
  }
  return localBtName.length > 0 ? localBtName : LOCAL_BT_NAME_PLACEHOLDER;
}
