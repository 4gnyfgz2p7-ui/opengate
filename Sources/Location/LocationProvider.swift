import Foundation
import CoreLocation
import Combine

/// 每次开录只取一次位置。
///
/// 为什么是「开录前一次性取」而不是录制中持续更新：
/// `AVAssetWriter.metadata` 必须在 `startWriting()` **之前**赋值——元数据写在
/// 文件头，startWriting 之后再改不会落盘。所以位置必须赶在启动前拿到，
/// 因此这里用「限时等待 + 缓存兜底」，而不是 startUpdatingLocation 长期跟踪。
///
/// 设计底线：定位失败绝不阻塞录制。拿不到就写无位置的文件，录制照常进行。
@MainActor
final class LocationProvider: NSObject, ObservableObject {

    // MARK: - 结果模型

    struct Fix {
        let latitude: Double
        let longitude: Double
        let altitude: Double?
        let horizontalAccuracy: Double
        let timestamp: Date
        /// 是否为缓存位置（本次没有拿到新的定位）
        let isCached: Bool
        /// 是否在「模糊位置」授权下取得（精度约 5 km，仅作参考）
        let isReducedAccuracy: Bool

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        /// 人读概要，用于界面与报告
        var summary: String {
            var parts = [String(format: "%.5f, %.5f", latitude, longitude)]
            parts.append(String(format: "±%.0f m", horizontalAccuracy))
            if let altitude = altitude {
                parts.append(String(format: "海拔 %.1f m", altitude))
            }
            if isCached { parts.append("缓存") }
            if isReducedAccuracy { parts.append("模糊位置") }
            return parts.joined(separator: " · ")
        }
    }

    enum Outcome {
        case fixed(Fix)
        case denied
        case timedOut(Fix?)
        case failed(String)

        var fix: Fix? {
            switch self {
            case .fixed(let fix): return fix
            case .timedOut(let fix): return fix
            case .denied, .failed: return nil
            }
        }

        var displayText: String {
            switch self {
            case .fixed(let fix):
                return fix.summary
            case .denied:
                return "未授权定位，本条视频不带位置"
            case .timedOut(let cached):
                if let cached = cached {
                    return "定位超时，沿用 \(Int(Date().timeIntervalSince(cached.timestamp))) 秒前的位置"
                }
                return "定位超时，本条视频不带位置"
            case .failed(let reason):
                return "定位失败：\(reason)"
            }
        }

        /// 是否需要在界面上提示用户
        var isDegraded: Bool {
            switch self {
            case .fixed(let fix): return fix.isCached || fix.isReducedAccuracy
            case .denied, .timedOut, .failed: return true
            }
        }
    }

    // MARK: - 参数

    /// 临时精确定位的用途键，必须与 Info.plist 的
    /// `NSLocationTemporaryUsageDescriptionDictionary` 中的键一致。
    static let purposeKey = "PreciseRecordingLocation"

    /// 认为「够用」的水平精度阈值（米）
    private let acceptableAccuracy: Double = 25

    /// 缓存位置的最大可接受年龄（秒）
    private let maxCacheAge: TimeInterval = 60

    // MARK: - 状态

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var waitingForAuthorization = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
    }

    // MARK: - 对外接口

    /// 取一次位置。超时后返回缓存（若有）或 `.timedOut(nil)`，从不抛错。
    func requestOnce(timeout: TimeInterval = 3.0) async -> Outcome {
        // 已有请求在飞，先取消旧的，避免 continuation 泄漏
        finish(with: .failed("新的定位请求取代了旧请求"))

        switch manager.authorizationStatus {
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            waitingForAuthorization = true
            manager.requestWhenInUseAuthorization()
            // 授权弹窗的响应时间不可控，这里给更长的等待窗口
            return await waitForFix(timeout: max(timeout, 15.0), allowCache: false)
        case .authorizedWhenInUse, .authorizedAlways:
            break
        @unknown default:
            return .failed("未知的定位授权状态")
        }

        // 用户可能只给了模糊位置，尝试换取一次临时精确授权
        if manager.accuracyAuthorization == .reducedAccuracy {
            await requestTemporaryPreciseAccuracy()
        }

        // 手头已有新鲜且够准的位置，直接用，不必等卫星
        if let cached = freshCachedFix() {
            return .fixed(cached)
        }

        return await waitForFix(timeout: timeout, allowCache: true)
    }

    /// 供界面显示当前授权概况
    var authorizationDescription: String {
        switch manager.authorizationStatus {
        case .denied: return "定位已拒绝"
        case .restricted: return "定位受限制"
        case .notDetermined: return "尚未询问定位"
        case .authorizedWhenInUse: return "使用期间可定位"
        case .authorizedAlways: return "始终可定位"
        @unknown default: return "定位状态未知"
        }
    }

    var hasPreciseAccuracy: Bool {
        manager.accuracyAuthorization == .fullAccuracy
    }

    // MARK: - 内部

    private func requestTemporaryPreciseAccuracy() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: Self.purposeKey) { _ in
                continuation.resume()
            }
        }
    }

    private func waitForFix(timeout: TimeInterval, allowCache: Bool) async -> Outcome {
        manager.startUpdatingLocation()

        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            self.continuation = continuation

            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self = self else { return }
                    let fallback = allowCache ? self.freshCachedFix(ignoringAccuracy: true) : nil
                    self.finish(with: .timedOut(fallback))
                }
            }
        }

        manager.stopUpdatingLocation()
        return outcome
    }

    private func freshCachedFix(ignoringAccuracy: Bool = false) -> Fix? {
        guard let location = manager.location else { return nil }
        let age = Date().timeIntervalSince(location.timestamp)
        guard age >= 0, age <= maxCacheAge else { return nil }
        guard location.horizontalAccuracy > 0 else { return nil }
        if !ignoringAccuracy {
            guard location.horizontalAccuracy <= acceptableAccuracy else { return nil }
        }
        return makeFix(location, isCached: true)
    }

    private func makeFix(_ location: CLLocation, isCached: Bool) -> Fix {
        Fix(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
            horizontalAccuracy: location.horizontalAccuracy,
            timestamp: location.timestamp,
            isCached: isCached,
            isReducedAccuracy: manager.accuracyAuthorization == .reducedAccuracy
        )
    }

    private func finish(with outcome: Outcome) {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let continuation = continuation {
            self.continuation = nil
            continuation.resume(returning: outcome)
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationProvider: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard self.continuation != nil else { return }
            guard let location = locations.last else { return }
            guard location.horizontalAccuracy > 0 else { return }

            let isPreciseEnough = location.horizontalAccuracy <= self.acceptableAccuracy
            let isFresh = -location.timestamp.timeIntervalSinceNow < 5

            if isPreciseEnough && isFresh {
                self.finish(with: .fixed(self.makeFix(location, isCached: false)))
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            guard self.continuation != nil else { return }
            let nsError = error as NSError
            // kCLErrorLocationUnknown 是暂时性失败，继续等定位，不要提前收尾
            if nsError.domain == kCLErrorDomain, nsError.code == CLError.locationUnknown.rawValue {
                return
            }
            self.finish(with: .failed(error.localizedDescription))
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.waitingForAuthorization else { return }
            let status = manager.authorizationStatus
            guard status != .notDetermined else { return }
            self.waitingForAuthorization = false

            switch status {
            case .denied, .restricted:
                self.finish(with: .denied)
            default:
                // 已授权，开始真正取点
                self.manager.startUpdatingLocation()
            }
        }
    }
}
