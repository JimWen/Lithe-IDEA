import SwiftUI
import LitheCoreContracts

struct GoToolActionsMenu: View {
    @EnvironmentObject private var model: AppModel
    let location: ProjectMetadataLocation
    let includesModuleActions: Bool
    var body: some View {
        Group {
            Divider()
            Button("Go Build") { model.startGoTool(.build, location: location) }
            Button("Go Test") { model.startGoTool(.test, location: location) }
            Button("Go Vet") { model.startGoTool(.vet, location: location) }
            Button("Check Formatting") { model.startGoTool(.checkFormatting, location: location) }
            if includesModuleActions {
                Menu("Go Module") {
                    Button("Tidy") { model.startGoTool(.moduleTidy, location: location) }
                    Button("Download") { model.startGoTool(.moduleDownload, location: location) }
                    Button("Verify") { model.startGoTool(.moduleVerify, location: location) }
                }
            }
        }.disabled(location.rootID != "workspace")
    }
}
