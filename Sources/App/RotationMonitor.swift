import Foundation
import UIKit

/// 旋转链路监测。
///
/// 「点方向键瞬间黑屏、界面无响应」此前缺证据：不知道是几何申请没生效、
/// 窗口没转、预览连接断了，还是主线程真被卡住。这里把整条链逐步记进时间线：
/// 按键 → 锁支持面 → 几何申请（含系统回执）→ 窗口实际尺寸/安全区/方向 → 预览连接状态，
/// 并用 Timer 看门狗测主线程停顿（0.25 s 心跳，偏差超 0.6 s 记一次卡顿）。
///
/// 查看：设置 → 方向监测（最近 40 条）。落盘 Documents/rotation-log.txt，闪退后仍在。
/// 开销：看门狗只在每次按键后跑 3 秒；记录只在事件发生时发生，无常驻刷新。
@MainActor
final class RotationMonitor: ObservableObject {

    static let shared = RotationMonitor()

    struct Event: Identifiable, Equatable {
        let id = UUID()
        /// 距进程启动的秒数
        let t: TimeInterval
        let text: String
    }

    @Published private(set) var events: [Event] = []

    /// 几何申请发出但窗口尚未跟上的持续秒数；nil = 没有在等的申请
    var pendingElapsed: TimeInterval? {
        guard let pendingPressDate else { return nil }
        return Date().timeIntervalSince(pendingPressDate)
    }

    private let boot = Date()
    private var pendingPressDate: Date?
    private var pendingLandscape: Bool?
    private var lastPreviewKey = ""
    private var lastWindowKey = ""
    private var watchdog: Timer?
    private var watchdogUntil = Date.distantPast
    private var lastFire = Date.distantPast

    /// 日志文件：设置页可直接分享，也可以连电脑取
    let logURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("rotation-log.txt")
    }()

    private init() {}

    // MARK: - 记录

    func note(_ text: String) {
        let event = Event(t: Date().timeIntervalSince(boot), text: text)
        events.append(event)
        if events.count > 40 {
            events.removeFirst(events.count - 40)
        }
        appendToFile(event)
    }

    /// 方向键按下：布防看门狗（3 秒窗口），记录按键瞬间与会话状态
    func notePress(from: CGFloat, to: CGFloat, sessionReady: Bool, sessionRunning: Bool) {
        note("── 方向键 \(Int(from))° → \(Int(to))°（会话 \(sessionReady ? "就绪" : "未就绪") · \(sessionRunning ? "运行中" : "已停")）")
        armWatchdog()
    }

    /// 锁支持面 + 几何申请发出。回执走 noteRequestResult。
    func noteRequest(_ targetName: String, target: UIInterfaceOrientation, scene: UIWindowScene?) {
        if let scene, scene.interfaceOrientation == target {
            note("窗口已在位 \(targetName)，跳过申请")
            pendingPressDate = nil
            pendingLandscape = nil
            return
        }
        pendingPressDate = Date()
        pendingLandscape = target == .landscapeLeft || target == .landscapeRight
        note("几何申请 \(targetName) 发出")
    }

    func noteRequestResult(_ errorDescription: String?) {
        if let errorDescription {
            note("几何申请回执：失败 —— \(errorDescription)")
        } else {
            note("几何申请回执：系统接受")
        }
    }

    /// 窗口尺寸/方向变化（同一尺寸只记一次）。顺带判定本次申请是否已生效。
    func noteWindow(size: CGSize, insets: UIEdgeInsets, scale: CGFloat, orientationName: String) {
        let pxW = Int(size.width * scale)
        let pxH = Int(size.height * scale)
        let key = "\(Int(size.width))x\(Int(size.height))|\(orientationName)"
        guard key != lastWindowKey else { return }
        lastWindowKey = key

        let landscape = size.width > size.height
        note("窗口 \(Int(size.width))×\(Int(size.height)) pt = \(pxW)×\(pxH) px @\(Int(scale))x · \(orientationName) · 安全区 左\(Int(insets.left)) 右\(Int(insets.right)) 上\(Int(insets.top)) 下\(Int(insets.bottom))")

        if let since = pendingPressDate, let wantLandscape = pendingLandscape {
            if wantLandscape == landscape {
                note("窗口跟上申请，用时 \(String(format: "%.2f", Date().timeIntervalSince(since))) s")
                pendingPressDate = nil
                pendingLandscape = nil
            }
        }
    }

    /// 预览连接状态（状态不变不重复记）。
    func notePreview(connectionNil: Bool, angle: Int, supported: Bool) {
        let key = "\(connectionNil)|\(angle)|\(supported)"
        guard key != lastPreviewKey else { return }
        lastPreviewKey = key
        if connectionNil {
            note("预览连接不存在（会话未跑或连接已失效）")
        } else {
            note("预览连接 angle=\(angle)° \(supported ? "· 支持目标角度" : "· 不支持目标角度")")
        }
    }

    /// 逃生门放行时的记录
    func noteEscape(after seconds: TimeInterval) {
        note("几何 \(String(format: "%.1f", seconds)) s 未生效，放行界面（宁可有瑕疵不黑屏）")
    }

    // MARK: - 看门狗

    /// 0.25 s 心跳。主线程一旦被卡，下一次触发会迟到，迟到量即停顿时长。
    private func armWatchdog(seconds: TimeInterval = 3) {
        watchdogUntil = Date().addingTimeInterval(seconds)
        lastFire = Date()
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                self?.tick(timer)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func tick(_ timer: Timer) {
        let now = Date()
        let gap = now.timeIntervalSince(lastFire)
        // 计划 0.25 s，连续两次心跳丢失即视为一次可感知的卡顿
        if gap > 0.6 {
            note("主线程停顿 \(String(format: "%.2f", gap)) s（心跳计划间隔 0.25 s）")
        }
        lastFire = now
        if now > watchdogUntil {
            timer.invalidate()
            watchdog = nil
        }
    }

    // MARK: - 落盘

    var logText: String {
        events.map { String(format: "[%8.2fs] %@", $0.t, $0.text) }.joined(separator: "\n")
    }

    private func appendToFile(_ event: Event) {
        guard let data = event.text.data(using: .utf8) else { return }
        let line = String(format: "[%8.2fs] %@\n", event.t, event.text)
        let payload = line.data(using: .utf8) ?? data
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            if handle.seekToEndOfFile() >= UInt64(512 * 1024) {
                // 文件超过 512 KB 就重开，防无限膨胀
                try? FileManager.default.removeItem(at: logURL)
                try? payload.write(to: logURL)
                return
            }
            handle.write(payload)
        } else {
            try? payload.write(to: logURL)
        }
    }
}
