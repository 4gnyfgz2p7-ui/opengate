import AVFoundation

/// 一个可选的镜头。
///
/// 刻意用**物理设备**而不是 `builtInTripleCamera` 这类虚拟设备：
/// 虚拟设备的格式集与主摄不同，Open Gate 的 4224×3024 Bayer 只有物理主摄提供，
/// 换成虚拟设备会直接丢掉 RAW 通路。代价是切镜头要重建会话，收益是 RAW 还在。
struct LensOption: Identifiable, Hashable {

    /// 物理设备用 uniqueID；数字变焦档用固定标识
    let id: String
    let label: String
    /// 该镜头是否提供 4224×3024 全幅格式（ProRes RAW 的前提）
    let supportsOpenGate: Bool
    /// 非物理镜头时的变焦倍数（例如 8× 是主摄/长焦的传感器裁切）
    let zoomFactor: CGFloat?

    var isPhysical: Bool { zoomFactor == nil }
}

enum LensCatalog {

    static let openGateWidth: Int32 = 4224
    static let openGateHeight: Int32 = 3024

    /// 后置可选镜头。至少包含超广、主摄；有长焦就再加一个。
    static func backLenses() -> [LensOption] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video,
            position: .back
        )

        var seen = Set<String>()
        var devices: [AVCaptureDevice] = []
        for device in discovery.devices where seen.insert(device.uniqueID).inserted {
            devices.append(device)
        }

        var options: [LensOption] = []
        for device in devices {
            let hasGate = device.formats.contains { format in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return dims.width == openGateWidth && dims.height == openGateHeight
            }
            options.append(
                LensOption(
                    id: device.uniqueID,
                    label: label(for: device, among: devices),
                    supportsOpenGate: hasGate,
                    zoomFactor: nil
                )
            )
        }

        options.sort { order($0.label) < order($1.label) }

        // 8×：只有在系统真的报出 8× 换挡点时才给这一档，
        // 否则它只是纯数字放大，摆在镜头轨里会误导。
        if let eight = eightTimesFactor() {
            options.append(
                LensOption(id: "zoom-8", label: "8×", supportsOpenGate: false,
                           zoomFactor: CGFloat(eight))
            )
        }

        return options
    }

    /// 系统报出的镜头换挡点（相对超广角 FOV）。
    ///
    /// 这是判断「有没有 8×」唯一可靠的依据：`maxAvailableVideoZoomFactor`
    /// 全系都在 100 以上，那是数字放大，不代表有 8× 光学档。
    static func switchFactors() -> [Double] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera],
            mediaType: .video,
            position: .back
        )
        guard let virtual = discovery.devices.first else { return [] }
        return virtual.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue)
    }

    /// 有 8× 光学档时返回倍数，否则 nil。
    static func eightTimesFactor() -> Double? {
        switchFactors().first { abs($0 - 8) < 0.35 }
    }

    private static func label(for device: AVCaptureDevice, among devices: [AVCaptureDevice]) -> String {
        switch device.deviceType {
        case .builtInUltraWideCamera:
            return "0.5×"
        case .builtInWideAngleCamera:
            return "1×"
        case .builtInTelephotoCamera:
            // 长焦倍数没有直接 API：用虚拟设备的换挡点里最大的那个当标签，
            // 拿不到就写「长焦」，不编数字。
            if let factor = switchFactors().max(), factor > 1.5 {
                return String(format: "%.0f×", factor)
            }
            return "长焦"
        default:
            return "?"
        }
    }

    private static func order(_ label: String) -> Double {
        let digits = label.prefix { $0.isNumber || $0 == "." }
        return Double(digits) ?? 99
    }
}
