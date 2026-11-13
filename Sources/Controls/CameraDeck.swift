import SwiftUI

/// 五个可调参数。横竖屏共用同一套语义，界面只负责画成什么形状。
enum CameraParameter: String, CaseIterable, Identifiable {
    case shutter
    case iso
    case focus
    case exposure
    case whiteBalance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shutter: return "快门"
        case .iso: return "ISO"
        case .focus: return "焦距"
        case .exposure: return "曝光"
        case .whiteBalance: return "白平衡"
        }
    }
}

/// 参数面板的状态与动作。
///
/// 横屏和竖屏各画一套版式，但**行为只写这一份**：
/// 「第一次按只选中、已选中的再按切自动/手动、A 钮只把选中项交还系统、
/// 拖拽写设备」——这些规则上一轮在横屏里逐条修过，
/// 如果竖屏再抄一遍，两份迟早会漂，而且漂了不容易发现。
@MainActor
struct CameraDeck {

    /// 当前选中的参数。选中只影响颜色与拖拽条指向，不改设备。
    private(set) var selection: CameraParameter = .shutter

    /// 曝光的「自动」是本层语义：自动＝补偿归零且不接受拖拽。
    /// 设备侧没有「曝光补偿自动」这个模式，只有 bias 值。
    private(set) var exposureManual = false

    init() {}

    // MARK: - 自动判定

    func isAuto(_ parameter: CameraParameter, _ engine: RecordingEngine) -> Bool {
        switch parameter {
        case .shutter:
            return engine.exposure.mode != .manualShutter && engine.exposure.mode != .manualBoth
        case .iso:
            return engine.exposure.mode != .manualISO && engine.exposure.mode != .manualBoth
        case .focus:
            return engine.focus.mode != .manual
        case .exposure:
            return !exposureManual
        case .whiteBalance:
            return engine.whiteBalance.mode != .manual
        }
    }

    // MARK: - 交互

    /// 第一次按只选中；已选中的再按一次切自动 / 手动。
    mutating func tap(_ parameter: CameraParameter, _ engine: RecordingEngine) {
        guard selection == parameter else {
            selection = parameter
            return
        }
        toggleAuto(parameter, engine)
    }

    /// A 钮只作用于当前选中的参数：已经是自动就不动，手动就切回自动。
    /// 刻意不做「全部自动」——五个参数一起跳，画面会同时变亮、变焦、变色，
    /// 看不出是哪一项在动。
    mutating func setAuto(_ parameter: CameraParameter, _ engine: RecordingEngine) {
        guard !isAuto(parameter, engine) else { return }
        toggleAuto(parameter, engine)
    }

    private mutating func toggleAuto(_ parameter: CameraParameter, _ engine: RecordingEngine) {
        let targetAuto = !isAuto(parameter, engine)
        switch parameter {
        case .shutter:
            let isoAuto = isAuto(.iso, engine)
            switch (targetAuto, isoAuto) {
            case (true, true): engine.exposure.mode = .autoBoth
            case (true, false): engine.exposure.mode = .manualISO
            case (false, true): engine.exposure.mode = .manualShutter
            case (false, false): engine.exposure.mode = .manualBoth
            }
        case .iso:
            let shutterAuto = isAuto(.shutter, engine)
            switch (targetAuto, shutterAuto) {
            case (true, true): engine.exposure.mode = .autoBoth
            case (true, false): engine.exposure.mode = .manualShutter
            case (false, true): engine.exposure.mode = .manualISO
            case (false, false): engine.exposure.mode = .manualBoth
            }
        case .focus:
            engine.focus.mode = targetAuto ? .continuous : .manual
        case .exposure:
            exposureManual = !targetAuto
            if targetAuto { engine.exposure.ev = 0 }
        case .whiteBalance:
            engine.whiteBalance.mode = targetAuto ? .auto : .manual
        }
    }

    // MARK: - 拖拽条

    /// 归一化到 0…1 的当前位置。竖条与横条共用同一套映射。
    func position(_ parameter: CameraParameter, _ engine: RecordingEngine) -> Double {
        switch parameter {
        case .shutter: return engine.exposure.shutterSliderPosition
        case .iso: return engine.exposure.isoSliderPosition
        case .focus: return Double(engine.focus.lensPosition)
        case .exposure: return Self.normalize(Double(engine.exposure.ev), -3, 3)
        case .whiteBalance: return Self.normalize(Double(engine.whiteBalance.temperature), 2000, 9000)
        }
    }

    mutating func apply(_ parameter: CameraParameter, position t: Double, _ engine: RecordingEngine) {
        switch parameter {
        case .shutter:
            engine.exposure.shutterSliderPosition = t
        case .iso:
            engine.exposure.isoSliderPosition = t
        case .focus:
            engine.focus.mode = .manual
            engine.focus.lensPosition = Float(t)
        case .exposure:
            exposureManual = true
            engine.exposure.ev = Float(Self.denormalize(t, -3, 3))
        case .whiteBalance:
            engine.whiteBalance.mode = .manual
            engine.whiteBalance.temperature = Float(Self.denormalize(t, 2000, 9000))
        }
    }

    // MARK: - 读数

    /// 圆钮里的大字：优先显示设备回读的实时值，拿不到才退回设定值。
    func knobValue(_ parameter: CameraParameter, _ engine: RecordingEngine) -> String {
        switch parameter {
        case .shutter:
            return engine.exposure.formatShutter(
                engine.exposure.liveShutterSeconds > 0
                    ? engine.exposure.liveShutterSeconds
                    : engine.exposure.shutterSeconds
            )
        case .iso:
            let live = engine.exposure.liveISO
            return String(format: "%.0f", live > 0 ? live : engine.exposure.iso)
        case .focus:
            return String(format: "%.2f", engine.focus.liveLensPosition)
        case .exposure:
            return String(format: "%+.1f", engine.exposure.ev)
        case .whiteBalance:
            let live = engine.whiteBalance.liveTemperature
            return String(format: "%.0f", live > 0 ? live : engine.whiteBalance.temperature)
        }
    }

    /// 拖拽条上的读数：带单位，空间够就写全。
    func readout(_ parameter: CameraParameter, _ engine: RecordingEngine) -> String {
        switch parameter {
        case .shutter:
            return engine.exposure.formatShutter(engine.exposure.liveShutterSeconds)
        case .iso:
            return String(format: "ISO %.0f", engine.exposure.liveISO)
        case .focus:
            return String(format: "%.2f", engine.focus.liveLensPosition)
        case .exposure:
            return String(format: "%+.1f EV", engine.exposure.ev)
        case .whiteBalance:
            let live = engine.whiteBalance.liveTemperature
            return String(format: "%.0fK", live > 0 ? live : engine.whiteBalance.temperature)
        }
    }

    // MARK: - 映射

    static func normalize(_ value: Double, _ low: Double, _ high: Double) -> Double {
        guard high > low else { return 0 }
        return min(max((value - low) / (high - low), 0), 1)
    }

    static func denormalize(_ position: Double, _ low: Double, _ high: Double) -> Double {
        low + (high - low) * min(max(position, 0), 1)
    }
}

/// 时间与容量的统一写法。横竖屏各画各的，但数字格式只此一份。
enum CameraFormat {

    static func timecode(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        if seconds >= 3600 { return String(format: "%.1fh", seconds / 3600) }
        if seconds >= 60 { return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
        return String(format: "0:%02d", Int(seconds))
    }
}
