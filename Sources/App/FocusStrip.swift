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

            // 只要选到手动就出滑块。
            // 早先还要求 supportsManualFocus，那条来自
            // isLockingFocusWithCustomLensPositionSupported —— 在 btp2 这类
            // 全幅格式下系统可能返回 false，滑块于是整个不出现，
            // 看起来就是"根本没法手动对焦"。先给出来，能力值已写进诊断。
            if focus.mode == .manual {
                HStack(spacing: 8) {
                    Text("近")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.42))
                        .frame(width: 30, alignment: .leading)

                    // 系统 Slider 自带 ~30pt 的高度，在参数面板里太占地方。
                    // 换自绘的细轨道版本：高度 14pt，宽度撑满（与原来一致），
                    // 拖动逻辑与原来完全相同——拖动中写设备，松手清 draft。
                    CompactSlider(
                        value: Binding(
                            get: { draft ?? focus.sliderPosition },
                            // 拖动过程中就写进设备。对焦是「看着画面找焦点」，
                            // 松手才生效等于盲拖。
                            set: { value in
                                draft = value
                                focus.sliderPosition = value
                            }
                        ),
                        accent: accent,
                        onEditingChanged: { editing in
                            if !editing { draft = nil }
                        }
                    )

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

// MARK: - 细轨道滑块

/// 高度只有 14pt 的滑块，替换系统 `Slider`（后者自带约 30pt）。
///
/// 参数面板在 `ScrollView` 里、高度由布局分区给定，滑块厚一点就多吃一行，
/// 用户直接反馈「滑块占的高度太大」。这里只压高度，**长度沿用原来的撑满**，
/// 拖动阈值、跟手程度与系统版本一致。
///
/// 不用 `.scaleEffect` 压系统控件：那会把文字和拇指一起缩放、
/// 且点击热区仍按原尺寸算，手感会变差。
struct CompactSlider: View {

    @Binding var value: Double
    let accent: Color
    var onEditingChanged: ((Bool) -> Void)?

    /// 轨道粗细与拇指直径。整体高度 = knobSize，比系统少一半以上。
    private let trackHeight: CGFloat = 3
    private let knobSize: CGFloat = 12

    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let travel = max(width - knobSize, 1)
            let clamped = min(max(value, 0), 1)
            let knobX = CGFloat(clamped) * travel

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(height: trackHeight)
                    .padding(.horizontal, knobSize / 2)

                Capsule()
                    .fill(accent)
                    .frame(width: knobX + knobSize / 2, height: trackHeight)
                    .offset(x: 0)

                Circle()
                    .fill(accent)
                    .frame(width: knobSize, height: knobSize)
                    .offset(x: knobX)
            }
            .frame(width: width, height: knobSize, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                // minimumDistance 0：按下即开始调，和系统滑块一致，
                // 否则对焦要拖出一点点距离才响应，手感发涩
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !dragging {
                            dragging = true
                            onEditingChanged?(true)
                        }
                        let position = (gesture.location.x - knobSize / 2) / travel
                        value = min(max(Double(position), 0), 1)
                    }
                    .onEnded { _ in
                        dragging = false
                        onEditingChanged?(false)
                    }
            )
        }
        // 整条高度：拇指直径 + 一点上下余量，便于手指按住
        .frame(height: knobSize + 2)
    }
}
