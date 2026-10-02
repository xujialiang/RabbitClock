import Foundation
import UIKit

/// 显示时序：把「计算时刻的时间」换算成「像素点亮时刻的时间」（与双端同构）。
/// iOS 上 ProMotion 实际刷新率动态变化（80~120Hz），maximumFramesPerSecond 为上限，
/// 悬浮 PiP 视频链路另加固定视频管线延迟。
enum DisplayTiming {
    static let depthKey = "ts_present_depth"

    /// 呈现深度（帧）：默认 1；可调 1/1.5/2（持久化 UserDefaults）
    static var presentDepth: Double {
        get { UserDefaults.standard.double(forKey: depthKey).clamped(1...2, fallback: 1) }
        set { UserDefaults.standard.set(newValue, forKey: depthKey) }
    }

    static func refreshRateHz() -> Double {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        return Double(scene?.screen.maximumFramesPerSecond ?? 60)
    }

    static func periodMs(hz: Double) -> Double { hz > 1 ? 1000 / hz : 1000 / 60 }

    /// 屏幕高度占比 yFrac 处像素的「从现在到点亮」延迟（呈现深度 + 面板扫描位置）
    static func compMs(yFrac: Double, depth: Double = presentDepth) -> Double {
        periodMs(hz: refreshRateHz()) * (depth + yFrac.clamped(0...1, fallback: 0))
    }

    /// PiP 悬浮链路：视频合成器额外约 1 帧延迟
    static func pipCompMs(yFrac: Double) -> Double {
        periodMs(hz: refreshRateHz()) * (presentDepth + 1 + yFrac.clamped(0...1, fallback: 0))
    }
}

extension Double {
    func clamped(_ range: ClosedRange<Double>, fallback: Double) -> Double {
        range.contains(self) ? self : fallback
    }
}
