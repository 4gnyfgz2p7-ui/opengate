import Foundation
import UIKit
import Combine

/// 拍摄方向，**完全手动**。
///
/// 不读陀螺仪、不订阅设备方向通知。理由有三：
/// 1. 横竖临界点（手机接近 45°）时自动判定会来回抖；
/// 2. `UIDeviceOrientation.landscapeLeft` 与 `AVCaptureVideoOrientation.landscapeRight`
///    左右命名相反，自动映射极易搞反；
/// 3. Home 键在左还是在右，传感器本身分不清方向语义，只有用户知道。
///
/// 所以这里只提供一个循环按钮，按 90 → 0 → 180 → 270 轮转。
/// 预览与写入共用同一份角度，不会出现「取景器正了、文件却倒了」。
@MainActor
final class CaptureRotation: ObservableObject {

    /// 顺时针角度。后置相机下 90° 即竖拍正立。
    static let presets: [CGFloat] = [90, 0, 180, 270]

    @Published private(set) var degrees: CGFloat = 90

    var label: String {
        switch degrees {
        case 90: return "竖拍"
        case 0: return "横拍 A"
        case 180: return "横拍 B"
        case 270: return "竖拍倒置"
        default: return "\(Int(degrees))°"
        }
    }

    var shortLabel: String {
        switch degrees {
        case 90: return "竖"
        case 0: return "横A"
        case 180: return "横B"
        case 270: return "倒"
        default: return "\(Int(degrees))°"
        }
    }

    var isLandscape: Bool {
        degrees == 0 || degrees == 180
    }

    /// 写入 `AVAssetWriterInput.transform` 用。
    /// 只标记显示方向，不旋转像素——全幅尺寸不能被改。
    var transform: CGAffineTransform {
        CGAffineTransform(rotationAngle: degrees * .pi / 180)
    }

    func cycle() {
        let list = Self.presets
        let index = list.firstIndex(of: degrees) ?? 0
        degrees = list[(index + 1) % list.count]
    }

    func reset() {
        degrees = 90
    }
}
