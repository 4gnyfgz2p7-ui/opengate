import SwiftUI

/// 对焦条：一行模式 + 手动时出滑块。
///
/// 只有手动档才需要常驻滑块——自动档没有可拖的量。所以默认只占一行，
/// 选「手动」之后才展开，避免和曝光、白平衡抢垂直空间。
///
/// 滑块刻度就是焦距本身：0 = 无限远，1 = 最近。`lensPosition` 的单位是
/// 屈光度（1/米），天然是"近处变化快、远处变化慢"的物理刻度，不再二次映射。
struct FocusStrip: View {

    @ObservedObject var focus: FocusController
    let accent: Color

    @State private var draft: Double?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text("对焦")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(width: 30, alignment: .leading)

                ForEach(FocusController.Mode.allCases) { mode in
                    chip(mode)
                }

                Spacer(minLength: 0)

                Text(readout)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            if focus.mode == .manual && focus.supportsManualFocus {
                HStack(spacing: 8) {
                    Text("∞")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.42))
                        .frame(width: 30, alignment: .leading)

                    Slider(
                        value: Binding(
                            get: { draft ?? focus.sliderPosition },
                            set: { draft = $0 }
                        ),
                        in: 0...1,
                        onEditingChanged: { editing in
                            guard !editing, let value = draft else { return }
                            focus.sliderPosition = value
                            draft = nil
                        }
                    )
                    .tint(accent)

                    Text("近")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.42))
                        .frame(width: 18, alignment: .trailing)
                }
            }
        }
    }

    /// 只在手动档显示距离。
    ///
    /// 自动对焦期间 `lensPosition` 由系统按场景反推，不是镜头的确定位置，
    /// 拿它当读数会让人以为"对上了但实际没有"。手动档的位置是用户给的，才可信。
    private var readout: String {
        guard focus.mode == .manual else { return "" }
        guard focus.supportsManualFocus else { return "锁定" }
        return focus.distanceText(Float(draft ?? focus.sliderPosition))
    }

    private func chip(_ mode: FocusController.Mode) -> some View {
        let selected = focus.mode == mode
        return Button {
            focus.mode = mode
            draft = nil
        } label: {
            Text(mode.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? accent : Color.white.opacity(0.07))
                )
        }
        .buttonStyle(.plain)
    }
}
