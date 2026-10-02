import Foundation

// ───────── 时间源：注册表 / 校准引擎（与双端同构 v2） ─────────

enum SourceKind { case device, sntp, json, date }

struct TimeSource: Identifiable, Equatable {
    let id: String
    let name: String
    let sub: String
    let kind: SourceKind
    let url: String
    let ntpHosts: [String]
}

struct SyncResult: Equatable {
    var sourceId: String
    var ok = false
    var offsetMs = 0.0
    /// SNTP/JSON=最小时延；DATE=秒沿翻转窗口（不确定度）
    var rttMs = 0.0
    var atWall = 0.0
    var error: String?
    var prevOffsetMs = 0.0
    var prevAtWall = 0.0
    /// true=NTP 直连成功；false=HTTP 回落或 HTTP 类源
    var ntp = false
}

enum Sources {
    static let device = "device"
    static let beijing = "beijing"

    static let all: [TimeSource] = [
        TimeSource(id: device, name: "设备时间", sub: "本机系统时间 · 不联网", kind: .device, url: "", ntpHosts: []),
        TimeSource(id: beijing, name: "北京时间", sub: "中国国家授时中心 · NTP 直连（被拦时回落 HTTP）",
                   kind: .sntp, url: "https://www.ntsc.ac.cn/",
                   ntpHosts: ["ntp.ntsc.ac.cn", "ntp.aliyun.com"]),
        TimeSource(id: "taobao", name: "淘宝", sub: "acs.m.taobao.com · 毫秒级接口", kind: .json,
                   url: "https://acs.m.taobao.com/gw/mtop.common.getTimestamp/", ntpHosts: []),
        TimeSource(id: "damai", name: "大麦", sub: "mtop.damai.cn · 毫秒级接口", kind: .json,
                   url: "https://mtop.damai.cn/gw/mtop.common.getTimestamp/", ntpHosts: []),
        TimeSource(id: "jd", name: "京东", sub: "www.jd.com", kind: .date, url: "https://www.jd.com/", ntpHosts: []),
        TimeSource(id: "meituan", name: "美团", sub: "www.meituan.com", kind: .date, url: "https://www.meituan.com/", ntpHosts: []),
        TimeSource(id: "pdd", name: "拼多多", sub: "mobile.yangkeduo.com", kind: .date, url: "https://mobile.yangkeduo.com/", ntpHosts: []),
        TimeSource(id: "unionpay", name: "云闪付", sub: "cn.unionpay.com", kind: .date, url: "https://cn.unionpay.com/", ntpHosts: []),
    ]

    static func byId(_ id: String) -> TimeSource {
        all.first { $0.id == id } ?? all[1]
    }
}

/// 时间源同步：SNTP / NTP 式 HTTP 校准。
/// 显示时间 = 墙钟 + offset(所选源, 含漂移外推) + 手动微调；仅 CLOCK 显示走 now()。
/// 读路径（now 等）非隔离可从任意线程调用；状态写入收敛在 MainActor 的 sync()。
final class TimeSync: ObservableObject {
    static let shared = TimeSync()

    @Published var selectedId = Sources.beijing
    @Published var manualOffsetMs = 0.0
    @Published var results: [String: SyncResult] = [:]
    @Published var syncing: Set<String> = []

    static let manualStepMs = 10.0
    static let manualMaxMs = 9_999.0
    private let staleMs = 10 * 60_000.0     // 新鲜度闸门 10 分钟
    private let periodMs = 10 * 60_000.0    // 周期补校准间隔
    private let driftMinSpanMs = 120_000.0
    private let driftMaxPpm = 50.0
    private var ntpBlockedUntil = 0.0
    private var inFlight: Set<String> = []
    private var periodicStarted = false

    private init() {
        load()
    }

    // ───────── 显示链路 ─────────

    func now() -> Double { Wall.nowMs() + totalOffsetMs().rounded() }

    func msToNextSecond() -> Double {
        let m = now().truncatingRemainder(dividingBy: 1000)
        return m == 0 ? 1000 : 1000 - m
    }

    func totalOffsetMs() -> Double {
        let src = Sources.byId(selectedId)
        let syncOffset = src.kind == .device ? 0 : syncOffsetNow(src)
        return syncOffset + manualOffsetMs
    }

    private func syncOffsetNow(_ src: TimeSource) -> Double {
        guard let r = results[src.id], r.ok else { return 0 }
        return r.offsetMs + driftNowMs(r, src)
    }

    private func driftNowMs(_ r: SyncResult, _ src: TimeSource) -> Double {
        guard src.kind != .date, r.prevAtWall > 0 else { return 0 }
        let span = r.atWall - r.prevAtWall
        guard span >= driftMinSpanMs else { return 0 }
        let slope = (r.offsetMs - r.prevOffsetMs) / span
        guard abs(slope) * 1e6 <= driftMaxPpm else { return 0 }
        return slope * (Wall.nowMs() - r.atWall)
    }

    func currentResult() -> SyncResult? {
        let src = Sources.byId(selectedId)
        return src.kind == .device ? nil : results[src.id]
    }

    // ───────── 用户操作 ─────────

    func select(_ id: String) {
        guard selectedId != id else { return }
        selectedId = id
        persist()
        ensureFresh()
    }

    func nudgeManual(_ deltaMs: Double) {
        manualOffsetMs = (manualOffsetMs + deltaMs).clamped(-Self.manualMaxMs...Self.manualMaxMs, fallback: 0)
        persist()
    }

    func resetManual() {
        manualOffsetMs = 0
        persist()
    }

    /// 过期（>10 分钟）才真正校准；触发点：开时间源页/切源/开悬浮窗/回前台/周期任务
    nonisolated func ensureFresh() {
        Task { @MainActor in
            let src = Sources.byId(self.selectedId)
            guard src.kind != .device else { return }
            let last = self.results[src.id]
            let fresh = last?.ok == true && Wall.nowMs() - (last?.atWall ?? 0) < self.staleMs
            if !fresh { self.requestSync(src.id) }
        }
    }

    nonisolated func requestSync(_ id: String) {
        Task { @MainActor in
            await self.sync(id: id)
        }
    }

    /// 进程存活期间每 10 分钟过一次闸门（新鲜不发请求）
    func startPeriodicSync() {
        guard !periodicStarted else { return }
        periodicStarted = true
        Timer.scheduledTimer(withTimeInterval: periodMs / 1000, repeats: true) { _ in
            TimeSync.shared.ensureFresh()
        }
    }

    // ───────── 校准 ─────────

    @MainActor
    private func sync(id: String) async {
        let src = Sources.byId(id)
        guard src.kind != .device, !inFlight.contains(id) else { return }
        inFlight.insert(id)
        syncing.insert(id)
        defer { inFlight.remove(id); syncing.remove(id) }

        var r: SyncResult
        switch src.kind {
        case .sntp:
            let n = await syncNtp(src)
            r = n.ok ? n : await syncDateRollover(src)
        case .json:
            r = await syncJson(src)
        default:
            r = await syncDateRollover(src)
        }
        if r.ok, let old = results[id], old.ok {
            r.prevOffsetMs = old.offsetMs
            r.prevAtWall = old.atWall
        }
        results[id] = r
        persist()
    }

    // SNTP 通道：主备各两轮（首轮全败快速放弃 → 10 分钟内不再尝试 NTP）
    private func syncNtp(_ src: TimeSource) async -> SyncResult {
        if Wall.nowMs() < ntpBlockedUntil {
            return SyncResult(sourceId: src.id, error: "NTP 通道近期不可用")
        }
        var samples: [Sntp.Sample] = []
        for round in 1...2 {
            for host in src.ntpHosts {
                if let s = await Sntp.probe(host: host) { samples.append(s) }
                if samples.count >= 4 { break }
            }
            if round == 1 && samples.isEmpty { break }
        }
        guard !samples.isEmpty else {
            ntpBlockedUntil = Wall.nowMs() + 10 * 60_000
            return SyncResult(sourceId: src.id, error: "NTP 不可达（UDP 123 被拦截）")
        }
        let best = samples.sorted { $0.delayMs < $1.delayMs }.prefix(3).map(\.offsetMs)
        var r = SyncResult(sourceId: src.id, ok: true,
                           offsetMs: median(best),
                           rttMs: samples.map(\.delayMs).min() ?? 0,
                           atWall: Wall.nowMs())
        r.ntp = true
        return r
    }

    // JSON 通道：8 样本（≤4s），最优 3 个 RTT 的偏移中位数
    private func syncJson(_ src: TimeSource) async -> SyncResult {
        let startAt = Mono.nowMs()
        var rtts: [Double] = []
        var offsets: [Double] = []
        var lastErr: String?
        var i = 0
        while i < 8 && (offsets.isEmpty || Mono.nowMs() - startAt < 4000) {
            do {
                let s = try await httpGet(url: src.url, head: false)
                guard let obj = try JSONSerialization.jsonObject(with: Data(s.body.utf8)) as? [String: Any],
                      let data = obj["data"] as? [String: Any],
                      let t = Double("\(data["t"] ?? "")") else {
                    throw TimeSyncError.badResponse
                }
                rtts.append(s.rttMs)
                offsets.append(t + s.rttMs / 2 - s.wallAtT1)
            } catch {
                lastErr = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            i += 1
            if i < 8 { try? await Task.sleep(nanoseconds: 80_000_000) }
        }
        guard !offsets.isEmpty else {
            return SyncResult(sourceId: src.id, error: lastErr ?? "请求失败")
        }
        let order = offsets.indices.sorted { rtts[$0] < rtts[$1] }
        let best = order.prefix(3).map { offsets[$0] }
        return SyncResult(sourceId: src.id, ok: true, offsetMs: median(best),
                          rttMs: rtts.min() ?? 0, atWall: Wall.nowMs())
    }

    // Date 头通道：两轮秒沿检测（预测 + 突发轮询，HEAD + URLSession 连接复用）
    private func syncDateRollover(_ src: TimeSource) async -> SyncResult {
        var rough: Double? = results[src.id].flatMap { $0.ok ? $0.offsetMs : nil }
        var bestOffset = 0.0
        var bestWindow = -1.0
        var lastErr: String?
        var rounds = 0
        while rounds < 2 {
            let r: (offset: Double, windowMs: Double)?
            do {
                r = try await (rough == nil
                    ? scanRollover(src)
                    : burstRollover(src, rough: rough!))
            } catch {
                lastErr = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                r = nil
            }
            guard let r else {
                if rough == nil {
                    return SyncResult(sourceId: src.id, error: lastErr ?? "未捕获到秒沿")
                }
                break
            }
            if bestWindow < 0 || r.windowMs < bestWindow {
                bestOffset = r.offset
                bestWindow = r.windowMs
            }
            rough = r.offset
            rounds += 1
        }
        guard bestWindow >= 0 else {
            return SyncResult(sourceId: src.id, error: lastErr ?? "校准失败")
        }
        return SyncResult(sourceId: src.id, ok: true, offsetMs: bestOffset,
                          rttMs: bestWindow, atWall: Wall.nowMs())
    }

    private func scanRollover(_ src: TimeSource) async throws -> (Double, Double) {
        var prevMs = 0.0, prevWall = 0.0
        let startAt = Mono.nowMs()
        while Mono.nowMs() - startAt < 3500 {
            let s = try await httpGet(url: src.url, head: true)
            guard s.dateMs > 0 else { throw TimeSyncError.noDateHeader }
            if prevMs > 0 && prevMs < s.dateMs {
                return (s.dateMs - (prevWall + s.wallAtT1) / 2, s.wallAtT1 - prevWall)
            }
            if s.dateMs != prevMs { prevMs = s.dateMs; prevWall = s.wallAtT1 }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return (0, -1)
    }

    private func burstRollover(_ src: TimeSource, rough: Double) async throws -> (Double, Double) {
        let serverNow = Wall.nowMs() + rough
        let nextBoundary = (serverNow / 1000).rounded(.down) * 1000 + 1000
        let boundaryLocal = nextBoundary - rough
        let sleepMs = (boundaryLocal - 450) - Wall.nowMs()
        guard sleepMs <= 1200 else { return (0, -1) }
        if sleepMs > 0 { try? await Task.sleep(nanoseconds: UInt64(sleepMs * 1_000_000)) }

        var prevMs = 0.0, prevWall = 0.0
        let startAt = Mono.nowMs()
        while Mono.nowMs() - startAt < 1300 {
            let s = try await httpGet(url: src.url, head: true)
            guard s.dateMs > 0 else { throw TimeSyncError.noDateHeader }
            if prevMs > 0 && prevMs < s.dateMs {
                return (s.dateMs - (prevWall + s.wallAtT1) / 2, s.wallAtT1 - prevWall)
            }
            if s.dateMs != prevMs { prevMs = s.dateMs; prevWall = s.wallAtT1 }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return (0, -1)
    }

    // ───────── HTTP（HEAD 探测；URLSession 自动复用连接） ─────────

    struct HttpSample {
        var body = ""
        var dateMs = -1.0
        var rttMs = 0.0
        var wallAtT1 = 0.0
    }

    enum TimeSyncError: LocalizedError {
        case http(Int)
        case noDateHeader
        case badResponse
        var errorDescription: String? {
            switch self {
            case .http(let c): return "HTTP \(c)"
            case .noDateHeader: return "响应缺少 Date 头"
            case .badResponse: return "响应格式异常"
            }
        }
    }

    private func httpGet(url: String, head: Bool) async throws -> HttpSample {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = head ? "HEAD" : "GET"
        req.timeoutInterval = 3.5
        req.setValue("Mozilla/5.0 (iPhone) Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let t0Mono = Mono.nowMs()
        let t0Wall = Wall.nowMs()
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
            throw TimeSyncError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let rtt = Mono.nowMs() - t0Mono
        let wallAtT1 = t0Wall + rtt
        return HttpSample(
            body: head ? "" : String(data: data, encoding: .utf8) ?? "",
            dateMs: http.value(forHTTPHeaderField: "Date").flatMap(parseGmt) ?? -1,
            rttMs: rtt,
            wallAtT1: wallAtT1
        )
    }

    private func parseGmt(_ s: String) -> Double? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.date(from: s).map { $0.timeIntervalSince1970 * 1000 }
    }

    private func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    // ───────── 持久化（UserDefaults，键与双端语义一致） ─────────

    private func persist() {
        let d = UserDefaults.standard
        d.set(selectedId, forKey: "ts_source")
        d.set(manualOffsetMs, forKey: "ts_manual_ms")
        if let data = try? JSONEncoder().encode(Array(results.values)) {
            d.set(data, forKey: "ts_results")
        }
    }

    private func load() {
        let d = UserDefaults.standard
        if let s = d.string(forKey: "ts_source") { selectedId = s }
        let manual = d.double(forKey: "ts_manual_ms")
        manualOffsetMs = manual.clamped(-Self.manualMaxMs...Self.manualMaxMs, fallback: 0)
        if let raw = d.data(forKey: "ts_results"),
           let arr = try? JSONDecoder().decode([SyncResult].self, from: raw) {
            results = Dictionary(uniqueKeysWithValues: arr.map { ($0.sourceId, $0) })
        }
    }

    // ───────── 格式化 ─────────

    static func fmtOffset(_ ms: Double) -> String {
        String(format: "%@%.4fs", ms >= 0 ? "+" : "−", abs(ms) / 1000)
    }

    static func fmtManual(_ ms: Double) -> String {
        ms == 0 ? "±0.0000s" : fmtOffset(ms)
    }

    static func fmtAgo(_ atWall: Double, _ nowWall: Double = Wall.nowMs()) -> String {
        let s = max(0, Int((nowWall - atWall) / 1000))
        if s < 3 { return L("ago.now") }
        if s < 60 { return LF("ago.sec", s) }
        if s < 3600 { return LF("ago.min", s / 60) }
        return LF("ago.hr", s / 3600)
    }
}

extension SyncResult: Codable {}
