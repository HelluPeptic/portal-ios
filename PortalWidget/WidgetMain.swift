import WidgetKit
import SwiftUI

/// The widgets the app offers (ServerWidget.swift) and the live panel
/// (LivePanel.swift). Kept apart so
/// Previews/WidgetPreviewTests can draw them without this entry point.
@main
struct PortalWidgets: WidgetBundle {
    var body: some Widget {
        ServerWidget()
        CPUGaugeWidget()
        TemperatureGaugeWidget()
        MemoryGaugeWidget()
        VaultGaugeWidget()
        PiLiveActivity()
        if #available(iOS 18.0, *) {
            LivePanelControl()
            MinecraftServerControl()
        }
    }
}
