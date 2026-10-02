/**
 * 计时引擎：时间戳差值驱动（与 Android 端同构）。
 * 显示值永远由「目标时刻 − 当前时刻」计算，不累加 tick ——
 * 进程挂起/冻结恢复后立即正确（PRD 非功能需求）。
 */

export enum Mode {
  CLOCK = 'clock',
  STOPWATCH = 'stopwatch',
  COUNTDOWN = 'countdown',
}

export enum RunState {
  IDLE = 0,
  RUNNING = 1,
  PAUSED = 2,
  FINISHED = 3,
}

export enum BgKind {
  CAPSULE = 'capsule',
  CARD = 'card',
  OUTLINE = 'outline',
}

/** 时钟/秒表的分段显示（主值 / 秒 / 三位毫秒） */
export class TimeParts {
  main: string = '--:--';
  sec: string = '';
  ms: string = '';
}

export class Stopwatch {
  running: boolean = false;
  private baseMs: number = 0;
  private startStamp: number = 0;

  startOrPause(now: number): boolean {
    if (this.running) {
      this.baseMs = this.elapsed(now);
      this.running = false;
    } else {
      this.startStamp = now;
      this.running = true;
    }
    return this.running;
  }

  reset(): void {
    this.running = false;
    this.baseMs = 0;
  }

  elapsed(now: number): number {
    return this.baseMs + (this.running ? now - this.startStamp : 0);
  }
}

export class Countdown {
  state: RunState = RunState.IDLE;
  totalMs: number = 5 * 60 * 1000;
  private remainCached: number = 5 * 60 * 1000;
  private endStamp: number = 0;

  isActive(): boolean {
    return this.state === RunState.RUNNING || this.state === RunState.PAUSED;
  }

  setTotal(ms: number): void {
    this.totalMs = ms;
    this.remainCached = ms;
    this.state = RunState.IDLE;
  }

  /** 开始/继续，返回结束时刻的 wall-clock 毫秒（用于代理提醒） */
  start(now: number): number {
    this.endStamp = now + this.remainCached;
    this.state = RunState.RUNNING;
    return Date.now() + this.remainCached;
  }

  pause(now: number): void {
    this.remainCached = this.remain(now);
    this.state = RunState.PAUSED;
  }

  reset(): void {
    this.remainCached = this.totalMs;
    this.state = RunState.IDLE;
  }

  remain(now: number): number {
    if (this.state === RunState.RUNNING) {
      return Math.max(0, this.endStamp - now);
    }
    if (this.state === RunState.FINISHED) {
      return 0;
    }
    return this.remainCached;
  }

  finishIfDue(now: number): boolean {
    if (this.state === RunState.RUNNING && this.remain(now) <= 0) {
      this.state = RunState.FINISHED;
      return true;
    }
    return false;
  }

  addMinute(now: number): number {
    this.remainCached = this.remain(now) + 60 * 1000;
    this.totalMs += 60 * 1000;
    if (this.state === RunState.RUNNING) {
      return this.start(now);
    }
    return -1;
  }
}

// ───────── 格式化 ─────────

function pad(n: number, len: number = 2): string {
  let s = Math.floor(Math.abs(n)).toString();
  while (s.length < len) {
    s = '0' + s;
  }
  return s;
}

export function fmtClock(h24: boolean, withSeconds: boolean, millisDigits: number, nowWall: number): TimeParts {
  const d = new Date(nowWall);
  let h = d.getHours();
  if (!h24) {
    h = h % 12;
    if (h === 0) {
      h = 12;
    }
  }
  const p = new TimeParts();
  p.main = `${pad(h)}:${pad(d.getMinutes())}`;
  p.sec = withSeconds ? `:${pad(d.getSeconds())}` : '';
  p.ms = millisDigits > 0 ? `.${pad(d.getMilliseconds(), 3).substring(0, clampDigits(millisDigits))}` : '';
  return p;
}

export function fmtStopwatch(ms: number, millisDigits: number = 3): TimeParts {
  const t = Math.max(0, ms);
  const h = Math.floor(t / 3600000);
  const m = Math.floor(t / 60000) % 60;
  const s = Math.floor(t / 1000) % 60;
  const p = new TimeParts();
  p.main = (h > 0 ? `${pad(h)}:` : '') + `${pad(m)}:${pad(s)}`;
  p.ms = `.${pad(t % 1000, 3).substring(0, clampDigits(millisDigits))}`;
  return p;
}

function clampDigits(d: number): number {
  return Math.min(3, Math.max(1, Math.floor(d)));
}

export function fmtCountdown(ms: number): string {
  const t = Math.ceil(Math.max(0, ms) / 1000);
  const h = Math.floor(t / 3600);
  const m = Math.floor(t / 60) % 60;
  const s = t % 60;
  return (h > 0 ? `${pad(h)}:` : '') + `${pad(m)}:${pad(s)}`;
}

const WEEK: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

export function dateLine(nowWall: number): string {
  const d = new Date(nowWall);
  return `${d.getMonth() + 1}月${d.getDate()}日`;
}

export function weekLine(nowWall: number): string {
  return WEEK[new Date(nowWall).getDay()];
}
