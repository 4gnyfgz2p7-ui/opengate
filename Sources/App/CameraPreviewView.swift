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
/// 三根参考线分别对应 25% / 50% / 75% 亮度。
struct WaveformView: View {

    let image: CGImage?
    let accent: Color

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
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Text("波形待机")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
            }

            GeometryReader { geometry in
                ForEach([0.25, 0.5, 0.75], id: \.self) { fraction in
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 0.5)
                        .position(
                            x: geometry.size.width / 2,
                            y: geometry.size.height * (1 - fraction)
                        )
                }
            }
            .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        }
    }
}
