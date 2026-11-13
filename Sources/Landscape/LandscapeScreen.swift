import SwiftUI

/// 横屏主界面（顺时针 90°）。
///
/// 版式全部由 `LandscapeLayout` 解算，这里只负责摆放与绑定，不写死坐标。
/// 交互与采集的耦合压到最低：只读 `RecordingEngine` 的公开属性，
/// 只调它的公开方法，不碰 `Sources/Capture` 内部状态。
///
/// 参数面板的行为（选中 / 自动 / 拖拽映射）与竖屏共用 `CameraDeck`，
/// 这里只决定画成什么形状——两份界面各写一套逻辑，迟早会漂。
struct LandscapeScreen: View {

    @ObservedObject var engine: RecordingEngine
    /// 顶部小弹窗文案（录制失败、自动停止等）
    let banner: String?
    /// 窗口安全区，由外层按 `UIWindowScene` 传入
    let insets: EdgeInsets
    var onSettings: () -> Void

    @State private var deck = CameraDeck()

    var body: some View {
        GeometryReader { geo in
            let layout = LandscapeLayout(size: geo.size, insets: insets)

            ZStack(alignment: .topLeading) {
                Color.black

                previewPane(layout)
                lensRail(layout)
                orientationButton(layout)
                parameterRail(layout)
                sideBar(layout)
                recordOrb(layout)
                settingsOrb(layout)
                chipsRow(layout)

                if let banner {
                    Text(banner)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .liquidGlass(Capsule(), tint: .white.opacity(0.16), interactive: false)
                        .frame(maxWidth: layout.preview.width * 0.8)
                        .position(x: layout.preview.midX, y: layout.preview.minY + 72)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.16), value: banner)
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
    }

    // MARK: - 取景

    private func previewPane(_ layout: LandscapeLayout) -> some View {
        CameraPreviewView(
            session: engine.capture.session,
            rotationDegrees: engine.rotationDegrees
        )
        .frame(width: layout.preview.width, height: layout.preview.height)
        .position(x: layout.preview.midX, y: layout.preview.midY)
    }

    // MARK: - 焦距（镜头）轨

    private func lensRail(_ layout: LandscapeLayout) -> some View {
        // 相邻玻璃圆钮放进同一个容器，让它们在靠近时按系统规则彼此融合，
        // 而不是各自独立的一层模糊。
        GlassEffectContainer(spacing: LandscapeLayout.lensGap) {
            VStack(spacing: LandscapeLayout.lensGap) {
                ForEach(engine.lenses) { lens in
                    CameraLensButton(
                        label: lens.label,
                        isActive: lens.id == engine.activeLensID,
                        isAvailable: !engine.state.isBusy,
                        size: LandscapeLayout.lensSize
                    ) {
                        engine.selectLens(lens)
                    }
                }
            }
        }
        // 居中而不是顶部对齐：只有三个镜头时（系统不报 8×）不会一堆挤在上边
        .frame(width: layout.lensRail.width, height: layout.lensRail.height)
        .position(x: layout.lensRail.midX, y: layout.lensRail.midY)
    }

    /// 横竖切换：镜头列里、齿轮上方，比 44pt 的镜头钮小一档
    private func orientationButton(_ layout: LandscapeLayout) -> some View {
        CameraOrientationButton(
            size: LandscapeLayout.orientationSize,
            targetTitle: engine.rotation.target.title
        ) {
            engine.toggleInterfaceMode()
        }
        .position(x: layout.orientation.midX, y: layout.orientation.midY)
    }

    // MARK: - 参数轨

    private func parameterRail(_ layout: LandscapeLayout) -> some View {
        GlassEffectContainer(spacing: LandscapeLayout.knobGap) {
            VStack(spacing: LandscapeLayout.knobGap) {
                ForEach(CameraParameter.allCases) { parameter in
                    CameraKnob(
                        title: parameter.title,
                        value: deck.knobValue(parameter, engine),
                        detail: deck.isAuto(parameter, engine) ? "AUTO" : "手动",
                        isAuto: deck.isAuto(parameter, engine),
                        isSelected: deck.selection == parameter,
                        size: LandscapeLayout.knobSize
                    ) {
                        deck.tap(parameter, engine)
                    }
                }

                CameraAutoKnob(
                    size: LandscapeLayout.knobSize,
                    isEnabled: !deck.isAuto(deck.selection, engine)
                ) {
                    deck.setAuto(deck.selection, engine)
                }
            }
        }
        .frame(width: layout.rail.width, height: layout.rail.height, alignment: .top)
        .position(x: layout.rail.midX, y: layout.rail.midY)
    }

    // MARK: - 拖拽条：全屏唯一一条，贴最右边

    /// 竖向拖拽条。
    ///
    /// SwiftUI 没有原生竖向滑块，这里用系统 `Slider` 旋转 -90° 实现：
    /// 交互、惯性与无障碍全部是系统的，只是摆成竖的。
    /// 旋转不改变布局尺寸，所以必须外套一个显式 frame，否则会溢出胶囊。
    private func sideBar(_ layout: LandscapeLayout) -> some View {
        VStack(spacing: 6) {
            Text(deck.selection.title)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)

            // 长度跟着条高走——条撑满屏幕高度，滑块就跟着变长。
            Slider(value: sliderBinding, in: 0...1)
                .tint(.white)
                .frame(width: sideBarTrackLength(layout))
                .rotationEffect(.degrees(-90))
                .frame(width: 30, height: sideBarTrackLength(layout))
                .disabled(deck.isAuto(deck.selection, engine))
                .opacity(deck.isAuto(deck.selection, engine) ? 0.4 : 1)

            Text(deck.readout(deck.selection, engine))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.vertical, 14)
        .frame(width: layout.bar.width, height: layout.bar.height)
        .liquidGlass(Capsule(), tint: .white.opacity(0.10))
        .position(x: layout.bar.midX, y: layout.bar.midY)
    }

    // MARK: - 录制键 / 设置

    private func recordOrb(_ layout: LandscapeLayout) -> some View {
        CameraRecordOrb(
            size: layout.record.width,
            isRecording: engine.state == .recording,
            isBusy: !engine.state.canStart && engine.state != .recording
        ) {
            if engine.state == .recording {
                engine.stopRecording()
            } else {
                engine.startRecording()
            }
        }
        .position(x: layout.record.midX, y: layout.record.midY)
    }

    private func settingsOrb(_ layout: LandscapeLayout) -> some View {
        Button(action: onSettings) {
            Image(systemName: "gearshape")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: layout.gear.width, height: layout.gear.height)
                .contentShape(Circle())
                .liquidGlass(Circle(), tint: .white.opacity(0.10))
        }
        .buttonStyle(.plain)
        .position(x: layout.gear.midX, y: layout.gear.midY)
    }

    /// 状态读数：左列顶部，不在画面上
    private func chipsRow(_ layout: LandscapeLayout) -> some View {
        CameraStatusStack(
            timecode: engine.state == .recording ? CameraFormat.timecode(engine.elapsed) : nil,
            remaining: CameraFormat.duration(engine.remainingSeconds)
        )
        .padding(.leading, layout.chipsOrigin.x)
        .padding(.top, layout.chipsOrigin.y)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 拖拽条取值

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { deck.position(deck.selection, engine) },
            set: { deck.apply(deck.selection, position: $0, engine) }
        )
    }

    /// 竖向滑块的长度：条内减去标签、读数与上下留白。
    private func sideBarTrackLength(_ layout: LandscapeLayout) -> CGFloat {
        max(120, layout.bar.height - 96)
    }
}
