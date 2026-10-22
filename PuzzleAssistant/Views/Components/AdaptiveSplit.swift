import SwiftUI

/// Portrait: content above, panel below. Landscape (compact height): content on
/// the left filling the height, panel on the right with a fixed width.
struct AdaptiveSplit<Content: View, Panel: View>: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    var panelWidth: CGFloat = 340
    @ViewBuilder var content: () -> Content
    @ViewBuilder var panel: () -> Panel

    var isLandscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        if isLandscape {
            HStack(spacing: 0) {
                content().frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                panel().frame(width: panelWidth).frame(maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 0) {
                content()
                panel()
            }
        }
    }
}
