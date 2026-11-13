import SwiftUI

/// 横屏右侧参数轨。
///
/// 五个参数各自一个圆钮，自动时是系统液态玻璃的黄色着色，手动时是默认白色玻璃，
/// 选中会加深一档。**整条轨共用一个“A”钮与一条拖拽条**，不给每个参数各配一条，
/// 理由很实际：横屏高度只有 440pt，六条滑块谁也够不着。
enum LandscapeParameter: String, CaseIterable, Identifiable {
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

// MARK: - 系统液态玻璃

/// 全 App 唯一调用系统液态玻璃的地方。
///
/// 不自己画模糊、渐变、高光——那些是 `glassEffect` 的职责。收在一处的好处是
/// 系统 API 调整时只改这一行，不会散落到十几个视图里各写一套。
extension View {
    func liquidGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = true) -> some View {
        glassEffect(
            interactive ? .regular.tint(tint).interactive() : .regular.tint(tint),
            in: shape
        )
    }
}

/// 参数圆钮。
struct LandscapeKnob: View {

    let title: String
    let value: String
    let detail: String
    let isAuto: Bool
    let isSelected: Bool
    let action: () -> Void

    private var tint: Color? {
        if isAuto { return .yellow }
        return .white.opacity(isSelected ? 0.28 : 0.08)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(value)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                Text(detail)
                    .font(.system(size: 7.5, weight: .medium))
                    .lineLimit(1)
                Text(title)
                    .font(.system(size: 7))
                    .lineLimit(1)
                    .opacity(0.6)
            }
            // 黄色玻璃上必须是深色字，否则对比度不足
            .foregroundStyle(isAuto ? Color.black.opacity(0.86) : Color.white)
            .frame(width: LandscapeLayout.knobSize, height: LandscapeLayout.knobSize)
            .liquidGlass(Circle(), tint: tint)
            .overlay {
                if isSelected {
                    Circle().strokeBorder(Color.white.opacity(isAuto ? 0.55 : 0.75), lineWidth: 1.2)
                }
            }
            .scaleEffect(isSelected ? 1.05 : 1)
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.18), value: isSelected)
    }
}

/// 焦距（镜头）圆钮。比参数钮小一档，靠画面左侧单独成列。
struct LandscapeLensButton: View {

    let label: String
    let isActive: Bool
    let isAvailable: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(isAvailable ? Color.white : Color.white.opacity(0.38))
                .frame(width: LandscapeLayout.lensSize, height: LandscapeLayout.lensSize)
                .liquidGlass(
                    Circle(),
                    tint: isActive ? .white.opacity(0.34) : .white.opacity(0.04)
                )
                .overlay {
                    if isActive {
                        Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 1.2)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
    }
}
