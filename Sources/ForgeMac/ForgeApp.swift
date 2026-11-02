import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ForgeCore

@main
struct ForgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = ForgeAppModel(cloud: ForgeCloudController.live())

    var body: some Scene {
        WindowGroup("Forge") {
            ForgeRootView(model: model)
                .frame(minWidth: 1100, minHeight: 720)
                .onAppear { appDelegate.model = model }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
                    model.appWillSuspend()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.cloud?.syncNow()
                }
        }
        .commands { ForgeCommands(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: ForgeAppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.appWillSuspend() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls where url.pathExtension.lowercased() == "forge" { model?.open(url) }
        }
    }
}

struct ForgeCommands: Commands {
    let model: ForgeAppModel

    private var doc: CadDocument? { model.document }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Part") { model.newDocument() }.keyboardShortcut("n")
            Button("Open Forge File…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.package, .folder]
                panel.canChooseDirectories = true
                panel.treatsFilePackagesAsDirectories = false
                if panel.runModal() == .OK, let url = panel.url { model.open(url) }
            }
            .keyboardShortcut("o")
            Divider()
            Button("Back to Projects") { model.closeDocument() }.keyboardShortcut("w").disabled(doc == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.saveNow() }.keyboardShortcut("s").disabled(doc == nil)
            Button("Export STL…") {
                guard let data = model.exportSTL() else { return }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = (doc?.name ?? "Part") + ".stl"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    model.errorMessage = error.localizedDescription
                }
            }
            .disabled(doc == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { doc?.undo() }.keyboardShortcut("z")
            Button("Redo") { doc?.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }
}
