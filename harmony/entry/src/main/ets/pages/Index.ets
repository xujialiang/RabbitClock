import { abilityAccessCtrl, bundleManager, common, Permissions } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { AppState, Prefs, Style, BgKind } from '../data/Prefs';
import { FloatWindowController } from '../float/FloatWindowController';
import { Mode, RunState, fmtClock, fmtStopwatch, fmtCountdown, dateLine, weekLine } from '../engine/TimerEngine';
import { ReminderHelper } from '../reminder/ReminderHelper';
import { SourceKind, Sources, TimeSync } from '../timesync/TimeSync';

const FLOAT_PERMISSION: Permissions = 'ohos.permission.FLOAT_WINDOW';
const PRESET_COLORS: string[] = ['#22D3EE', '#F4F7FF', '#FFB454', '#FF6B6B', '#34D399', '#A78BFA'];
const PRESET_MINUTES: number[] = [1, 3, 5, 10, 25, 60];
const BG_LABELS: string[] = ['胶囊', '方卡', '描边'];
const BG_KINDS: BgKind[] = [BgKind.CAPSULE, BgKind.CARD, BgKind.OUTLINE];

@Entry
@Component
struct Index {
  @State nowWall: number = Date.now();
  @State permGranted: boolean = false;
  @State floatVisible: boolean = false;
  @State bigClock: string = '--:--';
  @State swText: string = '00:00.000';
  @State swBtnLabel: string = '启动';
  @State cdText: string = '05:00';
  @State cdBtnLabel: string = '开始';
  @State cdChipMin: number = 5;
  @State mode: Mode = Mode.CLOCK;
  @State displayDateLine: string = '';
  private timerId: number = -1;
  private cdDialog: CustomDialogController = new CustomDialogController({
    builder: CustomMinDialog({
      setMin: (m: number) => {
        this.cdChipMin = m;
        AppState.cdTotalMin = m;
        AppState.countdown.setTotal(m * 60 * 1000);
        ReminderHelper.cancel();
      },
    }),
    autoCancel: true,
  });

  aboutToAppear(): void {
    this.syncFromAppState();
    this.refreshPermStatus();
    this.timerId = setInterval(() => {
      this.nowWall = Date.now();
      this.renderTick();
    }, 200);
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
    }
  }

  private syncFromAppState(): void {
    this.floatVisible = AppState.floatVisible;
    this.mode = AppState.mode;
    this.cdChipMin = AppState.cdTotalMin;
  }

  private refreshPermStatus(): void {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const bundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const tokenId = bundleInfo.applicationInfo.accessTokenId;
      this.permGranted = atManager.checkAccessToken(tokenId, FLOAT_PERMISSION) === 0;
    } catch (e) {
      console.error(`[perm] check failed: ${e instanceof Error ? e.message : ''}`);
    }
  }

  private async requestFloatPermission(): Promise<void> {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) {
      promptAction.showToast({ message: '初始化中，请稍后再试' });
      return;
    }
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const result = await atManager.requestPermissionsFromUser(ctx, [FLOAT_PERMISSION]);
      this.permGranted = result.authResults.length > 0 && result.authResults[0] === 0;
      if (!this.permGranted) {
        promptAction.showToast({ message: '可在 设置 › 应用 › 悬浮时钟 中开启悬浮窗' });
      }
    } catch (e) {
      console.error(`[perm] request failed: ${e instanceof Error ? e.message : ''}`);
    }
  }

  private async toggleFloat(): Promise<void> {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) {
      return;
    }
    if (this.floatVisible) {
      this.floatVisible = false;
      AppState.floatVisible = false;
      await FloatWindowController.destroy();
    } else {
      if (!this.permGranted) {
        await this.requestFloatPermission();
        this.refreshPermStatus();
        if (!this.permGranted) {
          promptAction.showToast({ message: '需要先允许悬浮窗权限' });
          return;
        }
      }
      const ok = await FloatWindowController.show(ctx);
      if (ok) {
        this.floatVisible = true;
        AppState.floatVisible = true;
        TimeSync.ensureFresh(); // 悬浮窗常显场景：过期则后台补校准
      }
    }
  }

  private renderTick(): void {
    // 大时钟与日期行取时间源校准后的「显示时间」；秒表/倒计时是时长语义，仍用系统时钟
    const displayNow = TimeSync.now();
    const p = fmtClock(AppState.style.hour24, true, 0, displayNow);
    this.bigClock = p.main + p.sec;
    this.displayDateLine = dateLine(displayNow) + ' ' + weekLine(displayNow);
    const sw = fmtStopwatch(AppState.stopwatch.elapsed(this.nowWall), Math.max(1, AppState.style.millisDigits));
    this.swText = sw.main + sw.ms;
    this.swBtnLabel = AppState.stopwatch.running ? '暂停'
      : (AppState.stopwatch.elapsed(this.nowWall) > 0 ? '继续' : '启动');
    this.cdText = fmtCountdown(AppState.countdown.remain(this.nowWall));
    this.cdBtnLabel = AppState.countdown.state === RunState.RUNNING ? '暂停'
      : (AppState.countdown.state === RunState.PAUSED ? '继续'
        : (AppState.countdown.state === RunState.FINISHED ? '重新开始' : '开始'));
  }

  build() {
    Tabs({ barPosition: BarPosition.End }) {
      TabContent() {
        this.TimerTab()
      }
      .tabBar('计时')

      TabContent() {
        StyleTab()
      }
      .tabBar('样式')

      TabContent() {
        MeTab()
      }
      .tabBar('我的')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('color.page_bg'))
  }

  @Builder
  TimerTab() {
    Scroll() {
      Column() {
        Row() {
          Column() {
            Text('兔时笺').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('color.text_main'))
            Text(this.displayDateLine)
              .fontSize(12).fontColor($r('color.text_sub')).margin({ top: 3 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text(this.permGranted ? '● 悬浮窗已开启' : '● 去开启悬浮窗')
            .fontSize(11)
            .fontColor(this.permGranted ? '#7EF0C5' : '#FFB454')
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .backgroundColor(this.permGranted ? '#2234D399' : '#2FFFB454')
            .borderRadius(99)
            .onClick(() => this.requestFloatPermission())
        }
        .width('100%')
        .padding({ top: 18 })

        Text(this.bigClock)
          .fontSize(54)
          .fontFamily('monospace')
          .fontWeight(FontWeight.Bold)
          .fontColor($r('color.text_main'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
          .onClick(() => {
            // 点击大钟切回时钟模式（秒表/倒计时模式下唯一的返回入口）
            if (AppState.mode !== Mode.CLOCK) {
              this.mode = Mode.CLOCK;
              AppState.mode = Mode.CLOCK;
            }
          })

        // 时间源状态（点击进设置页）
        Text(this.tsPillText())
          .fontSize(11)
          .fontColor('#7EDCE8')
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .backgroundColor('#1422D3EE')
          .borderRadius(99)
          .border({ width: 1, color: '#4022D3EE' })
          .margin({ top: 2, bottom: 8 })
          .onClick(() => router.pushUrl({ url: 'pages/TimeSourcePage' }))

        // 非时钟模式提示：悬浮窗正显示秒表/倒计时，点大钟切回
        if (this.mode !== Mode.CLOCK) {
          Text(`悬浮窗正在显示${this.mode === Mode.STOPWATCH ? '秒表' : '倒计时'} · 点击大钟切回时钟`)
            .fontSize(11)
            .fontColor($r('color.text_sub'))
            .margin({ bottom: 4 })
        }

        Row() {
          Column() {
            Text('悬浮窗').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('color.text_main'))
            Text(this.floatVisible ? '显示中 · 可切到其它应用查看' : '在任意界面悬浮显示')
              .fontSize(12).fontColor($r('color.text_sub')).margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.floatVisible })
            .onChange(() => this.toggleFloat())
        }
        .width('100%')
        .padding(14)
        .backgroundColor($r('color.card_bg'))
        .borderRadius(18)
        .margin({ top: 8 })

        // 秒表卡
        Column() {
          Row() {
            Circle({ width: 10, height: 10 }).fill('#34D399')
            Text(' 秒表').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('color.text_main'))
              .layoutWeight(1)
            if (this.mode === Mode.STOPWATCH) {
              Text('悬浮中').fontSize(11).fontColor('#34D399')
            }
          }
          .width('100%')
          .onClick(() => {
            this.mode = Mode.STOPWATCH;
            AppState.mode = Mode.STOPWATCH;
          })

          Text(this.swText)
            .fontSize(34)
            .fontFamily('monospace')
            .fontWeight(FontWeight.Bold)
            .fontColor($r('color.text_main'))
            .margin({ top: 6, bottom: 6 })
          Row({ space: 10 }) {
            Button(this.swBtnLabel)
              .backgroundColor('#34D399')
              .fontColor('#04101C')
              .onClick(() => {
                this.mode = Mode.STOPWATCH;
                AppState.mode = Mode.STOPWATCH;
                AppState.stopwatch.startOrPause(Date.now());
              })
            Button('重置')
              .backgroundColor('#1AFFFFFF')
              .fontColor($r('color.text_main'))
              .onClick(() => AppState.stopwatch.reset())
          }
        }
        .alignItems(HorizontalAlign.Start)
        .padding(14)
        .width('100%')
        .backgroundColor(this.mode === Mode.STOPWATCH ? '#1434D399' : '#0DFFFFFF')
        .borderRadius(18)
        .border({ width: 1, color: this.mode === Mode.STOPWATCH ? '#7334D399' : '#1FFFFFFF' })
        .margin({ top: 10 })

        // 倒计时卡
        Column() {
          Row() {
            Circle({ width: 10, height: 10 }).fill('#FFB454')
            Text(' 倒计时').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('color.text_main'))
              .layoutWeight(1)
            if (this.mode === Mode.COUNTDOWN) {
              Text('悬浮中').fontSize(11).fontColor('#FFB454')
            }
          }
          .width('100%')
          .onClick(() => {
            this.mode = Mode.COUNTDOWN;
            AppState.mode = Mode.COUNTDOWN;
          })

          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(PRESET_MINUTES, (m: number) => {
              Text(`${m}′`)
                .fontSize(12)
                .fontColor(this.cdChipMin === m ? '#04101C' : $r('color.text_sub'))
                .backgroundColor(this.cdChipMin === m ? '#FFB454' : '#14FFFFFF')
                .borderRadius(99)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .margin(4)
                .onClick(() => {
                  this.cdChipMin = m;
                  AppState.cdTotalMin = m;
                  AppState.countdown.setTotal(m * 60 * 1000);
                  ReminderHelper.cancel();
                })
            })
            Text(this.isCustomCd() ? `自定义 ${AppState.cdTotalMin}′` : '自定义')
              .fontSize(12)
              .fontColor(this.isCustomCd() ? '#04101C' : $r('color.text_sub'))
              .backgroundColor(this.isCustomCd() ? '#FFB454' : '#14FFFFFF')
              .borderRadius(99)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .margin(4)
              .onClick(() => this.cdDialog.open())
          }
          .margin({ top: 6 })

          Row() {
            Text(this.cdText)
              .fontSize(30)
              .fontFamily('monospace')
              .fontWeight(FontWeight.Bold)
              .fontColor($r('color.text_main'))
              .layoutWeight(1)
            Button(this.cdBtnLabel)
              .backgroundColor('#FFB454')
              .fontColor('#04101C')
              .onClick(() => this.onCdButton())
          }
          .margin({ top: 8 })
        }
        .alignItems(HorizontalAlign.Start)
        .padding(14)
        .width('100%')
        .backgroundColor(this.mode === Mode.COUNTDOWN ? '#14FFB454' : '#0DFFFFFF')
        .borderRadius(18)
        .border({ width: 1, color: this.mode === Mode.COUNTDOWN ? '#73FFB454' : '#1FFFFFFF' })
        .margin({ top: 10 })

        Text('提示：建议在最近任务中下拉加锁、允许后台运行，可提升退后台后悬浮窗的持续时长（不影响倒计时到点提醒）')
          .fontSize(11)
          .fontColor($r('color.text_sub'))
          .margin({ top: 10, bottom: 24 })
          .width('100%')
      }
      .padding({ left: 16, right: 16 })
      .alignItems(HorizontalAlign.Start)
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
  }

  private onCdButton(): void {
    this.mode = Mode.COUNTDOWN;
    AppState.mode = Mode.COUNTDOWN;
    const cd = AppState.countdown;
    if (cd.state === RunState.IDLE || cd.state === RunState.PAUSED) {
      if (cd.state === RunState.IDLE) {
        cd.setTotal(this.cdChipMin * 60 * 1000);
      }
      const endWall = cd.start(Date.now());
      ReminderHelper.scheduleCountdown(endWall);
    } else if (cd.state === RunState.RUNNING) {
      cd.pause(Date.now());
      ReminderHelper.cancel();
    } else {
      cd.reset();
      ReminderHelper.cancel();
    }
  }

  /** 首页大钟下方的时间源状态胶囊文案 */
  private tsPillText(): string {
    const src = Sources.byId(TimeSync.selectedId);
    if (src.kind === SourceKind.DEVICE) {
      return '⏱ 设备时间';
    }
    const r = TimeSync.currentResult();
    if (r !== null && r.ok) {
      return `⏱ ${src.name} · ${TimeSync.fmtOffset(r.offsetMs)}`;
    }
    return `⏱ ${src.name} · 待校准`;
  }

  private isCustomCd(): boolean {
    return PRESET_MINUTES.indexOf(AppState.cdTotalMin) < 0;
  }
}

/** 自定义倒计时分钟数弹窗（@CustomDialog，TextInput 数字键盘） */
@CustomDialog
struct CustomMinDialog {
  controller?: CustomDialogController;
  private txt: string = '';
  setMin: (m: number) => void = (_m: number) => {
  };

  build() {
    Column({ space: 14 }) {
      Text('自定义倒计时').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('color.text_main'))
      TextInput({ placeholder: '分钟（1 ~ 9999）' })
        .type(InputType.Number)
        .width('100%')
        .onChange((v: string) => {
          this.txt = v;
        })
      Row({ space: 10 }) {
        Button('取消')
          .fontSize(14)
          .backgroundColor('#1AFFFFFF')
          .fontColor($r('color.text_main'))
          .layoutWeight(1)
          .onClick(() => {
            if (this.controller) {
              this.controller.close();
            }
          })
        Button('设置')
          .fontSize(14)
          .backgroundColor('#FFB454')
          .fontColor('#04101C')
          .layoutWeight(1)
          .onClick(() => {
            const m = Number(this.txt);
            if (Number.isFinite(m) && m >= 1 && m <= 9999) {
              this.setMin(Math.floor(m));
              if (this.controller) {
                this.controller.close();
              }
            }
          })
      }
      .width('100%')
    }
    .padding(20)
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/** 样式页：本地 @State 镜像 + 写穿到 AppState/Prefs，保证 UI 即时刷新 */
@Component
struct StyleTab {
  @State curColor: string = AppState.style.color;
  @State bgIdx: number = 0;
  @State scaleV: number = AppState.style.scale;
  @State opacityV: number = AppState.style.opacity;
  @State elemSec: boolean = AppState.style.showSeconds;
  @State elemMs: boolean = AppState.style.showMillis;
  @State msDigits: number = AppState.style.millisDigits;
  @State elemDate: boolean = AppState.style.showDate;
  @State elemWeek: boolean = AppState.style.showWeek;
  @State elemBatt: boolean = AppState.style.showBattery;

  aboutToAppear(): void {
    this.reload();
  }

  reload(): void {
    const s = AppState.style;
    this.curColor = s.color;
    this.bgIdx = BG_KINDS.indexOf(s.bg);
    this.scaleV = s.scale;
    this.opacityV = s.opacity;
    this.elemSec = s.showSeconds;
    this.elemMs = s.showMillis;
    this.msDigits = s.millisDigits;
    this.elemDate = s.showDate;
    this.elemWeek = s.showWeek;
    this.elemBatt = s.showBattery;
  }

  private save(mutate: (s: Style) => void): void {
    const s = AppState.style;
    mutate(s);
    Prefs.saveStyle(s);
  }

  build() {
    Scroll() {
      Column() {
        Text('样式').fontSize(22).fontWeight(FontWeight.Bold)
          .fontColor($r('color.text_main')).margin({ top: 18, bottom: 12 })

        Column() {
          Text(this.previewText())
            .fontSize(24 * this.scaleV)
            .fontFamily('monospace')
            .fontWeight(FontWeight.Bold)
            .fontColor(this.curColor)
        }
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .backgroundColor(this.bgIdx === 2 ? Color.Transparent : '#D9080C18')
        .borderRadius(this.bgIdx === 0 ? 999 : 16)
        .border({ width: 1, color: this.bgIdx === 2 ? Color.Transparent : ('59' + this.curColor) })
        .opacity(this.opacityV)

        this.SectionTitle('主题色')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(PRESET_COLORS, (c: string) => {
            Circle({ width: 26, height: 26 })
              .fill(c)
              .stroke(this.curColor === c ? '#FFFFFF' : '#33FFFFFF')
              .strokeWidth(this.curColor === c ? 2.5 : 1)
              .margin(6)
              .onClick(() => {
                this.save((s: Style) => {
                  s.color = c;
                });
                this.curColor = c;
              })
          })
        }

        this.SectionTitle('背景')
        Row({ space: 8 }) {
          ForEach(BG_LABELS, (label: string, idx: number) => {
            Text(label)
              .fontSize(12)
              .fontColor(this.bgIdx === idx ? '#04101C' : $r('color.text_sub'))
              .backgroundColor(this.bgIdx === idx ? '#22D3EE' : '#14FFFFFF')
              .borderRadius(99)
              .padding({ left: 14, right: 14, top: 7, bottom: 7 })
              .onClick(() => {
                this.save((s: Style) => {
                  s.bg = BG_KINDS[idx];
                });
                this.bgIdx = idx;
              })
          })
        }

        this.SectionTitle(`大小  ${this.scaleV.toFixed(2)}×`)
        Slider({ value: this.scaleV, min: 0.7, max: 3.8 })
          .selectedColor('#22D3EE')
          .trackColor('#1FFFFFFF')
          .onChange((v: number) => {
            const clamped = Math.min(3.8, Math.max(0.7, v));
            this.scaleV = clamped;
            this.save((s: Style) => {
              s.scale = clamped;
            });
          })
        Text('拖动调节 · 最大约屏 1/4').fontSize(11).fontColor($r('color.text_sub'))

        this.SectionTitle(`透明度 ${(this.opacityV * 100).toFixed(0)}%`)
        Slider({ value: this.opacityV * 100, min: 30, max: 100 })
          .selectedColor('#22D3EE')
          .trackColor('#1FFFFFFF')
          .onChange((v: number) => {
            const clamped = Math.min(1, Math.max(0.3, v / 100));
            this.opacityV = clamped;
            this.save((s: Style) => {
              s.opacity = clamped;
            });
          })

        this.SectionTitle('显示元素')
        Flex({ wrap: FlexWrap.Wrap }) {
          this.ElemChip('秒', this.elemSec, (on: boolean) => {
            this.elemSec = on;
            this.save((s: Style) => {
              s.showSeconds = on;
            });
          })
          this.ElemChip('毫秒', this.elemMs, (on: boolean) => {
            this.elemMs = on;
            this.save((s: Style) => {
              s.showMillis = on;
            });
          })
          this.ElemChip('日期', this.elemDate, (on: boolean) => {
            this.elemDate = on;
            this.save((s: Style) => {
              s.showDate = on;
            });
          })
          this.ElemChip('星期', this.elemWeek, (on: boolean) => {
            this.elemWeek = on;
            this.save((s: Style) => {
              s.showWeek = on;
            });
          })
          this.ElemChip('电量', this.elemBatt, (on: boolean) => {
            this.elemBatt = on;
            this.save((s: Style) => {
              s.showBattery = on;
            });
          })
        }
        .width('100%')
        .margin({ bottom: 6 })

        this.SectionTitle('毫秒位数（开启「毫秒」后生效）')
        Row({ space: 8 }) {
          ForEach([1, 2, 3], (d: number) => {
            Text(d === 1 ? '1 位 .s' : (d === 2 ? '2 位 .ss' : '3 位 .sss'))
              .fontSize(12)
              .fontColor(this.msDigits === d ? '#04101C' : $r('color.text_sub'))
              .backgroundColor(this.msDigits === d ? '#22D3EE' : '#14FFFFFF')
              .borderRadius(99)
              .padding({ left: 14, right: 14, top: 7, bottom: 7 })
              .onClick(() => {
                this.msDigits = d;
                this.save((s: Style) => {
                  s.millisDigits = d;
                });
              })
          })
        }
        .margin({ bottom: 30 })
      }
      .padding({ left: 16, right: 16 })
      .alignItems(HorizontalAlign.Start)
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
  }

  private previewText(): string {
    const p = fmtClock(true, this.elemSec, this.elemMs ? this.msDigits : 0, Date.now());
    return p.main + p.sec + p.ms;
  }

  @Builder
  SectionTitle(text: string) {
    Text(text)
      .fontSize(13)
      .fontColor($r('color.text_sub'))
      .margin({ top: 18, bottom: 6 })
  }

  @Builder
  ElemChip(label: string, active: boolean, onTap: (on: boolean) => void) {
    Text(label)
      .fontSize(12)
      .fontColor(active ? '#04101C' : $r('color.text_sub'))
      .backgroundColor(active ? '#22D3EE' : '#14FFFFFF')
      .borderRadius(99)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .margin(4)
      .onClick(() => onTap(!active))
  }
}

/** 我的页：权限状态 + 基础设置 */
@Component
struct MeTab {
  build() {
    Scroll() {
      Column() {
        Text('我的').fontSize(22).fontWeight(FontWeight.Bold)
          .fontColor($r('color.text_main')).margin({ top: 18 })

        Column() {
          Text('权限状态').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('color.text_main'))
          Row() {
            Text('悬浮窗权限').fontSize(14).fontColor($r('color.text_main')).layoutWeight(1)
            Text('以首页状态为准').fontSize(13).fontColor($r('color.text_sub'))
          }.width('100%').margin({ top: 10 })
          Row() {
            Text('后台运行建议').fontSize(14).fontColor($r('color.text_main')).layoutWeight(1)
            Text('最近任务下拉加锁 ›').fontSize(13).fontColor('#FFB454')
          }.width('100%').margin({ top: 8 })
        }
        .padding(14)
        .backgroundColor($r('color.card_bg'))
        .borderRadius(18)
        .width('100%')
        .margin({ top: 12 })

        Column() {
          Text('设置').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('color.text_main'))
          Row() {
            Text('时间源').fontSize(14).fontColor($r('color.text_main')).layoutWeight(1)
            Text(`${Sources.byId(TimeSync.selectedId).name} ›`)
              .fontSize(13).fontColor($r('color.text_sub'))
          }
          .width('100%').margin({ top: 8 })
          .onClick(() => router.pushUrl({ url: 'pages/TimeSourcePage' }))
          Row() {
            Text('24 小时制').fontSize(14).fontColor($r('color.text_main')).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: AppState.style.hour24 })
              .onChange((on: boolean) => {
                const s = AppState.style;
                s.hour24 = on;
                Prefs.saveStyle(s);
              })
          }.width('100%').margin({ top: 8 })
          Row() {
            Text('贴边吸附').fontSize(14).fontColor($r('color.text_main')).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: AppState.style.snap })
              .onChange((on: boolean) => {
                const s = AppState.style;
                s.snap = on;
                Prefs.saveStyle(s);
              })
          }.width('100%').margin({ top: 8 })
        }
        .padding(14)
        .backgroundColor($r('color.card_bg'))
        .borderRadius(18)
        .width('100%')
        .margin({ top: 10 })

        Text('兔时笺 v0.3.3 · 无广告 · 不收集任何数据\n计时为时间戳驱动，恢复后零累计误差；默认显示北京时间（授时中心 NTP 直连），除时间源校准外不联网')
          .fontSize(12)
          .fontColor($r('color.text_sub'))
          .margin({ top: 10, bottom: 30 })
      }
      .padding({ left: 16, right: 16 })
      .alignItems(HorizontalAlign.Start)
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
  }
}
