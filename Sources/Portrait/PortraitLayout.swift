import SwiftUI

/// 竖屏版式的几何解算。
///
/// 与横屏同一套约束，只是换了主轴：
/// - 横屏是「取景高度撑满、控件往右排」；
/// - 竖屏是「取景宽度撑满、控件往下排」。
///
/// 三条硬规则在竖屏上的对应：
/// 1. **取景满宽**，高度按 Open Gate 画幅 0.7159 推导；屏幕太矮时才等比缩小，
///    绝不为了塞控件而把画面压扁（压扁会变形，等比缩小只是留黑边）；
/// 2. **全屏只有一条拖拽条**，横放在控件区，跟着选中的参数走；
/// 3. **镜头切换不压在画面上**，单独占一行。
///
/// 与 `_design/render_layout.py` 用的是同一组数字，改动必须两边同步。
struct PortraitLayout {

    static let margin: CGFloat = 12
    static let knobMax: CGFloat = 56
    static let knobGap: CGFloat = 8
    static let lensSize: CGFloat = 44
    static let lensGap: CGFloat = 8
    static let lensSlots: CGFloat = 4
    static let orientationSize: CGFloat = 30
    static let gearSize: CGFloat = 38
    static let barHeight: CGFloat = 56
    static let recordSize: CGFloat = 72
    /// Open Gate 在竖屏下的画幅：3024 / 4224
    static let aspect: CGFloat = 3024.0 / 4224.0
    let preview: CGRect
    let lensRow: CGRect
    let knobRow: CGRect
    let bar: CGRect
    let record: CGRect
    let chipsOrigin: CGPoint
    let knobSize: CGFloat

    /// 圆钮直径随屏宽收缩：六颗钮加五道缝必须塞得进一行。
    static func knobDiameter(for width: CGFloat) -> CGFloat {
        let usable = width - margin * 2 - knobGap * 5
        return min(knobMax, max(40, usable / 6))
    }

    init(size: CGSize, insets: EdgeInsets) {
        let knob = Self.knobDiameter(for: size.width)
        knobSize = knob

        let controlHeight = Self.lensSize + 10 + knob + 12 + Self.barHeight + 16 + Self.recordSize
        let usableBottom = size.height - insets.bottom

        // ---- 取景：满宽，高度按画幅；塞不下控件时等比缩小 ----
        var previewHeight = size.width / Self.aspect
        if previewHeight + controlHeight + 12 > usableBottom {
            previewHeight = max(0, usableBottom - controlHeight - 12)
        }
        let previewWidth = min(size.width, previewHeight * Self.aspect)
        preview = CGRect(
            x: (size.width - previewWidth) / 2,
            y: 0,
            width: previewWidth,
            height: previewHeight
        )

        // ---- 控件块：在画面与底部安全区之间居中留白 ----
        let free = max(0, usableBottom - preview.maxY - controlHeight)
        let gap = min(max(10, free / 2), 34)
        var y = preview.maxY + gap

        // 一行放：焦距 ×4 + 横竖切换 + 设置。后两颗刻意小一档，
        // 与 44pt 的镜头钮拉开层级——切镜头那侧的小按钮，不抢视线。
        let lensRowWidth = Self.lensSize * Self.lensSlots
            + Self.lensGap * (Self.lensSlots - 1)
            + Self.lensGap + Self.orientationSize
            + Self.lensGap + Self.gearSize
        lensRow = CGRect(
            x: (size.width - lensRowWidth) / 2,
            y: y,
            width: lensRowWidth,
            height: Self.lensSize
        )
        y = lensRow.maxY + 10

        // ---- 参数钮：五颗 + A，居中一行 ----
        let knobRowWidth = knob * 6 + Self.knobGap * 5
        knobRow = CGRect(
            x: (size.width - knobRowWidth) / 2,
            y: y,
            width: knobRowWidth,
            height: knob
        )
        y = knobRow.maxY + 12

        // ---- 拖拽条：横放，全屏唯一一条 ----
        bar = CGRect(
            x: insets.leading + Self.margin,
            y: y,
            width: size.width - insets.leading - insets.trailing - Self.margin * 2,
            height: Self.barHeight
        )
        y = bar.maxY + 16

        // ---- 录制键：底部居中，拇指自然落点 ----
        record = CGRect(
            x: (size.width - Self.recordSize) / 2,
            y: y,
            width: Self.recordSize,
            height: Self.recordSize
        )

        // 状态读数放在镜头行左侧的空白里：与镜头同一水平，不在画面上。
        // 两行窄文本约 26pt 高，垂直居中在这条 44pt 的行里。
        chipsOrigin = CGPoint(x: insets.leading + Self.margin, y: lensRow.midY - 13)
    }
}
