import { display } from '@kit.ArkUI';
import { AppState, Prefs, Style, BgKind } from '../data/Prefs';
import { FloatWindowController } from '../float/FloatWindowController';
import { Mode, fmtClock, fmtStopwatch, fmtCountdown, dateLine, weekLine } from '../engine/TimerEngine';
import { TimeSync } from '../timesync/TimeSync';

/**
 * 悬浮窗内容页：由 FloatWindowController.setUIContent 加载。
 * 每 100ms 主动重算（时间戳差值），进程挂起恢复后第一个 tick 即显示正确时间。
 * 拖动 = PanGesture + moveWindowTo（vp→px 换算）；双击最小化；单击呼出控制条。
 */
@Entry
@Component
struct FloatPage {
  @State mainText: string = '--:--';
  @State secText: string = '';
  @State msText: string = '';
  @State subText: string = '';
  @State color: string = '#22D3EE';
  @State isCapsule: boolean = true;
  @State isOutline: boolean = false;
  @State fontScale: number = 1.15;
  @State opacityVal: number = 1;
  @State minimized: boolean = false;
  @State alert: boolean = false;
  @State showControls: boolean = false;
  @State pinchScale: number = 1;
  private timerId: number = -1;
  private boundaryTimerId: number = -1;
  private winX: number = 120;
  private winY: number = 180;
  private dragStartX: number = 0;
  private dragStartY: number = 0;
  private pinchBase: number = 1.15;
  private readonly winW: number = 480;
  // 显示时序：刷新率与本机屏幕高度（px），用于显示延迟补偿（呈现 1 周期 + 面板扫描位置）
  private refreshHz: number = 60;
  private screenHp: number = 2400;
  private compMsVal: number = 0;

  aboutToAppear(): void {
    const s = AppState.style;
    this.winX = s.x >= 0 ? s.x : 120;
    this.winY = s.y >= 0 ? s.y : 180;
    try {
      const d = display.getDefaultDisplaySync();
      this.refreshHz = d.refreshRate > 0 ? d.refreshRate : 60;
      this.screenHp = d.height > 0 ? d.height : 2400;
    } catch (e) {
      console.error(`[float] display info failed: ${e instanceof Error ? e.message : ''}`);
    }
    this.updateComp();
    this.tick();
    this.timerId = setInterval(() => this.tick(), 100);
    this.scheduleBoundary();
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
    }
    if (this.boundaryTimerId >= 0) {
      clearTimeout(this.boundaryTimerId);
      this.boundaryTimerId = -1;
    }
  }

  /** 本窗口位置的「从渲染到像素点亮」延迟（呈现深度可调 + 面板扫描位置；ArkUI 无公开 vsync） */
  private updateComp(): void {
    const period = 1000 / this.refreshHz;
    const cy = this.winY + 120; // 窗口内容近似半高
    const yFrac = this.screenHp > 0 ? Math.min(1, Math.max(0, cy / this.screenHp)) : 0.5;
    this.compMsVal = period * (TimeSync.presentDepth + yFrac);
  }

  /** 秒级时钟：在「整秒边界 − 补偿」时刻补一次渲染，让秒翻转恰好在真实边界点亮 */
  private scheduleBoundary(): void {
    if (this.boundaryTimerId >= 0) {
      clearTimeout(this.boundaryTimerId);
      this.boundaryTimerId = -1;
    }
    if (!this.minimized && AppState.mode === Mode.CLOCK && !AppState.style.showMillis) {
      const wait = Math.max(16, TimeSync.msToNextSecond() - this.compMsVal);
      this.boundaryTimerId = setTimeout(() => {
        this.tick();
        this.scheduleBoundary();
      }, wait);
    }
  }

  tick(): void {
    const s: Style = AppState.style;
    this.color = s.color;
    this.isCapsule = s.bg === BgKind.CAPSULE;
    this.isOutline = s.bg === BgKind.OUTLINE;
    this.fontScale = s.scale;
    this.opacityVal = s.opacity;
    this.updateComp();

    const nowWall = Date.now();
    if (AppState.countdown.finishIfDue(nowWall)) {
      AppState.alarming = true;   // 系统代理提醒已在倒计时启动时登记，必达
      this.alert = true;
    }

    // 显示值加显示延迟补偿（= 该帧点亮时刻的真实时间）；引擎判定（finishIfDue）不参与补偿。
    // CLOCK 读数另含时间源校准偏移；秒表/倒计时是时长语义，仅加显示补偿。
    const displayNow = TimeSync.now() + this.compMsVal;
    const monoNow = nowWall + this.compMsVal;
    if (AppState.mode === Mode.CLOCK) {
      const p = fmtClock(s.hour24, s.showSeconds, s.showMillis ? s.millisDigits : 0, displayNow);
      this.mainText = p.main;
      this.secText = p.sec;
      this.msText = p.ms;
    } else if (AppState.mode === Mode.STOPWATCH) {
      const p = fmtStopwatch(AppState.stopwatch.elapsed(monoNow), Math.max(1, s.millisDigits));
      this.mainText = p.main;
      this.secText = '';
      this.msText = p.ms;
    } else {
      this.mainText = fmtCountdown(AppState.countdown.remain(monoNow));
      this.secText = '';
      this.msText = '';
    }

    const bits: string[] = [];
    if (s.showDate) {
      bits.push(dateLine(displayNow));
    }
    if (s.showWeek) {
      bits.push(weekLine(displayNow));
    }
    this.subText = bits.join(' · ');
  }

  build() {
    Stack({ alignContent: Alignment.center }) {
      if (this.minimized) {
        Circle({ width: 24, height: 24 })
          .fill(this.color)
          .stroke('#FFFFFFCC')
          .strokeWidth(2)
      } else {
        Column({ space: 2 }) {
          Text(this.mainText + this.secText + this.msText)
            .fontSize(24 * this.fontScale)
            .fontColor(this.alert ? '#FF5252' : this.color)
            .fontFamily('monospace')
            .fontWeight(FontWeight.Bold)
            .textShadow(this.isOutline ? {
              radius: 10,
              color: this.alert ? '#AAFF5252' : ('AA' + this.color),
              offsetX: 0,
              offsetY: 0,
            } : { radius: 0, color: 'transparent', offsetX: 0, offsetY: 0 })
          if (this.subText.length > 0) {
            Text(this.subText)
              .fontSize(10 * this.fontScale + 1)
              .fontColor(this.alert ? '#FF5252' : this.color)
              .opacity(0.92)
          }
        }
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
        .backgroundColor(this.isOutline ? Color.Transparent
          : (this.alert ? '#33FF5252' : (this.isCapsule ? '#D9080C18' : '#E6080C18')))
        .borderRadius(this.isCapsule ? 999 : 16)
        .border({
          width: 1,
          color: this.isOutline ? Color.Transparent : (this.alert ? '#66FF5252' : ('59' + this.color)),
        })
        .opacity(this.opacityVal)
        .scale({ x: this.pinchScale, y: this.pinchScale })
      }
      // 关闭按钮：绝对定位窗口右上角（悬浮于内容之上，不参与流式布局、不占位）
      if (this.showControls && !this.minimized) {
        Text('✕')
          .fontSize(14)
          .fontColor('#FFFFFF')
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .backgroundColor('#66FFFFFF')
          .borderRadius(8)
          .position({ x: '100%', y: 0 })
          .markAnchor({ x: '100%', y: 0 })
          .onClick(() => {
            AppState.floatVisible = false;
            FloatWindowController.destroy();
          })
      }
    }
    .width('100%')
    .height('100%')
    .gesture(
      GestureGroup(GestureMode.Exclusive,
        // 双击：最小化/还原（同步调整窗口尺寸）
        TapGesture({ count: 2 })
          .onAction(() => {
            this.minimized = !this.minimized;
            if (this.minimized) {
              FloatWindowController.resizeTo(56, 56);
            } else {
              FloatWindowController.resizeTo(this.winW, 260);
            }
          }),
        // 单击：呼出迷你控制条
        TapGesture({ count: 1 })
          .onAction(() => {
            this.showControls = !this.showControls;
          }),
      ),
    )
    .gesture(
      // 双指捏合：纯比例缩放 —— 捏合期间字号冻结，仅用 scale 变换（渲染层，零重排）；
      // 收手时一次性把字号定稿到新档位并持久化（逐帧改 fontSize 会每帧重排，抖卡）
      PinchGesture({ fingers: 2 })
        .onActionStart(() => {
          this.pinchBase = AppState.style.scale;
          this.pinchScale = 1;
        })
        .onActionUpdate((e: GestureEvent) => {
          const target = Math.min(3.8, Math.max(0.7, this.pinchBase * e.scale));
          this.pinchScale = target / this.pinchBase;
        })
        .onActionEnd(() => {
          const target = Math.min(3.8, Math.max(0.7, this.pinchBase * this.pinchScale));
          this.fontScale = target;
          AppState.style.scale = target;
          this.pinchScale = 1;
          Prefs.saveStyle(AppState.style);
        }),
    )
    .gesture(
      PanGesture({ fingers: 1, direction: PanDirection.All, distance: 3 })
        .onActionStart(() => {
          this.dragStartX = this.winX;
          this.dragStartY = this.winY;
        })
        .onActionUpdate((e: GestureEvent) => {
          // offsetX/offsetY 单位 vp，moveWindowTo 单位 px
          this.winX = this.dragStartX + vp2px(e.offsetX);
          this.winY = this.dragStartY + vp2px(e.offsetY);
          FloatWindowController.move(this.winX, this.winY);
        })
        .onActionEnd(() => {
          const s = AppState.style;
          if (s.snap) {
            // 贴边吸附：按窗口中心判断左右半屏
            const displayInfo = display.getDefaultDisplaySync();
            const centerX = this.winX + this.winW / 2;
            this.winX = centerX < displayInfo.width / 2 ? 12 : displayInfo.width - this.winW - 12;
            FloatWindowController.move(this.winX, this.winY);
          }
          s.x = Math.round(this.winX);
          s.y = Math.round(this.winY);
          Prefs.saveStyle(s);
        }),
    )
  }
}
