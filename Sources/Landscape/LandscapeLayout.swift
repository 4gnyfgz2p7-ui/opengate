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
/// 3. 焦距切换浮在画面左边缘，「靠画面」而不是另起一列。
///
/// 约束顺序决定了其余位置：先撑满取景 → 条贴右 → 参数列贴条 → 录制键贴参数列。
/// 与 `_design/render_layout.py` 用的是同一组数字，改动必须两边同步。
struct LandscapeLayout {

    static let margin: CGFloat = 8
    static let knobSize: CGFloat = 56
    static let knobGap: CGFloat = 8
    static let lensSize: CGFloat = 44
    static let lensGap: CGFloat = 8
    static let barWidth: CGFloat = 52
    static let barHeight: CGFloat = 240
    static let recordSize: CGFloat = 56
    static let gearSize: CGFloat = 38
    static let gap: CGFloat = 12
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
        // ---- 取景：高度撑满 ----
        var height = size.height
        var width = height * Self.aspect
        let maxWidth = size.width * Self.previewMaxWidthRatio
        if width > maxWidth {
            width = maxWidth
            height = width / Self.aspect
        }
        preview = CGRect(x: 0, y: 0, width: width, height: height)

        // ---- 拖拽条：贴最右 ----
        let barX = size.width - insets.trailing - Self.margin - Self.barWidth
        bar = CGRect(
            x: barX,
            y: (size.height - Self.barHeight) / 2,
            width: Self.barWidth,
            height: Self.barHeight
        )

        // ---- 参数列：贴条的左侧 ----
        let knobX = barX - Self.gap - Self.knobSize
        let columnHeight = Self.knobSize * 6 + Self.knobGap * 5
        rail = CGRect(
            x: knobX,
            y: (size.height - columnHeight) / 2,
            width: Self.knobSize,
            height: columnHeight
        )

        // ---- 录制键：贴参数列左侧、靠底 ----
        record = CGRect(
            x: knobX - Self.gap - Self.recordSize,
            y: size.height - insets.bottom - Self.margin - Self.recordSize,
            width: Self.recordSize,
            height: Self.recordSize
        )

        // ---- 设置：与录制键同列，靠顶 ----
        gear = CGRect(
            x: record.minX,
            y: insets.top + Self.margin,
            width: Self.gearSize,
            height: Self.gearSize
        )

        // ---- 焦距：浮在画面左边缘 ----
        let lensHeight = Self.lensSize * 4 + Self.lensGap * 3
        lensRail = CGRect(
            x: insets.leading + Self.margin,
            y: (size.height - lensHeight) / 2,
            width: Self.lensSize,
            height: lensHeight
        )

        chipsOrigin = CGPoint(x: insets.leading + Self.margin, y: insets.top + 10)
    }
}
