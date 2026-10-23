import WidgetKit
import SwiftUI

/// The widgets the app offers (ServerWidget.swift). Kept apart so
/// Previews/WidgetPreviewTests can draw them without this entry point.
@main
struct PortalWidgets: WidgetBundle {
    var body: some Widget {
        ServerWidget()
        CPUGaugeWidget()
        TemperatureGaugeWidget()
        MemoryGaugeWidget()
        VaultGaugeWidget()
    }
}
