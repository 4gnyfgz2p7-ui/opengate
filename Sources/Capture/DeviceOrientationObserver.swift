import Foundation
import UIKit
import Combine

/// 界面方向：只有两种，横屏与竖屏。
///
/// 之前的四向轮转（竖拍 / 横拍 A / 横拍 B / 竖拍倒置）把「常用」和「纠正」
/// 混在一个按钮里，实际用起来要按三四下才到想要的方向，还容易按过头。
/// 现在收敛成两档：
/// - **默认横屏**（0°）：开机就是这个方向；
/// - 设置或画面上的小按钮切到竖屏（90°）。
///
/// 选择落盘，下次打开沿用。
enum InterfaceMode: String, CaseIterable, Identifiable {
    case landscape
    case portrait

    var id: String { rawValue }

    var title: String {
        switch self {
        case .landscape: return "横屏"
        case .portrait: return "竖屏"
        }
    }

    /// 后置相机下：0° 即横拍 A，90° 即竖拍正立。
    var degrees: CGFloat {
        switch self {
        case .landscape: return 0
        case .portrait: return 90
        }
    }

    var mask: UIInterfaceOrientationMask {
        switch self {
        case .landscape: return .landscapeRight
        case .portrait: return .portrait
        }
    }

    var opposite: InterfaceMode {
        self == .landscape ? .portrait : .landscape
    }

    // MARK: 落盘

    private static let storageKey = "opengate.interfaceMode"

    static var saved: InterfaceMode {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let mode = InterfaceMode(rawValue: raw) else {
            // 没存过就是横屏——这是用户明确要求的开机方向。
            return .landscape
        }
        return mode
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
    }
}

/// 拍摄方向，**完全手动**。
///
/// 不读陀螺仪、不订阅设备方向通知。理由有三：
/// 1. 横竖临界点（手机接近 45°）时自动判定会来回抖；
/// 2. `UIDeviceOrientation.landscapeLeft` 与 `AVCaptureVideoOrientation.landscapeRight`
///    左右命名相反，自动映射极易搞反；
/// 3. Home 键在左还是在右，传感器本身分不清方向语义，只有用户知道。
///
/// 所以只暴露横/竖两档，由界面按钮或设置切换，预览与写入共用同一份角度，
/// 不会出现「取景器正了、文件却倒了」。
@MainActor
final class CaptureRotation: ObservableObject {

    /// 顺时针角度。后置相机下 90° 即竖拍正立。
    @Published private(set) var degrees: CGFloat

    init() {
        degrees = InterfaceMode.saved.degrees
    }

    var mode: InterfaceMode {
        (degrees == 90 || degrees == 270) ? .portrait : .landscape
    }

    var isLandscape: Bool { mode == .landscape }

    /// 写入文件元数据与界面提示用
    var label: String { mode.title }

    var target: InterfaceMode { mode.opposite }

    /// 写入 `AVAssetWriterInput.transform` 用。
    /// 只标记显示方向，不旋转像素——全幅尺寸不能被改。
    var transform: CGAffineTransform {
        CGAffineTransform(rotationAngle: degrees * .pi / 180)
    }

    func setMode(_ mode: InterfaceMode) {
        mode.save()
        if degrees != mode.degrees {
            degrees = mode.degrees
        }
    }

    func toggle() {
        setMode(target)
    }
}
