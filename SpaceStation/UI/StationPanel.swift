import SwiftUI

/// M2 panel surface. The card shell (glass + grid + selection) lives in
/// CardGridView; M3 will add Action overlays / prediction / Split on top.
struct StationPanel: View {
    @Environment(History.self) private var history
    @Environment(StationState.self) private var stationState

    var body: some View {
        CardGridView(edge: stationState.edge, history: history, stationState: stationState)
            .frame(width: stationState.edge.panelSize.width,
                   height: stationState.edge.panelSize.height)
            .background(.clear)
    }
}
