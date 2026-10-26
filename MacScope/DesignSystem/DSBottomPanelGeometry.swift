import Foundation

/// The budget includes Lumen's divider, which sits outside the panel-height binding.
/// Below the usable-panel threshold the editor receives all available space. Visibility
/// intent and the user's preferred height survive that temporary geometry restriction.
struct DSBottomPanelGeometry: Equatable, Hashable {
    static let minimumEditorHeight: CGFloat = 360
    static let maximumBottomFraction: CGFloat = 0.25
    static let minimumUsablePanelHeight: CGFloat = 48

    let availableHeight: CGFloat
    let dividerHeight: CGFloat
    let maximumPanelHeight: CGFloat

    init(availableHeight: CGFloat, dividerHeight: CGFloat) {
        self.availableHeight = availableHeight.isFinite ? max(0, availableHeight) : 0
        self.dividerHeight = dividerHeight.isFinite ? max(0, dividerHeight) : 0
        let wholeBottomBudget = min(
            self.availableHeight * Self.maximumBottomFraction,
            max(0, self.availableHeight - Self.minimumEditorHeight)
        )
        maximumPanelHeight = max(0, wholeBottomBudget - self.dividerHeight)
    }

    var canPresent: Bool { maximumPanelHeight >= Self.minimumUsablePanelHeight }

    var minimumPanelHeight: CGFloat {
        min(Self.minimumUsablePanelHeight, maximumPanelHeight)
    }

    /// Lumen otherwise gives its minimum precedence over both its maxima.
    var lumenMaximumFraction: CGFloat {
        availableHeight > 0 ? maximumPanelHeight / availableHeight : 0
    }

    func clampedPanelHeight(_ preferredHeight: CGFloat) -> CGFloat {
        let finiteHeight = preferredHeight.isFinite ? preferredHeight : minimumPanelHeight
        return min(max(finiteHeight, minimumPanelHeight), maximumPanelHeight)
    }

    func wholeBottomHeight(preferredHeight: CGFloat, isPresented: Bool) -> CGFloat {
        isPresented && canPresent ? clampedPanelHeight(preferredHeight) + dividerHeight : 0
    }
}
