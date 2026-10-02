import { connection, http, socket } from '@kit.NetworkKit';
import { Prefs } from '../data/Prefs';

/** 源类型：本机 / SNTP(UDP123) / JSON 接口（毫秒级）/ HTTP Date 头（秒级，秒沿检测提精度） */
export enum SourceKind {
  DEVICE = 0,
  SNTP = 1,
  JSON = 2,
  DATE = 3,
}

/** 内置时间源（接口与 Android 端同源，均于 2026-10 实测可用；SNTP 主备 + HTTP 回落） */
export class TimeSource {
  id: string = '';
  name: string = '';
  sub: string = '';
  kind: SourceKind = SourceKind.DEVICE;
  url: string = '';
  ntpHosts: string[] = [];

  constructor(id: string, name: string, sub: string, kind: SourceKind, url: string, ntpHosts: string[]) {
    this.id = id;
    this.name = name;
    this.sub = sub;
    this.kind = kind;
    this.url = url;
    this.ntpHosts = ntpHosts;
  }
}

export class Sources {
  static readonly DEVICE: string = 'device';
  static readonly BEIJING: string = 'beijing';

  static readonly ALL: TimeSource[] = [
    new TimeSource(Sources.DEVICE, '设备时间', '本机系统时间 · 不联网', SourceKind.DEVICE, '', []),
    // ntp2/3.ntsc.ac.cn 无 DNS 记录，备选阿里公共 NTP（同为授时中心同步体系）
    new TimeSource(Sources.BEIJING, '北京时间', '中国国家授时中心 · NTP 直连（被拦时回落 HTTP）',
      SourceKind.SNTP, 'https://www.ntsc.ac.cn/', ['ntp.ntsc.ac.cn', 'ntp.aliyun.com']),
    new TimeSource('taobao', '淘宝', 'acs.m.taobao.com · 毫秒级接口', SourceKind.JSON,
      'https://acs.m.taobao.com/gw/mtop.common.getTimestamp/', []),
    new TimeSource('damai', '大麦', 'mtop.damai.cn · 毫秒级接口', SourceKind.JSON,
      'https://mtop.damai.cn/gw/mtop.common.getTimestamp/', []),
    new TimeSource('jd', '京东', 'www.jd.com', SourceKind.DATE, 'https://www.jd.com/', []),
    new TimeSource('meituan', '美团', 'www.meituan.com', SourceKind.DATE, 'https://www.meituan.com/', []),
    new TimeSource('pdd', '拼多多', 'mobile.yangkeduo.com', SourceKind.DATE, 'https://mobile.yangkeduo.com/', []),
    new TimeSource('unionpay', '云闪付', 'cn.unionpay.com', SourceKind.DATE, 'https://cn.unionpay.com/', []),
  ];

  static byId(id: string): TimeSource {
    for (const s of Sources.ALL) {
      if (s.id === id) {
        return s;
      }
    }
    return Sources.ALL[1]; // 兜底：北京时间
  }
}

/**
 * 一次校准结果（按源保留）。rttMs 按源类型语义不同：
 * SNTP/JSON = 最小时延；DATE = 秒沿翻转窗口（不确定度）。
 * prevOffsetMs/prevAtWall 为上一次成功校准，用于晶振漂移外推。
 */
export class SyncResult {
  sourceId: string = '';
  ok: boolean = false;
  offsetMs: number = 0;
  rttMs: number = 0;
  atWall: number = 0;
  error: string = '';
  prevOffsetMs: number = 0;
  prevAtWall: number = 0;
  /** 本次结果使用的通道：true=NTP（SNTP 源直连成功），false=HTTP 回落或 HTTP 类源 */
  ntp: boolean = false;

  constructor(sourceId: string, ok: boolean, offsetMs: number = 0, rttMs: number = 0,
    atWall: number = 0, error: string = '') {
    this.sourceId = sourceId;
    this.ok = ok;
    this.offsetMs = offsetMs;
    this.rttMs = rttMs;
    this.atWall = atWall;
    this.error = error;
  }
}

/** 校准结果持久化 JSON 形状（ArkTS 禁无类型对象字面量） */
interface ResultJson {
  id: string;
  ok: boolean;
  off: number;
  rtt: number;
  at: number;
  off2: number;
  at2: number;
  ntp: boolean;
  err: string;
}

/** SNTP 单次样本 */
class SntpSample {
  offsetMs: number = 0;
  delayMs: number = 0;
}

/** 一次 HTTP 采样的观测值 */
class HttpSample {
  body: string = '';
  dateMs: number = -1;
  rttMs: number = 0;
  wallAtT1: number = 0;
}

const STALE_MS: number = 10 * 60 * 1000;   // 新鲜度闸门：超过 10 分钟视为过期
const PERIOD_MS: number = 10 * 60 * 1000;  // 进程存活期间的周期补校准间隔
const TIMEOUT_MS: number = 3500;
const UA: string = 'Mozilla/5.0 (Linux; Android 14) Mobile Safari/537.36';
const NTP_BACKOFF_MS: number = 10 * 60 * 1000;
const DRIFT_MIN_SPAN_MS: number = 120 * 1000;
const DRIFT_MAX_PPM: number = 50;

/**
 * SNTP 客户端（RFC 5905 48 字报文，UDP 123）。完整 NTP 时延/偏移公式（非 HTTP 近似），
 * 是默认「北京时间」源的首选通道；网络拦截 UDP 123 时由上层回落 HTTP 秒沿法。
 */
class Sntp {
  static async probe(host: string): Promise<SntpSample | null> {
    // DNS 解析（UDP 发送只收 IP）
    let ip: string = '';
    try {
      const addrs: connection.NetAddress[] = await connection.getAddressesByName(host);
      if (addrs.length > 0 && addrs[0].address) {
        ip = addrs[0].address;
      }
    } catch (e) {
      return null;
    }
    if (ip === '') {
      return null;
    }
    const t0: number = Date.now();
    const udp: socket.UDPSocket = socket.constructUDPSocketInstance();
    try {
      await udp.bind({ address: '0.0.0.0', port: 0 });
      const req: ArrayBuffer = new ArrayBuffer(48);
      new DataView(req).setUint8(0, 0x1B); // LI=0 VN=3 Mode=3(client)
      const result: SntpSample | null = await new Promise<SntpSample | null>((resolve) => {
        let settled: boolean = false;
        let timer: number = -1;
        const finish = (v: SntpSample | null): void => {
          if (settled) {
            return;
          }
          settled = true;
          clearTimeout(timer);
          udp.off('message');
          resolve(v);
        };
        timer = setTimeout(() => finish(null), 2500);
        udp.on('message', (value: socket.SocketMessageInfo) => {
          const t1: number = Date.now();
          finish(Sntp.parse(value.message, t0, t1));
        });
        udp.send({
          address: { address: ip, port: 123 } as socket.NetAddress,
          data: req,
        } as socket.UDPSendOptions).catch(() => finish(null));
      });
      return result;
    } catch (e) {
      return null;
    } finally {
      try {
        udp.close();
      } catch (e) {
        // 已关闭则忽略
      }
    }
  }

  /** 应答报文 → 偏移/时延样本；mode/stratum/时间范围异常返回 null */
  static parse(msg: ArrayBuffer, t0: number, t1: number): SntpSample | null {
    if (msg.byteLength < 48) {
      return null;
    }
    const dv: DataView = new DataView(msg);
    const mode: number = dv.getUint8(0) & 0x07;
    const stratum: number = dv.getUint8(1);
    if (mode !== 4 && mode !== 5) {
      return null;
    }
    if (stratum === 0) {
      return null; // Kiss-o'-Death
    }
    const t2: number = Sntp.ntpMs(dv, 32); // 服务器收到请求
    const t3: number = Sntp.ntpMs(dv, 40); // 服务器发出应答
    if (t2 <= 0 || t3 <= 0) {
      return null;
    }
    // NTP 公式 θ=((T2−T1)+(T3−T4))/2 等价实现：服务器中点 − 本地中点
    const rtt: number = t1 - t0;
    const wallMid: number = t0 + rtt / 2;
    const serverMid: number = (t2 + t3) / 2;
    const s: SntpSample = new SntpSample();
    s.offsetMs = serverMid - wallMid;
    s.delayMs = rtt;
    return s;
  }

  /** NTP 64 位时间戳（32 位秒 + 32 位小数）→ Unix 毫秒；2020~2035 之外视为异常 */
  static ntpMs(dv: DataView, off: number): number {
    const sec: number = dv.getUint32(off);
    if (sec === 0) {
      return -1;
    }
    const frac: number = dv.getUint32(off + 4);
    const unix: number = (sec - 2208988800) * 1000 + Math.floor(frac / 4294967.296);
    if (unix < 1577836800000 || unix > 2051224000000) {
      return -1;
    }
    return unix;
  }
}

/**
 * 时间源同步：SNTP / NTP 式 HTTP 校准（与 Android 端同构）。
 * 显示时间 = Date.now() + offset(所选源, 含漂移外推) + 手动微调；
 * 仅 CLOCK 显示走 now()，秒表/倒计时是时长语义，仍用系统时钟。
 */
export class TimeSync {
  static readonly MANUAL_STEP_MS: number = 10;
  static readonly MANUAL_MAX_MS: number = 9999;
  /** 呈现深度（帧）：默认 1；真机若见整体滞后可调大（持久化于 preferences） */
  static presentDepth: number = 1;

  static selectedId: string = Sources.BEIJING;
  static manualOffsetMs: number = 0;
  static results: Map<string, SyncResult> = new Map();
  static syncing: Set<string> = new Set();
  private static inFlight: Set<string> = new Set();
  private static ntpBlockedUntil: number = 0;

  /** 当前应显示的「现在」 */
  static now(): number {
    return Date.now() + Math.round(TimeSync.totalOffsetMs());
  }

  /** 悬浮窗秒对齐用：显示时间距下一整秒的剩余毫秒 */
  static msToNextSecond(): number {
    const m = TimeSync.now() % 1000;
    return m === 0 ? 1000 : 1000 - m;
  }

  static totalOffsetMs(): number {
    const src = Sources.byId(TimeSync.selectedId);
    let syncOffset = 0;
    if (src.kind !== SourceKind.DEVICE) {
      const r = TimeSync.results.get(src.id);
      if (r !== undefined && r.ok) {
        syncOffset = r.offsetMs + TimeSync.driftNowMs(r, src);
      }
    }
    return syncOffset + TimeSync.manualOffsetMs;
  }

  /** 晶振漂移外推：仅高精度源（SNTP/JSON）、间隔达标且斜率合理时启用 */
  private static driftNowMs(r: SyncResult, src: TimeSource): number {
    if (src.kind === SourceKind.DATE) {
      return 0; // Date 源噪声远大于真实漂移信号
    }
    if (r.prevAtWall <= 0) {
      return 0;
    }
    const span: number = r.atWall - r.prevAtWall;
    if (span < DRIFT_MIN_SPAN_MS) {
      return 0;
    }
    const slope: number = (r.offsetMs - r.prevOffsetMs) / span;
    if (Math.abs(slope) * 1000000 > DRIFT_MAX_PPM) {
      return 0;
    }
    return slope * (Date.now() - r.atWall);
  }

  static currentResult(): SyncResult | null {
    const src = Sources.byId(TimeSync.selectedId);
    if (src.kind === SourceKind.DEVICE) {
      return null;
    }
    return TimeSync.results.get(src.id) ?? null;
  }

  // ───────── 用户操作 ─────────

  static select(id: string): void {
    if (TimeSync.selectedId === id) {
      return;
    }
    TimeSync.selectedId = id;
    TimeSync.persist();
    TimeSync.ensureFresh();
  }

  static nudgeManual(deltaMs: number): void {
    const v = TimeSync.manualOffsetMs + deltaMs;
    TimeSync.manualOffsetMs = Math.min(TimeSync.MANUAL_MAX_MS, Math.max(-TimeSync.MANUAL_MAX_MS, v));
    TimeSync.persist();
  }

  static resetManual(): void {
    TimeSync.manualOffsetMs = 0;
    TimeSync.persist();
  }

  /** 所选源过期则后台补校准（打开时间源页 / 显示悬浮窗时触发） */
  static ensureFresh(): void {
    const src = Sources.byId(TimeSync.selectedId);
    if (src.kind === SourceKind.DEVICE) {
      return;
    }
    const r = TimeSync.results.get(src.id);
    const fresh = r !== undefined && r.ok && Date.now() - r.atWall < STALE_MS;
    if (!fresh) {
      TimeSync.requestSync(src.id);
    }
  }

  static requestSync(id: string): void {
    TimeSync.doSync(id);
  }

  // ───────── 校准入口 ─────────

  private static async doSync(id: string): Promise<void> {
    const src = Sources.byId(id);
    if (src.kind === SourceKind.DEVICE || TimeSync.inFlight.has(id)) {
      return;
    }
    TimeSync.inFlight.add(id);
    TimeSync.syncing.add(id);
    try {
      let r: SyncResult;
      if (src.kind === SourceKind.SNTP) {
        const n = await TimeSync.syncNtp(src);
        r = n.ok ? n : await TimeSync.syncDateRollover(src); // UDP 被拦 → 回落 HTTP 秒沿法
      } else if (src.kind === SourceKind.JSON) {
        r = await TimeSync.syncJson(src);
      } else {
        r = await TimeSync.syncDateRollover(src);
      }
      const withPrev = TimeSync.carryPrev(id, r);
      TimeSync.results.set(id, withPrev);
      TimeSync.persist();
    } finally {
      TimeSync.inFlight.delete(id);
      TimeSync.syncing.delete(id);
    }
  }

  private static carryPrev(id: string, r: SyncResult): SyncResult {
    if (!r.ok) {
      return r;
    }
    const old = TimeSync.results.get(id);
    if (old !== undefined && old.ok) {
      r.prevOffsetMs = old.offsetMs;
      r.prevAtWall = old.atWall;
    }
    return r;
  }

  // ───────── SNTP 通道 ─────────

  private static async syncNtp(src: TimeSource): Promise<SyncResult> {
    if (Date.now() < TimeSync.ntpBlockedUntil) {
      return new SyncResult(src.id, false, 0, 0, 0, 'NTP 通道近期不可用');
    }
    const samples: SntpSample[] = [];
    for (let round = 1; round <= 2; round++) {
      for (const h of src.ntpHosts) {
        const s = await Sntp.probe(h);
        if (s !== null) {
          samples.push(s);
        }
        if (samples.length >= 4) {
          break;
        }
      }
      if (round === 1 && samples.length === 0) {
        break; // 网络明显拦截 UDP，快速放弃走 HTTP
      }
    }
    if (samples.length === 0) {
      TimeSync.ntpBlockedUntil = Date.now() + NTP_BACKOFF_MS;
      return new SyncResult(src.id, false, 0, 0, 0, 'NTP 不可达（UDP 123 被拦截）');
    }
    const byDelay: SntpSample[] = samples.slice().sort((a, b) => a.delayMs - b.delayMs);
    const best: number[] = [];
    for (let i = 0; i < Math.min(3, byDelay.length); i++) {
      best.push(byDelay[i].offsetMs);
    }
    let minDelay: number = byDelay[0].delayMs;
    const r = new SyncResult(src.id, true, TimeSync.median(best), minDelay, Date.now());
    r.ntp = true;
    return r;
  }

  // ───────── JSON 通道：8 样本（≤4s），最优 3 个 RTT 的偏移取中位数 ─────────

  private static async syncJson(src: TimeSource): Promise<SyncResult> {
    const client = http.createHttp();
    const startAt: number = Date.now();
    const rtts: number[] = [];
    const offsets: number[] = [];
    let lastErr: string = '';
    let i: number = 0;
    try {
      while (i < 8 && (offsets.length === 0 || Date.now() - startAt < 4000)) {
        try {
          const s = await TimeSync.httpGet(client, src.url, false);
          const obj = JSON.parse(s.body) as Record<string, Object>;
          const data = obj['data'] as Record<string, Object>;
          const t = Number(data['t']);
          if (!Number.isFinite(t) || t <= 0) {
            throw new Error('响应格式异常');
          }
          rtts.push(s.rttMs);
          offsets.push(t + s.rttMs / 2 - s.wallAtT1);
        } catch (e) {
          lastErr = e instanceof Error ? e.message : '请求失败';
        }
        i++;
        if (i < 8) {
          await TimeSync.sleep(80);
        }
      }
    } finally {
      client.destroy();
    }
    if (offsets.length === 0) {
      return new SyncResult(src.id, false, 0, 0, 0, lastErr !== '' ? lastErr : '请求失败');
    }
    // 低 RTT 组的偏移取中位数：抗单次网络抖动
    const order: number[] = offsets.map((_, k) => k).sort((a, b) => rtts[a] - rtts[b]);
    const best: number[] = [];
    for (let k = 0; k < Math.min(3, order.length); k++) {
      best.push(offsets[order[k]]);
    }
    let minRtt: number = rtts[0];
    for (const v of rtts) {
      minRtt = Math.min(minRtt, v);
    }
    return new SyncResult(src.id, true, TimeSync.median(best), minRtt, Date.now());
  }

  // ───────── Date 头通道：预测秒沿 + 临近突发轮询（HEAD + 同客户端连接复用） ─────────

  /**
   * 两轮秒沿检测，保留窗口最小者：有历史偏差 → 预测下一整秒边界，边界前 450ms 起
   * 每 50ms 突发探测；无历史 → 先 250ms 间隔扫描定位。窗口 = 翻转前后两次响应的墙钟差。
   */
  private static async syncDateRollover(src: TimeSource): Promise<SyncResult> {
    const old = TimeSync.results.get(src.id);
    let rough: number | null = old !== undefined && old.ok ? old.offsetMs : null;
    let bestOffset: number = 0;
    let bestWindow: number = -1;
    let lastErr: string = '';
    let rounds: number = 0;
    const client = http.createHttp();
    try {
      while (rounds < 2) {
        let r: Rollover | null = null;
        try {
          r = rough === null ? await TimeSync.scanRollover(client, src) : await TimeSync.burstRollover(client, src, rough);
        } catch (e) {
          lastErr = e instanceof Error ? e.message : '请求失败';
        }
        if (r === null) {
          if (rough === null) {
            return new SyncResult(src.id, false, 0, 0, 0, lastErr !== '' ? lastErr : '未捕获到秒沿');
          }
          break; // 预测轮失败：保留已获得的最好结果
        }
        if (bestWindow < 0 || r.windowMs < bestWindow) {
          bestOffset = r.offset;
          bestWindow = r.windowMs;
        }
        rough = r.offset;
        rounds++;
      }
    } finally {
      client.destroy();
    }
    if (bestWindow < 0) {
      return new SyncResult(src.id, false, 0, 0, 0, lastErr !== '' ? lastErr : '校准失败');
    }
    return new SyncResult(src.id, true, bestOffset, bestWindow, Date.now());
  }

  private static async scanRollover(client: http.HttpRequest, src: TimeSource): Promise<Rollover | null> {
    let prevMs: number = 0;
    let prevWall: number = 0;
    const startAt: number = Date.now();
    while (Date.now() - startAt < 3500) {
      const s = await TimeSync.httpGet(client, src.url, true);
      if (s.dateMs <= 0) {
        throw new Error('响应缺少 Date 头');
      }
      if (prevMs > 0 && prevMs < s.dateMs) {
        return new Rollover(s.dateMs - (prevWall + s.wallAtT1) / 2, Math.round(s.wallAtT1 - prevWall));
      }
      if (s.dateMs !== prevMs) {
        prevMs = s.dateMs;
        prevWall = s.wallAtT1;
      }
      await TimeSync.sleep(250);
    }
    return null;
  }

  private static async burstRollover(client: http.HttpRequest, src: TimeSource, rough: number): Promise<Rollover | null> {
    // 预测下一整秒边界（服务器时间线）对应的本地墙钟
    const serverNow: number = Date.now() + rough;
    const nextBoundary: number = Math.floor(serverNow / 1000) * 1000 + 1000;
    const boundaryLocal: number = nextBoundary - rough;
    const sleepMs: number = (boundaryLocal - 450) - Date.now();
    if (sleepMs > 1200) {
      return null; // 预测异常（偏差过大），交给外层换扫描
    }
    if (sleepMs > 0) {
      await TimeSync.sleep(sleepMs);
    }
    let prevMs: number = 0;
    let prevWall: number = 0;
    const startAt: number = Date.now();
    while (Date.now() - startAt < 1300) {
      const s = await TimeSync.httpGet(client, src.url, true);
      if (s.dateMs <= 0) {
        throw new Error('响应缺少 Date 头');
      }
      if (prevMs > 0 && prevMs < s.dateMs) {
        return new Rollover(s.dateMs - (prevWall + s.wallAtT1) / 2, Math.round(s.wallAtT1 - prevWall));
      }
      if (s.dateMs !== prevMs) {
        prevMs = s.dateMs;
        prevWall = s.wallAtT1;
      }
      await TimeSync.sleep(50);
    }
    return null;
  }

  /** 同步过程复用同一 client 以复用底层连接；HEAD 探测不带响应体 */
  private static async httpGet(client: http.HttpRequest, url: string, head: boolean): Promise<HttpSample> {
    const t0: number = Date.now();
    const s: HttpSample = new HttpSample();
    const resp = await client.request(url, {
      method: head ? http.RequestMethod.HEAD : http.RequestMethod.GET,
      header: { 'User-Agent': UA, 'Cache-Control': 'no-cache' } as Record<string, string>,
      connectTimeout: TIMEOUT_MS,
      readTimeout: TIMEOUT_MS,
      usingCache: false,
    } as http.HttpRequestOptions);
    if (resp.responseCode < 200 || resp.responseCode >= 400) {
      throw new Error(`HTTP ${resp.responseCode}`);
    }
    const headers = resp.header as Record<string, Object>;
    const d = headers['date'] !== undefined ? headers['date'] : headers['Date'];
    s.dateMs = d !== undefined ? Date.parse(String(d)) : -1;
    if (!head && typeof resp.result === 'string') {
      s.body = resp.result;
    }
    s.wallAtT1 = Date.now();
    s.rttMs = s.wallAtT1 - t0;
    return s;
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => setTimeout(resolve, ms));
  }

  private static median(v: number[]): number {
    if (v.length === 0) {
      return 0;
    }
    const s: number[] = v.slice().sort((a, b) => a - b);
    const n: number = s.length;
    return n % 2 === 1 ? s[(n - 1) / 2] : (s[n / 2 - 1] + s[n / 2]) / 2;
  }

  // ───────── 持久化（preferences，键与 Android DataStore 语义一致） ─────────

  static persist(): void {
    Prefs.put('ts_source', TimeSync.selectedId);
    Prefs.put('ts_manual_ms', TimeSync.manualOffsetMs);
    Prefs.put('ts_present_depth', TimeSync.presentDepth);
    const arr: ResultJson[] = [];
    TimeSync.results.forEach((r) => {
      const j: ResultJson = {
        id: r.sourceId, ok: r.ok, off: r.offsetMs, rtt: r.rttMs, at: r.atWall,
        off2: r.prevOffsetMs, at2: r.prevAtWall, ntp: r.ntp, err: r.error,
      };
      arr.push(j);
    });
    Prefs.put('ts_results', JSON.stringify(arr));
  }

  static load(): void {
    TimeSync.selectedId = Prefs.getString('ts_source', Sources.BEIJING);
    TimeSync.manualOffsetMs = Math.min(TimeSync.MANUAL_MAX_MS,
      Math.max(-TimeSync.MANUAL_MAX_MS, Prefs.getNumber('ts_manual_ms', 0)));
    TimeSync.presentDepth = Math.min(2, Math.max(1, Prefs.getNumber('ts_present_depth', 1)));
    const raw = Prefs.getString('ts_results', '');
    if (raw !== '') {
      try {
        const arr = JSON.parse(raw) as object[];
        for (const item of arr) {
          const o = item as Record<string, Object>;
          const id = String(o['id'] ?? '');
          if (id === '') {
            continue;
          }
          const r = new SyncResult(
            id,
            Boolean(o['ok']),
            Number(o['off'] ?? 0),
            Number(o['rtt'] ?? 0),
            Number(o['at'] ?? 0),
            String(o['err'] ?? ''),
          );
          r.prevOffsetMs = Number(o['off2'] ?? 0);
          r.prevAtWall = Number(o['at2'] ?? 0);
          r.ntp = Boolean(o['ntp'] ?? false);
          TimeSync.results.set(id, r);
        }
      } catch (e) {
        console.error(`[timesync] load results failed: ${e instanceof Error ? e.message : ''}`);
      }
    }
  }

  // ───────── 格式化 ─────────

  /** +0.0943s / −0.0312s */
  static fmtOffset(ms: number): string {
    const sign = ms >= 0 ? '+' : '−';
    const v = Math.abs(ms) / 1000;
    return `${sign}${v.toFixed(4)}s`;
  }

  static fmtManual(ms: number): string {
    return ms === 0 ? '±0.0000s' : TimeSync.fmtOffset(ms);
  }

  static fmtAgo(atWall: number, nowWall: number): string {
    const s = Math.max(0, Math.floor((nowWall - atWall) / 1000));
    if (s < 3) {
      return '刚刚';
    }
    if (s < 60) {
      return `${s} 秒前`;
    }
    if (s < 3600) {
      return `${Math.floor(s / 60)} 分钟前`;
    }
    return `${Math.floor(s / 3600)} 小时前`;
  }
}

/** 一次秒沿检测结果：offset 与翻转窗口（前后两次响应的墙钟差，即不确定度） */
class Rollover {
  offset: number = 0;
  windowMs: number = 0;

  constructor(offset: number, windowMs: number) {
    this.offset = offset;
    this.windowMs = windowMs;
  }
}
