import SwiftUI
import AVFoundation

/// 取景器。
///
/// `videoGravity = .resizeAspect` 而不是 `.resizeAspectFill`：
/// 本项目硬约束是「全幅不裁切」，取景器若做 fill，构图边缘会被藏掉，
/// 拍完才发现画面里多了东西。宁可留黑边。
struct CameraPreviewView: UIViewRepresentable {

    let session: AVCaptureSession
    /// 顺时针旋转角度，取值来自 `CaptureRotation.degrees`
    let rotationDegrees: CGFloat

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
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
