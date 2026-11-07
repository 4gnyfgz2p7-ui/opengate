import SwiftUI
import AVFoundation

/// 取景器。
///
/// 默认 `resizeAspectFill`：拍摄时画面优先撑满屏幕，UI 叠在上面。
/// 全幅不裁切由**成片**保证——`AVAssetWriterInput.transform` 只标记方向、不裁剪像素，
/// 所以取景器放大填满不会影响录到的画面内容；构图以边缘可见为准时，
/// 可在设置里切回 `resizeAspect` 看全幅边界。
struct CameraPreviewView: UIViewRepresentable {

    let session: AVCaptureSession
    /// 顺时针旋转角度，取值来自 `CaptureRotation.degrees`
    let rotationDegrees: CGFloat
    /// true = 铺满（可能裁边，构图更直观）；false = 完整显示全幅
    var fill: Bool = true

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        let gravity: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
        if uiView.previewLayer.videoGravity != gravity {
            uiView.previewLayer.videoGravity = gravity
        }
        applyRotation(to: uiView)
    }

    private func applyRotation(to view: PreviewContainerView) {
        guard let connection = view.previewLayer.connection else { return }
        // 预览层连接在 session 装配完成后才存在，首次调用可能拿不到，
        // 下一次更新会补上
        if connection.isVideoRotationAngleSupported(rotationDegrees) {
            connection.videoRotationAngle = rotationDegrees
        }
    }

    final class PreviewContainerView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            guard let layer = layer as? AVCaptureVideoPreviewLayer else {
                // layerClass 已固定，这里不可能走到；用空层兜底而不是 fatalError，
                // 避免界面在异常情况下直接崩掉
                return AVCaptureVideoPreviewLayer()
            }
            return layer
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

            if let image = image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.low)
                    .aspectRatio(contentMode: .fill)
                    .colorMultiply(accent)
            }

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
