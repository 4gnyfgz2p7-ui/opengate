import SwiftUI

/// 对焦条：一行模式 + 手动时出滑块。
///
/// 只有手动档才需要常驻滑块——自动档没有可拖的量。所以默认只占一行，
/// 选「手动」之后才展开，避免和曝光、白平衡抢垂直空间。
///
/// 滑块刻度就是焦距本身：左端「近」、右端「∞」。按 Apple 文档，
/// `lensPosition` 的 **0.0 是最近、1.0 是最远**（1.0 不等于严格无限远），
/// 且不对应确定的物理距离，所以读数只给位置值，不换算成米。
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
                    .frame(width: 34, alignment: .trailing)
            }

            if focus.mode == .manual && focus.supportsManualFocus {
                HStack(spacing: 8) {
                    Text("近")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.42))
                        .frame(width: 30, alignment: .leading)

                    Slider(
                        value: Binding(
                            get: { draft ?? focus.sliderPosition },
                            // 拖动过程中就写进设备。对焦是「看着画面找焦点」，
                            // 松手才生效等于盲拖——曝光条那样延后提交在这一档行不通。
                            set: { value in
                                draft = value
                                focus.sliderPosition = value
                            }
                        ),
                        in: 0...1,
                        onEditingChanged: { editing in
                            if !editing { draft = nil }
                        }
                    )
                    .tint(accent)

                    Text("∞")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.42))
                        .frame(width: 18, alignment: .trailing)
                }
            }
        }
    }

    /// 手动档显示目标位置；自动档显示**实时**位置。
    ///
    /// 自动档这串数字会随场景跳动，这本身就是"AF 在不在工作"的证据——
    /// 一直不动就是没在对焦，比任何提示都直接。
    private var readout: String {
        switch focus.mode {
        case .manual:
            guard focus.supportsManualFocus else { return "锁定" }
            return focus.positionText(Float(draft ?? focus.sliderPosition))
        case .continuous:
            return focus.positionText(focus.liveLensPosition)
        }
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
