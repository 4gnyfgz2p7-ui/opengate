import SwiftUI

/// 横屏版式的几何解算。
///
/// 单独成文件、只依赖 `CGSize` 与安全区，不引用任何采集类型：
/// 版式改数字不会碰到拍摄逻辑，拍摄改逻辑也不会挪动版式。
///
/// 约束与顺序（与本地离屏渲染脚本 `_design/render_layout.py` 完全一致，
/// 两边用的是同一组数字，改动必须同步）：
///
/// 1. 右轨贴右边安全区，宽 56，六个圆钮竖排；
/// 2. 底栏占 `BAR_H`，取景高度 = 底栏上沿 − 间距 − 顶部间距；
/// 3. 取景按 Open Gate 画幅 1.397 定宽，镜头轨放在它左侧 12pt；
/// 4. 「镜头轨 + 间距 + 取景」作为一个整体，在右侧参数轨与左安全区之间居中。
struct LandscapeLayout {

    static let margin: CGFloat = 8
    static let railWidth: CGFloat = 56
    static let knobSize: CGFloat = 56
    static let knobGap: CGFloat = 8
    static let lensSize: CGFloat = 44
    static let lensGap: CGFloat = 8
    static let barHeight: CGFloat = 52
    static let recordSize: CGFloat = 52
    static let trackGap: CGFloat = 16
    static let lensToPreview: CGFloat = 12
    static let previewToRail: CGFloat = 12
    /// Open Gate 画幅：4224 / 3024
    static let aspect: CGFloat = 4224.0 / 3024.0

    let size: CGSize
    let insets: EdgeInsets

    let preview: CGRect
    let lensRail: CGRect
    let rail: CGRect
    let bar: CGRect
    let track: CGRect

    var columnHeight: CGFloat {
        Self.knobSize * 6 + Self.knobGap * 5
    }

    init(size: CGSize, insets: EdgeInsets) {
        self.size = size
        self.insets = insets

        let left = insets.leading + Self.margin
        let right = size.width - insets.trailing - Self.margin
        let bottomLimit = size.height - insets.bottom - Self.margin

        // 右轨
        let railX = right - Self.railWidth
        let columnHeight = Self.knobSize * 6 + Self.knobGap * 5
        let railY = max(insets.top + Self.margin, (size.height - columnHeight) / 2)
        rail = CGRect(x: railX, y: railY, width: Self.railWidth, height: columnHeight)

        // 底栏：贴底安全区
        let barY = bottomLimit - Self.barHeight
        // 取景高度由「底栏上沿」顶出来，宽度按画幅换算
        let top = insets.top + Self.margin
        let previewHeight = max(80, barY - Self.margin - top)
        let previewWidth = previewHeight * Self.aspect

        // 镜头轨 + 取景作为一组居中
        let groupWidth = Self.lensSize + Self.lensToPreview + previewWidth
        let freeWidth = max(groupWidth, railX - Self.previewToRail - left)
        let groupX = left + (freeWidth - groupWidth) / 2

        let lensHeight = Self.lensSize * 4 + Self.lensGap * 3
        lensRail = CGRect(
            x: groupX,
            y: top + (previewHeight - lensHeight) / 2,
            width: Self.lensSize,
            height: lensHeight
        )

        let previewX = groupX + Self.lensSize + Self.lensToPreview
        preview = CGRect(x: previewX, y: top, width: previewWidth, height: previewHeight)

        bar = CGRect(x: previewX, y: barY, width: previewWidth, height: Self.barHeight)
        track = CGRect(
            x: bar.minX + Self.recordSize + Self.trackGap,
            y: bar.minY,
            width: max(80, bar.width - Self.recordSize - Self.trackGap),
            height: Self.barHeight
        )
    }
}
