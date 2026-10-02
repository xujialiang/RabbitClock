import { display, router } from '@kit.ArkUI';
import { SourceKind, Sources, SyncResult, TimeSync, TimeSource } from '../timesync/TimeSync';

/**
 * 时间源页：同步状态卡 + 手动微调 + 源列表。
 * 静态引擎（TimeSync）无响应式，页面每 400ms 轮询镜像到 @State 刷新（与首页模式一致）。
 */
@Entry
@Component
struct TimeSourcePage {
  @State selId: string = Sources.BEIJING;
  @State manualMs: number = 0;
  @State statusTitle: string = '';
  @State statusDetail: string = '';
  @State statusKind: number = 0; // 0 ok / 1 syncing / 2 warn / 3 device
  @State syncingNow: boolean = false;
  @State rowStatus: string[] = [];
  @State rowOk: boolean[] = [];
  @State nowTick: number = 0;
  @State displayLine: string = '';
  @State depth: number = 1;
  private timerId: number = -1;

  aboutToAppear(): void {
    this.refresh();
    TimeSync.ensureFresh();
    this.depth = TimeSync.presentDepth;
    try {
      const d = display.getDefaultDisplaySync();
      const hz = d.refreshRate > 0 ? Math.round(d.refreshRate) : 60;
      const comp = (1000 / hz) * (this.depth + 0.5); // 呈现深度 + 屏高中位扫描
      this.displayLine = `屏幕 ${hz}Hz · 显示延迟已补偿 ≈ ${comp.toFixed(1)}ms（悬浮窗按所在屏幕高度精确补偿）`;
    } catch (e) {
      this.displayLine = '';
    }
    this.timerId = setInterval(() => this.refresh(), 400);
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
    }
  }

  private refresh(): void {
    this.nowTick = Date.now();
    this.selId = TimeSync.selectedId;
    this.manualMs = TimeSync.manualOffsetMs;
    this.syncingNow = TimeSync.syncing.has(this.selId);

    const src = Sources.byId(this.selId);
    if (src.kind === SourceKind.DEVICE) {
      this.statusKind = 3;
      this.statusTitle = '使用设备时间 · 不联网';
      this.statusDetail = '兔时笺与系统时间保持一致';
    } else {
      const r = TimeSync.currentResult();
      const syncing = TimeSync.syncing.has(src.id);
      if (syncing) {
        this.statusKind = 1;
        this.statusTitle = `正在校准 ${src.name}…`;
        this.statusDetail = '正在向时间服务器发起多次采样…';
      } else if (r !== null && r.ok) {
        this.statusKind = 0;
        this.statusTitle = `已校准 ${src.name} · ${TimeSync.fmtAgo(r.atWall, this.nowTick)}`;
        let detail = `偏差 ${TimeSync.fmtOffset(r.offsetMs)}`;
        if (this.manualMs !== 0) {
          detail += ` · 微调 ${TimeSync.fmtManual(this.manualMs)}`;
        }
        detail += '\n显示时间 = 设备时间 + 以上偏移 · ';
        if (src.kind === SourceKind.DATE) {
          detail += `秒沿窗口 ${r.rttMs}ms`;
        } else if (src.kind === SourceKind.SNTP) {
          detail += `RTT ${r.rttMs}ms · ${r.ntp ? 'NTP 直连' : 'HTTP 回落'}`;
        } else {
          detail += `RTT ${r.rttMs}ms`;
        }
        this.statusDetail = detail;
      } else {
        this.statusKind = 2;
        this.statusTitle = `${src.name} · 未校准`;
        this.statusDetail = `点击下方「立即校准」获取与 ${src.name} 服务器的偏差`;
      }
    }

    const st: string[] = [];
    const ok: boolean[] = [];
    for (const s of Sources.ALL) {
      const r: SyncResult | undefined = TimeSync.results.get(s.id);
      if (s.kind === SourceKind.DEVICE) {
        st.push('跟随本机');
        ok.push(true);
      } else if (TimeSync.syncing.has(s.id)) {
        st.push('校准中');
        ok.push(false);
      } else if (r !== undefined && r.ok) {
        st.push(TimeSync.fmtOffset(r.offsetMs));
        ok.push(true);
      } else {
        st.push(r !== undefined ? '失败·重试' : '未校准');
        ok.push(false);
      }
    }
    this.rowStatus = st;
    this.rowOk = ok;
  }

  private dotColor(): string {
    if (this.statusKind === 0) {
      return '#34D399';
    }
    if (this.statusKind === 1) {
      return '#22D3EE';
    }
    if (this.statusKind === 3) {
      return '#92A0BA';
    }
    return '#FFB454';
  }

  build() {
    Scroll() {
      Column() {
        // ── 顶栏 ──
        Row() {
          Text('‹')
            .fontSize(26)
            .fontColor('#22D3EE')
            .padding({ left: 10, right: 10, top: 2, bottom: 2 })
            .onClick(() => router.back())
          Text('时间源')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('color.text_main'))
            .layoutWeight(1)
          Text('?')
            .fontSize(15)
            .fontColor($r('color.text_sub'))
            .padding(8)
            .onClick(() => this.showHelp())
        }
        .width('100%')
        .margin({ top: 18 })

        // ── 同步状态卡 ──
        Column() {
          Row() {
            Circle({ width: 8, height: 8 }).fill(this.dotColor())
            Text(' ' + this.statusTitle)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('color.text_main'))
              .layoutWeight(1)
          }
          .width('100%')

          Text(this.statusDetail)
            .fontSize(12)
            .fontColor($r('color.text_sub'))
            .margin({ top: 8 })
            .width('100%')

          if (this.displayLine !== '') {
            Text(this.displayLine)
              .fontSize(11)
              .fontColor($r('color.text_sub'))
              .margin({ top: 6 })
              .width('100%')
          }

          if (this.selId !== Sources.DEVICE) {
            Button(this.syncingNow ? '校准中…' : '立即校准')
              .fontSize(14)
              .backgroundColor(this.syncingNow ? '#1AFFFFFF' : '#22D3EE')
              .fontColor(this.syncingNow ? $r('color.text_sub') : '#04101C')
              .margin({ top: 10 })
              .enabled(!this.syncingNow)
              .onClick(() => TimeSync.requestSync(this.selId))
          }
        }
        .alignItems(HorizontalAlign.Start)
        .padding(14)
        .width('100%')
        .backgroundColor($r('color.card_bg'))
        .borderRadius(18)
        .margin({ top: 10 })

        // ── 手动调整时间 ──
        Text('手动调整时间')
          .fontSize(13)
          .fontColor($r('color.text_sub'))
          .margin({ top: 18, bottom: 6 })

        Row() {
          Column() {
            Text('手动微调').fontSize(14).fontColor($r('color.text_main'))
            Text('每次 ±10 毫秒 · 在校准偏差上叠加')
              .fontSize(11).fontColor($r('color.text_sub')).margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          this.NudgeBtn('−', () => TimeSync.nudgeManual(-TimeSync.MANUAL_STEP_MS))
          Text(TimeSync.fmtManual(this.manualMs))
            .fontSize(14)
            .fontFamily('monospace')
            .fontColor(this.manualMs === 0 ? $r('color.text_sub') : '#22D3EE')
            .textAlign(TextAlign.Center)
            .width(86)
          this.NudgeBtn('+', () => TimeSync.nudgeManual(TimeSync.MANUAL_STEP_MS))
        }
        .width('100%')
        .padding(14)
        .backgroundColor($r('color.card_bg'))
        .borderRadius(18)

        if (this.manualMs !== 0) {
          Text('重置微调')
            .fontSize(12)
            .fontColor('#22D3EE')
            .alignSelf(ItemAlign.End)
            .margin({ top: 6 })
            .onClick(() => TimeSync.resetManual())
        }

        // ── 显示补偿深度 ──
        Text('显示补偿深度')
          .fontSize(13)
          .fontColor($r('color.text_sub'))
          .margin({ top: 18, bottom: 6 })

        Column() {
          Text('呈现深度').fontSize(14).fontColor($r('color.text_main'))
          Text('悬浮窗经系统合成器叠加的路径偶有 2 帧深度。若真机上时钟整体偏快/偏慢约 1 帧，可在此调大；不确定就保持 1 帧')
            .fontSize(11).fontColor($r('color.text_sub')).margin({ top: 2, bottom: 8 })
          Row({ space: 8 }) {
            ForEach([1, 1.5, 2], (d: number) => {
              Text(d === 1 ? '1 帧' : (d === 1.5 ? '1.5 帧' : '2 帧'))
                .fontSize(12)
                .fontColor(this.depth === d ? '#04101C' : $r('color.text_sub'))
                .backgroundColor(this.depth === d ? '#22D3EE' : '#14FFFFFF')
                .borderRadius(99)
                .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .onClick(() => {
                  TimeSync.presentDepth = d;
                  this.depth = d;
                  TimeSync.persist();
                })
            })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .padding(14)
        .width('100%')
        .backgroundColor($r('color.card_bg'))
        .borderRadius(18)

        // ── 时间源列表 ──
        Text('时间源')
          .fontSize(13)
          .fontColor($r('color.text_sub'))
          .margin({ top: 18, bottom: 6 })

        ForEach(Sources.ALL, (s: TimeSource, idx: number) => {
          Row() {
            Stack({ alignContent: Alignment.Center }) {
              Circle({ width: 18, height: 18 })
                .fill(Color.Transparent)
                .stroke(this.selId === s.id ? '#22D3EE' : '#55FFFFFF')
                .strokeWidth(1.5)
              if (this.selId === s.id) {
                Circle({ width: 9, height: 9 }).fill('#22D3EE')
              }
            }
            Column() {
              Row() {
                Text(s.name).fontSize(15).fontColor($r('color.text_main'))
                if (s.id === Sources.BEIJING) {
                  Text(' 默认')
                    .fontSize(10)
                    .fontColor('#04101C')
                    .backgroundColor('#D922D3EE')
                    .borderRadius(6)
                    .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                }
              }
              Text(s.sub).fontSize(11).fontColor($r('color.text_sub')).margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            .margin({ left: 12 })

            Text(this.rowStatus[idx] ?? '未校准')
              .fontSize(12)
              .fontFamily('monospace')
              .fontColor(this.rowOk[idx] ? '#7EF0C5' : $r('color.text_sub'))
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 12, bottom: 12 })
          .backgroundColor(this.selId === s.id ? '#1A22D3EE' : '#0DFFFFFF')
          .borderRadius(16)
          .border({
            width: 1,
            color: this.selId === s.id ? '#7322D3EE' : '#1FFFFFFF',
          })
          .margin({ top: 4, bottom: 4 })
          .onClick(() => TimeSync.select(s.id))
        }, (s) => s.id)

        Text('「北京时间」优先 NTP 直连国家授时中心（UDP 被网络拦截时自动回落 HTTP，精度降为 ±0.1s）；接口类源（淘宝/大麦）约 ±0.02s；其余 Date 头源约 ±0.05~0.1s（预测秒沿 + 突发轮询）。高精度源在两次校准之间还会按本机晶振漂移自动外推。')
          .fontSize(11)
          .fontColor($r('color.text_sub'))
          .margin({ top: 10, bottom: 40 })
      }
      .padding({ left: 16, right: 16 })
      .alignItems(HorizontalAlign.Start)
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
    .backgroundColor($r('color.page_bg'))
  }

  @Builder
  NudgeBtn(label: string, onTap: () => void) {
    Text(label)
      .fontSize(18)
      .fontColor($r('color.text_main'))
      .width(34)
      .height(34)
      .textAlign(TextAlign.Center)
      .backgroundColor('#1AFFFFFF')
      .borderRadius(99)
      .border({ width: 1, color: '#33FFFFFF' })
      .onClick(() => onTap())
  }

  private showHelp(): void {
    AlertDialog.show({
      title: '关于时间源',
      message: '兔时笺默认显示北京时间（国家授时中心）。\n\n' +
        '· 校准原理：向所选服务器发起请求，用往返时延的一半修正服务器时间，得到与本机的偏差；显示时间 = 设备时间 + 偏差。\n' +
        '· 显示延迟补偿：每帧按屏幕刷新率与悬浮窗所在高度，把显示值前移「1 个呈现周期 + 面板扫描延迟」（60Hz 约 17~25ms、120Hz 减半），使「看到的时刻」≈ 真实时刻。\n' +
        '· 手动微调在校准偏差上叠加，适合「故意提前/延后」的场景。\n' +
        '· 校准时机：打开本页、切换源、开启悬浮窗、回到前台时进行（10 分钟内不重复），应用存活期间每 10 分钟自动补一次；新鲜时不发任何请求。',
      alignment: DialogAlignment.Bottom,
      primaryButton: {
        value: '知道了',
        action: () => {
        },
      },
    });
  }
}
