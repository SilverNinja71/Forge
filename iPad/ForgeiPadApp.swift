// iPad app entry point. Not part of Package.swift: add it to an Xcode "App" project (iOS 17+) that links the
// ForgeCore library from this package — see README.md, "iPad".

import SwiftUI
import ForgeCore

@main
struct ForgeiPadApp: App {
    @State private var model = ForgeAppModel(cloud: ForgeCloudController.live())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ForgeRootView(model: model)
                .onOpenURL { url in
                    if url.pathExtension.lowercased() == "forge" { model.open(url) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Save (and let cloud sync upload) as soon as the app leaves the foreground.
            if phase == .background { model.appWillSuspend() }
            if phase == .active { model.cloud?.syncNow() }
        }
    }
}
