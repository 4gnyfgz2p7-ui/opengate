import SwiftUI

/// 竖屏主界面。
///
/// 与横屏是同一套语言、同一份参数逻辑，只是主轴换成纵向：
/// 取景满宽 → 镜头一行 → 参数钮一行（含 A） → 唯一一条横向拖拽条 → 录制键。
///
/// 采集侧一律不碰：只读 `RecordingEngine` 的公开属性、只调公开方法。
/// `tools/check_ui_isolation.sh` 是这条边界的构建门禁。
struct PortraitScreen: View {

    @ObservedObject var engine: RecordingEngine
    /// 顶部小弹窗文案（录制失败、自动停止等）
    let banner: String?
    /// 窗口安全区，由外层按 `UIWindowScene` 传入
    let insets: EdgeInsets
    var onSettings: () -> Void

    /// 选中/自动/拖拽的行为与横屏共用一份，版式各画各的。
    @State private var deck = CameraDeck()

    var body: some View {
        GeometryReader { geo in
            let layout = PortraitLayout(size: geo.size, insets: insets)

            ZStack(alignment: .topLeading) {
                Color.black

                previewPane(layout)
                lensRow(layout)
                knobRow(layout)
                sideBar(layout)
                recordOrb(layout)
                chipsRow(layout)

                if let banner {
                    Text(banner)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .liquidGlass(Capsule(), tint: .white.opacity(0.16), interactive: false)
                        .frame(maxWidth: geo.size.width * 0.82)
                        .position(x: geo.size.width / 2, y: layout.preview.maxY * 0.4)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.16), value: banner)
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
    }

    // MARK: - 取景

    private func previewPane(_ layout: PortraitLayout) -> some View {
        CameraPreviewView(
            session: engine.capture.session,
            rotationDegrees: engine.rotationDegrees
        )
        .frame(width: layout.preview.width, height: layout.preview.height)
        .position(x: layout.preview.midX, y: layout.preview.midY)
    }

    // MARK: - 焦距（镜头）行

    private func lensRow(_ layout: PortraitLayout) -> some View {
        // 相邻玻璃圆钮放进同一个容器，让它们在靠近时按系统规则彼此融合。
        GlassEffectContainer(spacing: PortraitLayout.lensGap) {
            HStack(spacing: PortraitLayout.lensGap) {
                ForEach(engine.lenses) { lens in
                    CameraLensButton(
                        label: lens.label,
                        isActive: lens.id == engine.activeLensID,
                        isAvailable: !engine.state.isBusy,
                        size: PortraitLayout.lensSize
                    ) {
                        engine.selectLens(lens)
                    }
                }

                // 横竖切换：与镜头同一行、同一侧，尺寸小一档
                CameraOrientationButton(
                    size: PortraitLayout.orientationSize,
                    targetTitle: engine.rotation.target.title
                ) {
                    engine.toggleInterfaceMode()
                }

                // 设置：仍在这条行尾，不压画面
                settingsOrb(size: PortraitLayout.gearSize)
            }
            // 只有三颗时也居中在四颗的槽位里，不会偏到一边
            .frame(width: layout.lensRow.width, height: layout.lensRow.height)
        }
        .position(x: layout.lensRow.midX, y: layout.lensRow.midY)
    }

    // MARK: - 参数行

    private func knobRow(_ layout: PortraitLayout) -> some View {
        GlassEffectContainer(spacing: PortraitLayout.knobGap) {
            HStack(spacing: PortraitLayout.knobGap) {
                ForEach(CameraParameter.allCases) { parameter in
                    CameraKnob(
                        title: parameter.title,
                        value: deck.knobValue(parameter, engine),
                        detail: deck.isAuto(parameter, engine) ? "AUTO" : "手动",
                        isAuto: deck.isAuto(parameter, engine),
                        isSelected: deck.selection == parameter,
                        size: layout.knobSize
                    ) {
                        deck.tap(parameter, engine)
                    }
                }

                CameraAutoKnob(
                    size: layout.knobSize,
                    isEnabled: !deck.isAuto(deck.selection, engine)
                ) {
                    deck.setAuto(deck.selection, engine)
                }
            }
            .frame(width: layout.knobRow.width, height: layout.knobRow.height)
        }
        .position(x: layout.knobRow.midX, y: layout.knobRow.midY)
    }

    // MARK: - 拖拽条：全屏唯一一条，横放

    private func sideBar(_ layout: PortraitLayout) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 8) {
                Text(deck.selection.title)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(deck.readout(deck.selection, engine))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Slider(value: sliderBinding, in: 0...1)
                .tint(.white)
                .disabled(deck.isAuto(deck.selection, engine))
                .opacity(deck.isAuto(deck.selection, engine) ? 0.4 : 1)
        }
        .padding(.horizontal, 16)
        .frame(width: layout.bar.width, height: layout.bar.height)
        .liquidGlass(Capsule(), tint: .white.opacity(0.10))
        .position(x: layout.bar.midX, y: layout.bar.midY)
    }

    // MARK: - 录制键 / 设置

    private func recordOrb(_ layout: PortraitLayout) -> some View {
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

    private func settingsOrb(size: CGFloat) -> some View {
        Button(action: onSettings) {
            Image(systemName: "gearshape")
                .font(.system(size: size * 0.39, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .contentShape(Circle())
                .liquidGlass(Circle(), tint: .white.opacity(0.10))
        }
        .buttonStyle(.plain)
    }

    /// 状态读数：镜头行左侧，不在画面上
    private func chipsRow(_ layout: PortraitLayout) -> some View {
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
}
