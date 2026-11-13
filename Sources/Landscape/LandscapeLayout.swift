import SwiftUI

/// 横屏版式的几何解算。
///
/// 单独成文件、只依赖 `CGSize` 与安全区，不引用任何采集类型：
/// 版式改数字不会碰到拍摄逻辑，拍摄改逻辑也不会挪动版式。
///
/// 三条硬约束（来自实机要求，不是审美选择）：
///
/// 1. **取景高度撑满整屏**，宽度按 Open Gate 画幅 1.397 推导，
///    绝不为了给控件腾地方而缩高度；
/// 2. **拖拽条贴最右边**，竖向，全屏只有这一条，跟着选中的参数走；
/// 3. **画面左侧要给焦距切换留出整列空间**，镜头钮不压在画面上。
///
/// 约束顺序决定了其余位置：先留左列 → 取景撑满高度 → 条贴右 → 参数列贴条。
/// 录制键因此只能浮在画面右下角：左列被镜头占用、右侧被参数列与竖条占满，
/// 硬要再挤一列就得缩取景高度，与第 1 条冲突。
/// 与 `_design/render_layout.py` 用的是同一组数字，改动必须两边同步。
struct LandscapeLayout {

    static let margin: CGFloat = 8
    static let knobSize: CGFloat = 56
    static let knobGap: CGFloat = 8
    static let lensSize: CGFloat = 44
    static let lensGap: CGFloat = 8
    static let barWidth: CGFloat = 52
    static let recordSize: CGFloat = 56
    static let gearSize: CGFloat = 38
    static let gap: CGFloat = 12
    /// 焦距列与画面之间的缝。压到 6 让画面再往左一点，同时不贴到镜头钮。
    static let lensGapToPreview: CGFloat = 6
    /// Open Gate 画幅：4224 / 3024
    static let aspect: CGFloat = 4224.0 / 3024.0
    /// 控件区至少要留出的宽度占比。取景按画幅撑满高度后若把右侧挤没，
    /// 才退而在宽度上让步——正常机器（956×440）远远用不到这条。
    static let previewMaxWidthRatio: CGFloat = 0.78

    let preview: CGRect
    let lensRail: CGRect
    let rail: CGRect
    let bar: CGRect
    let record: CGRect
    let gear: CGRect
    let chipsOrigin: CGPoint

    init(size: CGSize, insets: EdgeInsets) {
        // ---- 焦距列：先占位，画面从它右侧开始 ----
        let lensHeight = Self.lensSize * 4 + Self.lensGap * 3
        lensRail = CGRect(
            x: insets.leading + Self.margin,
            y: (size.height - lensHeight) / 2,
            width: Self.lensSize,
            height: lensHeight
        )
        gear = CGRect(
            x: lensRail.minX,
            y: size.height - insets.bottom - Self.margin - Self.gearSize,
            width: Self.gearSize,
            height: Self.gearSize
        )

        // ---- 取景：高度撑满，左侧让开焦距列 ----
        var height = size.height
        var width = height * Self.aspect
        let maxWidth = size.width * Self.previewMaxWidthRatio
        if width > maxWidth {
            width = maxWidth
            height = width / Self.aspect
        }
        let previewX = lensRail.maxX + Self.lensGapToPreview
        preview = CGRect(x: previewX, y: 0, width: width, height: height)

        // ---- 拖拽条：贴最右，纵向撑满可用高度 ----
        // 只有一条，就把它做长：竖向空间越多，同一像素对应越细的调整量。
        let barX = size.width - insets.trailing - Self.margin - Self.barWidth
        let barY = insets.top + Self.margin
        let barHeight = max(160, size.height - insets.top - insets.bottom - Self.margin * 2)
        bar = CGRect(x: barX, y: barY, width: Self.barWidth, height: barHeight)

        // ---- 参数列：贴条的左侧 ----
        let knobX = barX - Self.gap - Self.knobSize
        let columnHeight = Self.knobSize * 6 + Self.knobGap * 5
        rail = CGRect(
            x: knobX,
            y: (size.height - columnHeight) / 2,
            width: Self.knobSize,
            height: columnHeight
        )

        // ---- 录制键：画面右下角 ----
        // 左列给了镜头、右侧给了参数列与竖条，再挤一列就得缩取景高度，
        // 那与「高度撑满」直接冲突。放到画面右下角是唯一不违背约束的位置。
        record = CGRect(
            x: preview.maxX - Self.margin * 2 - Self.recordSize,
            y: size.height - insets.bottom - Self.margin - Self.recordSize,
            width: Self.recordSize,
            height: Self.recordSize
        )

        chipsOrigin = CGPoint(x: preview.minX + 10, y: insets.top + 10)
    }
}
