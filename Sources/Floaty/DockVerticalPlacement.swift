import CoreGraphics

/// Vertical alignment in the space remaining beside a parent window.
enum DockVerticalPlacement {
    static func offset(alignment: CGFloat, parentHeight: CGFloat,
                       panelHeight: CGFloat, gap: CGFloat) -> CGFloat {
        let travel = parentHeight - panelHeight - 2 * gap
        guard travel > 0 else { return (parentHeight - panelHeight) / 2 }
        return gap + min(max(alignment, 0), 1) * travel
    }

    static func alignment(offset: CGFloat, parentHeight: CGFloat,
                          panelHeight: CGFloat, gap: CGFloat) -> CGFloat? {
        let travel = parentHeight - panelHeight - 2 * gap
        guard travel > 0 else { return nil }
        return min(max((offset - gap) / travel, 0), 1)
    }
}
