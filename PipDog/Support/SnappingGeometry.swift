import CoreGraphics
import Foundation

/// 小窗摆放的纯几何计算（Cocoa 屏幕坐标，点）：拖动吸附、级联起点、记忆位置在屏幕变化后的修正。
/// 不依赖 AppKit，输入都是矩形和尺寸，不碰 NSScreen，方便用真实屏幕坐标单独验证。
enum SnappingGeometry {
    /// 拖动吸附的距离（点）：窗口边缘进入这个范围才对齐
    static let snapThreshold: CGFloat = 8
    /// 级联时每个新面板相对上一个的偏移（点）
    static let cascadeStep: CGFloat = 24
    /// 级联离屏幕可见区域边缘的间距（点）
    static let edgeMargin: CGFloat = 20

    /// 把拖动中的窗口吸附到屏幕可见区域边缘或同一屏幕上的其他 PiP。
    /// 只改 origin，绝不改尺寸：拖动是移动手势，尺寸是用户已经调好的。
    /// 相邻 PiP 边缘贴合（gap 为 0），不留缝也不重叠。
    static func snappedFrame(_ proposed: CGRect, in visibleFrame: CGRect, siblings: [CGRect],
                             threshold: CGFloat = snapThreshold) -> CGRect {
        guard proposed.width > 0, proposed.height > 0,
              visibleFrame.width > 0, visibleFrame.height > 0,
              threshold >= 0 else { return proposed }

        var xDeltas = [
            visibleFrame.minX - proposed.minX, // 贴屏幕左边
            visibleFrame.maxX - proposed.maxX, // 贴屏幕右边
        ]
        var yDeltas = [
            visibleFrame.minY - proposed.minY, // 贴屏幕下边（Dock 之上）
            visibleFrame.maxY - proposed.maxY, // 贴屏幕上边（菜单栏之下）
        ]

        for sibling in siblings where sibling.width > 0 && sibling.height > 0
            && visibleFrame.intersects(sibling) {
            // X 轴只参考垂直方向重叠或快要贴上的窗口，免得被屏幕另一头的无关窗口拉过去；Y 轴同理。
            if intervalsAreNear(proposed.minY, proposed.maxY, sibling.minY, sibling.maxY, tolerance: threshold) {
                xDeltas += [
                    sibling.minX - proposed.minX, // 左边对齐
                    sibling.maxX - proposed.maxX, // 右边对齐
                    sibling.minX - proposed.maxX, // 贴到 sibling 左边
                    sibling.maxX - proposed.minX, // 贴到 sibling 右边
                ]
            }
            if intervalsAreNear(proposed.minX, proposed.maxX, sibling.minX, sibling.maxX, tolerance: threshold) {
                yDeltas += [
                    sibling.minY - proposed.minY, // 底边对齐
                    sibling.maxY - proposed.maxY, // 顶边对齐
                    sibling.minY - proposed.maxY, // 贴到 sibling 下方
                    sibling.maxY - proposed.minY, // 贴到 sibling 上方
                ]
            }
        }

        var result = proposed
        if let dx = closestDelta(in: xDeltas, threshold: threshold) { result.origin.x += dx }
        if let dy = closestDelta(in: yDeltas, threshold: threshold) { result.origin.y += dy }
        return result
    }

    /// 没有记忆位置的新面板从哪里冒出来：可见区域右上角开始，每个往后（左、下）错开 step 点，
    /// 走不下（再走就出可见区域）就回到起点。
    static func cascadeOrigin(size: CGSize, index: Int, in visibleFrame: CGRect,
                              step: CGFloat = cascadeStep, margin: CGFloat = edgeMargin) -> CGPoint {
        guard visibleFrame.width > 0, visibleFrame.height > 0, step > 0 else { return .zero }
        let start = CGPoint(x: max(visibleFrame.minX + margin, visibleFrame.maxX - size.width - margin),
                            y: max(visibleFrame.minY + margin, visibleFrame.maxY - size.height))
        // 左、下两个方向还能走几步而不出可见区域（第一步是起点本身）
        let stepsLeft = max(0, (start.x - visibleFrame.minX - margin) / step)
        let stepsDown = max(0, (start.y - visibleFrame.minY - margin) / step)
        let positions = max(1, Int(min(stepsLeft, stepsDown).rounded(.down)) + 1)
        let stepIndex = CGFloat(max(0, index) % positions)
        return CGPoint(x: (start.x - stepIndex * step).rounded(), y: (start.y - stepIndex * step).rounded())
    }

    /// 记忆的位置在屏幕变化（拔掉外接屏、改了分辨率）后仍要看得见：和任意一块屏幕有交集就原样用，
    /// 否则收进最近那块屏幕的可见区域。记忆的是面板左上角（屏幕坐标），返回面板原点；只改原点。
    static func restoredOrigin(topLeft: CGPoint, size: CGSize, screenFrames: [CGRect],
                               visibleFrames: [CGRect]) -> CGPoint {
        let rect = CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        guard !screenFrames.contains(where: { $0.intersects(rect) }) else { return rect.origin }
        guard let index = screenIndex(containing: rect, in: screenFrames),
              visibleFrames.indices.contains(index) else { return rect.origin }
        return constrainedOrigin(rect.origin, size: size, in: visibleFrames[index])
    }

    /// 承载 rect 的屏幕下标：重叠面积最大的那块；落在屏幕之间的空洞里时取中心最近的。
    static func screenIndex(containing rect: CGRect, in screenFrames: [CGRect]) -> Int? {
        guard !screenFrames.isEmpty else { return nil }
        let overlaps = screenFrames.map { frame -> CGFloat in
            let overlap = frame.intersection(rect)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        if let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 {
            return best
        }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return screenFrames.indices.min {
            squaredDistance(from: center, to: screenFrames[$0]) < squaredDistance(from: center, to: screenFrames[$1])
        }
    }

    /// 把窗口原点收进一块屏幕的可见区域（窗口比可见区域还大时贴左上角）
    static func constrainedOrigin(_ origin: CGPoint, size: CGSize, in visibleFrame: CGRect) -> CGPoint {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return origin }
        return CGPoint(x: min(max(origin.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - size.width)),
                       y: min(max(origin.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - size.height)))
    }

    /// 点到矩形的最短距离的平方（点在矩形里时为 0）
    static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = point.x < rect.minX ? rect.minX - point.x : max(point.x - rect.maxX, 0)
        let dy = point.y < rect.minY ? rect.minY - point.y : max(point.y - rect.maxY, 0)
        return dx * dx + dy * dy
    }

    private static func intervalsAreNear(_ aMin: CGFloat, _ aMax: CGFloat, _ bMin: CGFloat, _ bMax: CGFloat,
                                         tolerance: CGFloat) -> Bool {
        max(aMin, bMin) <= min(aMax, bMax) + tolerance
    }

    private static func closestDelta(in candidates: [CGFloat], threshold: CGFloat) -> CGFloat? {
        candidates
            .filter { $0.isFinite && abs($0) <= threshold }
            .min { abs($0) < abs($1) }
    }
}