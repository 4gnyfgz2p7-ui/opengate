import SwiftUI
import AVFoundation

/// 取景器。
///
/// 固定 `resizeAspect`：画面按比例贴合屏幕短边，宽或高总有一边撑满，
/// 多出来的部分留黑，**不裁切任何像素**。
/// 这样取景框里看到的就是最终成片的全部内容，构图不会在录制后才多出东西。
struct CameraPreviewView: UIViewRepresentable {

    let session: AVCaptureSession
    /// 顺时针旋转角度，取值来自 `CaptureRotation.degrees`
    let rotationDegrees: CGFloat

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspect
        view.requestedRotation = rotationDegrees
        view.attach(session: session)
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.requestedRotation = rotationDegrees
        uiView.attach(session: session)
        uiView.applyRotationIfPossible()
    }

    /// 预览容器。
    ///
    /// 黑屏的根因就在这里：预览图层一旦离开窗口再回来（切横竖、换布局分支、
    /// 从后台回前台），视频连接会失效，但 `session` 属性还挂着，
    /// `AVCaptureVideoPreviewLayer` 自己不会重建连接——画面就这么黑着，
    /// 而采集会话其实还在正常跑（所以开关指示灯仍是绿的）。
    /// 修法是在重新入窗和每次布局时把 session 再挂一次，并补回旋转角。
    final class PreviewContainerView: UIView {

        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var requestedRotation: CGFloat = 90

        private weak var attachedSession: AVCaptureSession?

        var previewLayer: AVCaptureVideoPreviewLayer {
            // layerClass 已固定，这里必定成立
            layer as! AVCaptureVideoPreviewLayer
        }

        func attach(session: AVCaptureSession) {
            guard previewLayer.session !== session else { return }
            previewLayer.session = session
            attachedSession = session
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // 重新入窗：把 session 再挂一次，强制重建视频连接
            if let session = attachedSession ?? previewLayer.session {
                previewLayer.session = session
                attachedSession = session
            }
            applyRotationIfPossible()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if previewLayer.frame != bounds {
                previewLayer.frame = bounds
            }
            applyRotationIfPossible()
        }

        func applyRotationIfPossible() {
            guard let connection = previewLayer.connection else { return }
            // 连接在 session 装配完成后才存在，首次可能拿不到，
            // 下一次 layout 会补上
            if connection.isVideoRotationAngleSupported(requestedRotation) {
                connection.videoRotationAngle = requestedRotation
            }
        }
    }
}

/// 波形示波器。
///
/// 横轴对应画面从左到右，纵轴是亮度（底 0、顶 100）。
///
/// 这里唯一的判读用途是**曝光**，所以顶和底不是普通参考线：
/// - 登顶 = 该列有像素落到编码范围上限，信号已被削平，后期救不回
/// - 触底 = 该列有像素落到 0，暗部已被压死，同样救不回
/// - 没登顶也没触底 = 高光与暗部都还在范围内，正常
///
/// 这个口径与色彩管线无关：换到 Apple Log 2 后，顶依然是"撞到天花板"那一格，
/// 只是 log 把更多高光压进了范围内，登顶会更晚发生。
struct WaveformView: View {

    let image: CGImage?
    let accent: Color
    var reading: WaveformSampler.Reading = .empty

    private var topClipped: Bool { reading.isHighlightClipped }
    private var bottomClipped: Bool { reading.isShadowClipped }

    private var statusText: String {
        switch (topClipped, bottomClipped) {
        case (true, true): return "过曝 · 死黑"
        case (true, false): return "过曝"
        case (false, true): return "死黑"
        case (false, false): return "正常"
        }
    }

    private var statusColor: Color {
        if topClipped { return Color.red }
        if bottomClipped { return Color(red: 0.45, green: 0.68, blue: 1.0) }
        return Color(red: 0.45, green: 0.85, blue: 0.6)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.6))

            // 波形图本身是 48×96 的竖图，直接放进 ZStack 会按图片比例撑开
            // （104 宽 → 208 高的长条），跑出 40pt 的框、压住状态栏和取景。
            // 用 Color 占位、图片只做 overlay，再裁掉溢出部分。
            Color.clear
                .overlay(
                    Group {
                        if let image = image {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .interpolation(.low)
                                .aspectRatio(contentMode: .fill)
                                .colorMultiply(accent)
                        }
                    }
                )
                .clipped()

            GeometryReader { geometry in
                ForEach([0.25, 0.5, 0.75], id: \.self) { fraction in
                    Rectangle()
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 0.5)
                        .position(
                            x: geometry.size.width / 2,
                            y: geometry.size.height * (1 - fraction)
                        )
                }

                Rectangle()
                    .fill(topClipped ? Color.red : Color.white.opacity(0.20))
                    .frame(height: topClipped ? 2 : 1)
                    .position(x: geometry.size.width / 2, y: 1.5)

                Rectangle()
                    .fill(bottomClipped ? Color(red: 0.45, green: 0.68, blue: 1.0) : Color.white.opacity(0.20))
                    .frame(height: bottomClipped ? 2 : 1)
                    .position(x: geometry.size.width / 2, y: geometry.size.height - 1.5)
            }
            .allowsHitTesting(false)

            VStack {
                HStack {
                    Text(statusText)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
    }
}
