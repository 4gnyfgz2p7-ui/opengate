import SwiftUI

// MARK: - 系统液态玻璃

/// 全 App 唯一调用系统液态玻璃的地方。
///
/// 不自己画模糊、渐变、高光——那些是 `glassEffect` 的职责。
/// 收在一处的好处是系统 API 调整时只改这一行，不会散落到十几个视图里各写一套。
extension View {
    func liquidGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = true) -> some View {
        glassEffect(
            interactive ? .regular.tint(tint).interactive() : .regular.tint(tint),
            in: shape
        )
    }
}

// MARK: - 参数圆钮

/// 参数圆钮：大字是实时值，中间一行自动/手动，底部是参数名。
///
/// 自动＝黄色玻璃 + 深色字，手动＝默认白玻璃；选中会加深一档并描一圈边。
/// 横竖屏共用，`size` 由各自的版式给。
struct CameraKnob: View {

    let title: String
    let value: String
    let detail: String
    let isAuto: Bool
    let isSelected: Bool
    let size: CGFloat
    let action: () -> Void

    private var tint: Color? {
        if isAuto { return .yellow }
        return .white.opacity(isSelected ? 0.28 : 0.08)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(value)
                    .font(.system(size: size * 0.24, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                Text(detail)
                    .font(.system(size: size * 0.134, weight: .medium))
                    .lineLimit(1)
                Text(title)
                    .font(.system(size: size * 0.125))
                    .lineLimit(1)
                    .opacity(0.6)
            }
            // 黄色玻璃上必须是深色字，否则对比度不足
            .foregroundStyle(isAuto ? Color.black.opacity(0.86) : Color.white)
            .frame(width: size, height: size)
            // 命中区必须显式给成整颗圆：命中测试默认走渲染内容，
            // 只有文字大小的话，手指落在圆边会打空。
            .contentShape(Circle())
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

/// 「A」钮：把当前选中的参数交还系统。
struct CameraAutoKnob: View {

    let size: CGFloat
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text("A")
                    .font(.system(size: size * 0.32, weight: .semibold))
                Text("自动")
                    .font(.system(size: size * 0.125))
                    .opacity(0.7)
            }
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .liquidGlass(Circle(), tint: .white.opacity(0.14))
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

// MARK: - 焦距（镜头）圆钮

/// 焦距圆钮。比参数钮小一档，横屏靠在画面左侧、竖屏排在画面下方。
struct CameraLensButton: View {

    let label: String
    let isActive: Bool
    let isAvailable: Bool
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: size * 0.25, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(isAvailable ? Color.white : Color.white.opacity(0.38))
                .frame(width: size, height: size)
                .contentShape(Circle())
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

// MARK: - 录制键

/// 录制键：外圈一块极淡的玻璃，里面是红点（录制中变成白色方块）。
/// 玻璃压到 0.03 是为了压在画面上时不挡构图。
struct CameraRecordOrb: View {

    let size: CGFloat
    let isRecording: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: isRecording ? size * 0.09 : size / 2, style: .continuous)
                .fill(isRecording ? Color.white : Color.red)
                .frame(
                    width: size * (isRecording ? 0.34 : 0.4),
                    height: size * (isRecording ? 0.34 : 0.4)
                )
                .frame(width: size, height: size)
                .contentShape(Circle())
                .liquidGlass(Circle(), tint: .white.opacity(0.03))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy ? 0.45 : 1)
    }
}

// MARK: - 横竖切换

/// 横竖屏切换。刻意做小一档（30pt）：它是低频操作，
/// 尺寸上必须和 44pt 的镜头钮、56pt 的参数钮拉开层级，不抢视线。
struct CameraOrientationButton: View {

    let size: CGFloat
    /// 点下去会切到哪一边，给无障碍读屏用
    let targetTitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: size, height: size)
                .contentShape(Circle())
                .liquidGlass(Circle(), tint: .white.opacity(0.10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("切到\(targetTitle)")
    }
}

// MARK: - 状态读数

/// 录制时间与剩余时长。
///
/// 刻意做成两行窄文本、不加胶囊：横屏时它要挤在 44pt 宽的镜头列里，
/// 竖屏时要塞进镜头行左侧的缝里。加内边距就放不下了，而这两项是信息不是控件，
/// 压在纯黑底上本来就清楚——不用为了玻璃感去牺牲版式。
struct CameraStatusStack: View {

    /// 录制中才有时间码
    let timecode: String?
    let remaining: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let timecode {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 4, height: 4)
                    Text(timecode)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                }
            }
            Text("剩 \(remaining)")
                .font(.system(size: 8, design: .monospaced))
                .opacity(0.72)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
        .lineLimit(1)
        .fixedSize()
    }
}
