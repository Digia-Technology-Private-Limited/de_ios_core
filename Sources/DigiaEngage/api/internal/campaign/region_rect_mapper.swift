import CoreGraphics

struct EdgeInsets2 { let left: CGFloat; let top: CGFloat; let right: CGFloat; let bottom: CGFloat }

func computeRegionRect(_ frac: RegionFrac, screen: CGSize, insets: EdgeInsets2) -> CGRect {
    let contentX = insets.left
    let contentY = insets.top
    let contentW = max(0, screen.width - insets.left - insets.right)
    let contentH = max(0, screen.height - insets.top - insets.bottom)

    let w = min(max(0, frac.w * contentW), screen.width)
    let h = min(max(0, frac.h * contentH), screen.height)
    var x = contentX + frac.x * contentW
    var y = contentY + frac.y * contentH
    x = min(max(0, x), max(0, screen.width - w))
    y = min(max(0, y), max(0, screen.height - h))
    return CGRect(x: x, y: y, width: w, height: h)
}
