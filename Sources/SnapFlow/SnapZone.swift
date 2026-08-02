import AppKit

struct SnapOuterEdges: OptionSet {
    let rawValue: Int

    static let left = SnapOuterEdges(rawValue: 1 << 0)
    static let right = SnapOuterEdges(rawValue: 1 << 1)
    static let top = SnapOuterEdges(rawValue: 1 << 2)
    static let bottom = SnapOuterEdges(rawValue: 1 << 3)

    static let horizontal: SnapOuterEdges = [.left, .right]
    static let vertical: SnapOuterEdges = [.top, .bottom]
    static let all: SnapOuterEdges = [.left, .right, .top, .bottom]
}

enum SnapZone: String, Equatable, CaseIterable, Codable {
    case leftHalf, rightHalf
    case topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize

    var displayName: String {
        switch self {
        case .leftHalf: return "左半分"
        case .rightHalf: return "右半分"
        case .topHalf: return "上半分"
        case .bottomHalf: return "下半分"
        case .topLeft: return "左上"
        case .topRight: return "右上"
        case .bottomLeft: return "左下"
        case .bottomRight: return "右下"
        case .maximize: return "最大化"
        }
    }

    func frame(in screen: NSScreen) -> CGRect {
        let f = screen.visibleFrame
        let halfW = floor(f.width / 2)
        let halfH = floor(f.height / 2)

        switch self {
        case .leftHalf:
            return CGRect(x: f.minX, y: f.minY, width: halfW, height: f.height)
        case .rightHalf:
            return CGRect(x: f.minX + halfW, y: f.minY, width: f.width - halfW, height: f.height)
        case .topHalf:
            return CGRect(x: f.minX, y: f.minY + halfH, width: f.width, height: f.height - halfH)
        case .bottomHalf:
            return CGRect(x: f.minX, y: f.minY, width: f.width, height: halfH)
        case .topLeft:
            return CGRect(x: f.minX, y: f.minY + halfH, width: halfW, height: f.height - halfH)
        case .topRight:
            return CGRect(x: f.minX + halfW, y: f.minY + halfH, width: f.width - halfW, height: f.height - halfH)
        case .bottomLeft:
            return CGRect(x: f.minX, y: f.minY, width: halfW, height: halfH)
        case .bottomRight:
            return CGRect(x: f.minX + halfW, y: f.minY, width: f.width - halfW, height: halfH)
        case .maximize:
            return f
        }
    }

    var sizeConstraintAnchor: CGPoint {
        switch self {
        case .leftHalf:
            return CGPoint(x: 0, y: 0.5)
        case .rightHalf:
            return CGPoint(x: 1, y: 0.5)
        case .topHalf:
            return CGPoint(x: 0.5, y: 1)
        case .bottomHalf:
            return CGPoint(x: 0.5, y: 0)
        case .topLeft:
            return CGPoint(x: 0, y: 1)
        case .topRight:
            return CGPoint(x: 1, y: 1)
        case .bottomLeft:
            return CGPoint(x: 0, y: 0)
        case .bottomRight:
            return CGPoint(x: 1, y: 0)
        case .maximize:
            return CGPoint(x: 0.5, y: 0.5)
        }
    }

    var requiredOuterEdges: SnapOuterEdges {
        switch self {
        case .leftHalf:
            return [.left, .top, .bottom]
        case .rightHalf:
            return [.right, .top, .bottom]
        case .topHalf:
            return [.left, .right, .top]
        case .bottomHalf:
            return [.left, .right, .bottom]
        case .topLeft:
            return [.left, .top]
        case .topRight:
            return [.right, .top]
        case .bottomLeft:
            return [.left, .bottom]
        case .bottomRight:
            return [.right, .bottom]
        case .maximize:
            return .all
        }
    }

    var verticalSibling: SnapZone {
        switch self {
        case .topLeft: return .bottomLeft
        case .bottomLeft: return .topLeft
        case .topRight: return .bottomRight
        case .bottomRight: return .topRight
        default: return self
        }
    }

    static func detect(
        at point: CGPoint,
        on screen: NSScreen,
        edgeThreshold: CGFloat = 26,
        cornerBand: CGFloat = 120
    ) -> SnapZone? {
        detect(
            at: point,
            in: screen.frame,
            edgeThreshold: edgeThreshold,
            cornerBand: cornerBand
        )
    }

    static func detect(
        at point: CGPoint,
        in frame: CGRect,
        edgeThreshold: CGFloat = 26,
        cornerBand: CGFloat = 120
    ) -> SnapZone? {
        let f = frame
        let safeEdgeThreshold = max(edgeThreshold, 0)
        let safeCornerBand = max(cornerBand, 0)
        let nearLeft = point.x <= f.minX + safeEdgeThreshold
        let nearRight = point.x >= f.maxX - safeEdgeThreshold
        let nearTop = point.y >= f.maxY - safeEdgeThreshold
        let nearBottom = point.y <= f.minY + safeEdgeThreshold

        if nearLeft && point.y >= f.maxY - safeCornerBand { return .topLeft }
        if nearRight && point.y >= f.maxY - safeCornerBand { return .topRight }
        if nearLeft && point.y <= f.minY + safeCornerBand { return .bottomLeft }
        if nearRight && point.y <= f.minY + safeCornerBand { return .bottomRight }
        if nearLeft { return .leftHalf }
        if nearRight { return .rightHalf }
        if nearTop { return .maximize }
        if nearBottom { return nil }
        return nil
    }
}
