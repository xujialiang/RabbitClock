import AVFoundation
import AVKit
import CoreMedia
import UIKit

/**
 * PiP 悬浮时钟（iOS 无悬浮窗权限，全局悬浮走画中画通道）：
 * - 时钟逐帧渲染进 CVPixelBuffer → AVSampleBufferDisplayLayer → AVPictureInPictureController
 * - 后台保活：AVAudioSession .playback + 循环静音 WAV（Info.plist 已声明 audio 后台模式）
 * - PiP 系统自带 关闭/恢复 按钮；暂停/重置回 App 内操作
 * - 显示值加 pipCompMs（呈现深度 + 视频管线约 1 帧 + 扫描位置）延迟补偿
 */
@MainActor
final class PipClockController: NSObject {
    static let shared = PipClockController()

    private let displayLayer = AVSampleBufferDisplayLayer()
    private var pip: AVPictureInPictureController?
    private var renderTimer: Timer?
    private var audioPlayer: AVAudioPlayer?
    private var hostView: UIView?
    private(set) var active = false

    private let bufW = 640
    private let bufH = 320

    // MARK: 生命周期

    func toggleFromApp(_ view: UIView) {
        if active { stop() } else { start(from: view) }
    }

    private func start(from view: UIView) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            AppModel.shared.pipHint = L("pip.nosupport")
            return
        }
        // layer 需挂在窗口内视图上（PiP 启动后由系统接管显示）；
        // 尺寸用视频宽高比的真实值——1×1 退化尺寸会让 PiP 渲染管线拿不到有效 render size
        let host = UIView(frame: CGRect(x: -200, y: -200, width: 160, height: 80))
        view.addSubview(host)
        host.layer.addSublayer(displayLayer)
        displayLayer.frame = host.bounds
        displayLayer.videoGravity = .resizeAspect
        hostView = host

        startKeepAliveAudio()
        renderFrame() // 先入队一帧，否则 PiP 无法启动

        if pip == nil {
            let src = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
            pip = AVPictureInPictureController(contentSource: src)
            pip?.delegate = self
            // 时钟是"直播"内容：藏掉快进/快退按钮（暂停键为系统 UI，静置数秒自动隐藏）
            pip?.requiresLinearPlayback = true
        }
        pip?.startPictureInPicture()
    }

    func stop() {
        pip?.stopPictureInPicture()
        teardown()
    }

    private func teardown() {
        renderTimer?.invalidate()
        renderTimer = nil
        audioPlayer?.stop()
        audioPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        hostView?.removeFromSuperview()
        hostView = nil
        active = false
        AppModel.shared.floatVisible = false
    }

    // MARK: 渲染循环

    private func startRenderLoop() {
        renderTimer?.invalidate()
        // 秒级 15fps；毫秒模式 30fps（PiP 视频链路保持喂帧才不会停）
        let style = AppModel.shared.style
        let fastMode = AppModel.shared.mode == .stopwatch ||
            (AppModel.shared.mode == .clock && style.showMillis)
        let fps: Double = fastMode ? 30 : 15
        renderTimer = Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.renderFrame()
            }
        }
    }

    private func renderFrame() {
        // failed 后 enqueue 会被静默丢弃（黑屏）；flush 复位管线状态
        if displayLayer.status == .failed { displayLayer.flush() }
        guard displayLayer.isReadyForMoreMediaData else { return }
        guard let px = makePixelBuffer() else { return }
        drawClock(into: px)
        guard let sb = sampleBuffer(from: px) else { return }
        displayLayer.enqueue(sb)
    }

    private func makePixelBuffer() -> CVPixelBuffer? {
        var px: CVPixelBuffer?
        // IOSurface 背书是硬性要求：AVSampleBufferDisplayLayer 只接受 IOSurface-backed
        // 缓冲，缺了它 enqueue 直接失败、层进入 failed 状态 → PiP 黑屏
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, bufW, bufH, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &px)
        return px
    }

    private struct ClockText {
        var main = ""
        var sec = ""
        var ms = ""
        var sub = ""
    }

    private func currentText() -> ClockText {
        let style = AppModel.shared.style
        let mode = AppModel.shared.mode
        let comp = DisplayTiming.pipCompMs(yFrac: 0.5)
        var out = ClockText()
        switch mode {
        case .clock:
            let displayNow = TimeSync.shared.now() + comp
            let p = Fmt.clock(h24: style.hour24, withSeconds: style.showSeconds,
                              millisDigits: style.showMillis ? style.millisDigits : 0, nowWall: displayNow)
            out.main = p.main
            out.sec = p.sec
            out.ms = p.ms
            var bits: [String] = []
            if style.showDate { bits.append(Fmt.dateLine(displayNow)) }
            if style.showWeek { bits.append(Fmt.weekLine(displayNow)) }
            out.sub = bits.joined(separator: " · ")
        case .stopwatch:
            let p = Fmt.stopwatch(AppModel.shared.stopwatch.elapsed(nowMs: Mono.nowMs() + comp),
                                  millisDigits: max(1, style.millisDigits))
            out.main = p.main
            out.ms = p.ms
        case .countdown:
            out.main = Fmt.countdown(AppModel.shared.countdown.remain(nowMs: Mono.nowMs() + comp))
        }
        return out
    }

    /// 把「时钟该显示的内容」画进像素缓冲：深底 + 圆角胶囊 + 等宽字体时间
    private func drawClock(into px: CVPixelBuffer) {
        let style = AppModel.shared.style
        let t = currentText()

        CVPixelBufferLockBaseAddress(px, [])
        defer { CVPixelBufferUnlockBaseAddress(px, []) }

        let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(px),
            width: bufW,
            height: bufH,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(px),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        guard let ctx else { return }

        let accent = UIColor(hex: style.colorHex)

        // 背景：近黑底（PiP 不支持透明）+ 圆角胶囊
        ctx.setFillColor(CGColor(red: 0.02, green: 0.03, blue: 0.06, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: bufW, height: bufH))
        let capsule = CGRect(x: Double(bufW) * 0.04, y: Double(bufH) * 0.22,
                             width: Double(bufW) * 0.92, height: Double(bufH) * 0.56)
        let path = CGPath(
            roundedRect: capsule,
            cornerWidth: capsule.height / 2,
            cornerHeight: capsule.height / 2,
            transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(accent.withAlphaComponent(0.16).cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(accent.withAlphaComponent(0.5).cgColor)
        ctx.setLineWidth(2)
        ctx.strokePath()

        // 主时间文字（等宽数字）
        let fontRatio = min(0.52 * (style.scale / 1.15), 0.62)
        let fontSz = capsule.height * fontRatio
        let font = UIFont.monospacedDigitSystemFont(ofSize: fontSz, weight: .bold)
        let text = t.main + t.sec + t.ms
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: accent,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let tx = capsule.midX - size.width / 2
        let tyTop = capsule.midY - size.height / 2

        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(bufH))
        ctx.scaleBy(x: 1, y: -1)
        // NSString.draw 是 UIKit 调用，只画进 UIGraphics 栈里的当前上下文；
        // 必须把 CVPixelBuffer 的 CGContext 压栈，否则文字静默不渲染（形状不受影响）
        UIGraphicsPushContext(ctx)
        (text as NSString).draw(at: CGPoint(x: tx, y: CGFloat(bufH) - tyTop - size.height),
                                withAttributes: attrs)
        if !t.sub.isEmpty {
            let subFont = UIFont.systemFont(ofSize: capsule.height * 0.13)
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: subFont,
                .foregroundColor: accent.withAlphaComponent(0.92),
            ]
            let ss = (t.sub as NSString).size(withAttributes: subAttrs)
            (t.sub as NSString).draw(
                at: CGPoint(x: capsule.midX - ss.width / 2, y: CGFloat(bufH) - capsule.minY + 6),
                withAttributes: subAttrs)
        }
        UIGraphicsPopContext()
        ctx.restoreGState()
    }

    private func sampleBuffer(from px: CVPixelBuffer) -> CMSampleBuffer? {
        var desc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: px, formatDescriptionOut: &desc)
        guard let desc else { return nil }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600),
            decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: px,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: desc,
            sampleTiming: &timing,
            sampleBufferOut: &sb)
        return sb
    }

    // MARK: 后台保活（循环静音）

    private func startKeepAliveAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.silentWav())
            player.numberOfLoops = -1
            player.volume = 0.01
            player.play()
            audioPlayer = player
        } catch {
            NSLog("[pip] keep-alive audio failed: \(error)")
        }
    }

    /// 生成 1 秒静音 WAV（16bit/8kHz/mono，循环播放保活）
    static func silentWav() -> Data {
        let sampleRate = 8000
        let dataLen = sampleRate * 2
        var d = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append("RIFF".data(using: .ascii)!)
        le32(UInt32(36 + dataLen))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!)
        le32(16); le16(1); le16(1)
        le32(UInt32(sampleRate)); le32(UInt32(sampleRate * 2)); le16(2); le16(16)
        d.append("data".data(using: .ascii)!)
        le32(UInt32(dataLen))
        d.append(Data(count: dataLen))
        return d
    }
}

// MARK: - AVPictureInPictureControllerDelegate
// AVFoundation 回调本身在主线程送达；@preconcurrency 消除跨隔离诊断（Swift 6 下为错误）
extension PipClockController: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        active = true
        // 系统接管渲染管线时会清空已入队帧：flush 复位后立刻补一帧，避免 PiP 窗口黑屏
        displayLayer.flush()
        renderFrame()
        startRenderLoop()
        AppModel.shared.floatVisible = true
        AppModel.shared.pipHint = nil
    }

    func pictureInPictureControllerWillStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        renderTimer?.invalidate()
        renderTimer = nil
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        teardown()
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        AppModel.shared.pipHint = LF("pip.fail", error.localizedDescription)
        teardown()
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension PipClockController: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ controller: AVPictureInPictureController
    ) -> CMTimeRange { CMTimeRange(start: .zero, duration: .positiveInfinity) }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ controller: AVPictureInPictureController
    ) -> Bool { false }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) { completionHandler() }
}

extension UIColor {
    convenience init(hex: String) {
        var v: UInt64 = 0
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        Scanner(string: s).scanHexInt64(&v)
        self.init(
            red: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1)
    }
}
