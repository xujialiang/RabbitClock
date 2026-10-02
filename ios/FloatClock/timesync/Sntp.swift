import Foundation
import Network

/// SNTP 客户端（RFC 5905 48 字报文，UDP 123）。完整 NTP 偏移公式，
/// 是默认「北京时间」源的首选通道；UDP 被拦时由上层回落 HTTP 秒沿法。
enum Sntp {
    struct Sample {
        let offsetMs: Double
        let delayMs: Double
    }

    static func probe(host: String, timeoutMs: Double = 2500) async -> Sample? {
        await withCheckedContinuation { cont in
            let conn = NWConnection(
                host: NWEndpoint.Host(host), port: 123,
                using: NWParameters.udp
            )
            var finished = false
            let queue = DispatchQueue(label: "sntp")
            let finish: (Sample?) -> Void = { s in
                queue.async {
                    guard !finished else { return }
                    finished = true
                    conn.cancel()
                    cont.resume(returning: s)
                }
            }
            queue.asyncAfter(deadline: .now() + timeoutMs / 1000) { finish(nil) }

            let t0Mono = Mono.nowMs()
            let t0Wall = Wall.nowMs()

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var req = [UInt8](repeating: 0, count: 48)
                    req[0] = 0x1B // LI=0 VN=3 Mode=3(client)
                    conn.send(content: Data(req), completion: .contentProcessed { _ in })
                    receiveOnce(conn: conn) { data in
                        let t1Mono = Mono.nowMs()
                        guard let data, data.count >= 48 else { finish(nil); return }
                        let b = [UInt8](data)
                        let mode = b[0] & 0x07
                        let stratum = b[1]
                        guard mode == 4 || mode == 5, stratum != 0 else { finish(nil); return }
                        guard let t2 = ntpMs(b, 32), let t3 = ntpMs(b, 40) else { finish(nil); return }
                        // NTP θ=((T2−T1)+(T3−T4))/2 等价实现：服务器中点 − 本地中点
                        let rtt = t1Mono - t0Mono
                        let wallMid = t0Wall + rtt / 2
                        let serverMid = (t2 + t3) / 2
                        finish(Sample(offsetMs: serverMid - wallMid, delayMs: rtt))
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    private static func receiveOnce(conn: NWConnection, onDone: @escaping (Data?) -> Void) {
        conn.receive(minimumIncompleteLength: 48, maximumLength: 64) { data, _, _, error in
            onDone(error == nil ? data : nil)
        }
    }

    /// NTP 64 位时间戳（32 位秒 + 32 位小数）→ Unix 毫秒；2020~2035 之外视为异常
    private static func ntpMs(_ b: [UInt8], _ off: Int) -> Double? {
        let sec = u32(b, off)
        guard sec != 0 else { return nil }
        let frac = u32(b, off + 4)
        let unix = Double(sec - 2_208_988_800) * 1000 + Double(frac) / 4_294_967.296
        return (1_577_836_800_000...2_051_224_000_000).contains(unix) ? unix : nil
    }

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }
}
