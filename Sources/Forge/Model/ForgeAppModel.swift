import Foundation
import Observation
import CoreGraphics
import AuthenticationServices
import CommonKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Bridges CommonKit's `UniversalSyncManager` to SwiftUI for Forge: accounts, synced folders and a status line.
/// Forge calls `projectDidChange` after every save; the manager uploads after 10 s of quiet, or at once on suspend.
@MainActor
@Observable
public final class ForgeCloudController {
    public private(set) var providers: [ProviderStatus] = []
    public private(set) var folders: [SyncFolderConfig] = []
    public private(set) var statusText = "Up to date"
    public private(set) var lastError: String?
    @ObservationIgnored public var onProjectUpdated: ((URL) -> Void)?
    @ObservationIgnored let manager: UniversalSyncManager
    @ObservationIgnored private var listener: Task<Void, Never>?

    public init(manager: UniversalSyncManager, providers: [any CloudStorageProvider]) {
        self.manager = manager
        listener = Task { [weak self] in
            for p in providers { await manager.register(p) }
            await self?.refresh()
            await manager.syncAll()
            for await event in manager.events() {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    /// The real thing: tokens in the Keychain, app keys from Application Support/Forge/CloudKeys.plist.
    public static func live() -> ForgeCloudController? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let manager = try? UniversalSyncManager(stateDirectory: support.appendingPathComponent("Forge/Sync", isDirectory: true)) else { return nil }
        let keys = CloudProviderConfiguration.loadDefault(appFolderName: "Forge")
        return ForgeCloudController(manager: manager, providers: CloudProviderCatalog.standardProviders(configuration: keys))
    }

    deinit { listener?.cancel() }

    private func handle(_ event: SyncEvent) {
        switch event {
        case .idle:
            statusText = "Up to date"
        case .syncing(let p):
            statusText = (p.phase == .downloading ? "Downloading" : p.phase == .uploading ? "Uploading" : "Checking") + "…"
        case .conflict(let copy):
            statusText = "Kept both versions: \(copy.deletingPathExtension().lastPathComponent)"
            onProjectUpdated?(copy)
        case .projectUpdated(let url):
            onProjectUpdated?(url)
        case .error(let message):
            lastError = message
            statusText = "Sync problem"
        case .needsSignIn:
            statusText = "Sign-in needed"
        }
    }

    public func refresh() async {
        providers = await manager.providerStatuses()
        folders = await manager.syncFolders()
    }

    public func signIn(_ id: CloudProviderID) async {
        lastError = nil
        do {
            try await manager.signIn(to: id, using: SystemWebAuthenticator { Self.presentationAnchor() })
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    public func connect(folder: URL, to id: CloudProviderID, remoteFolder: String = "/Forge Projects") async {
        do {
            try await manager.addSyncFolder(name: folder.lastPathComponent, providerID: id, localFolder: folder, remoteFolder: CloudPath(remoteFolder))
            await refresh()
            await manager.syncAll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func projectDidChange(_ url: URL) {
        Task { await manager.projectDidChange(url) }
    }

    public func appWillSuspend() {
        Task { await manager.appWillSuspend() }
    }

    public func syncNow() {
        Task { await manager.syncAll() }
    }

    private static func presentationAnchor() -> ASPresentationAnchor {
        #if os(macOS)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #endif
    }
}

/// App-level state shared by the Mac and iPad apps: the open document, the project gallery, autosave, the sync hook.
@MainActor
@Observable
public final class ForgeAppModel {
    public private(set) var document: CadDocument?
    public let cloud: ForgeCloudController?
    public let renderer = CadRenderer()
    public var galleryFolder: URL {
        didSet {
            UserDefaults.standard.set(galleryFolder.path, forKey: "Forge.galleryFolder")
            refreshGallery()
        }
    }
    public private(set) var galleryItems: [GalleryItem] = []
    public var errorMessage: String?
    public private(set) var lastSaved: Date?

    public struct GalleryItem: Identifiable, Equatable {
        public var id: URL { url }
        public var url: URL
        public var name: String
        public var thumbnail: CGImage?
        public var detail: String
        public var modified: Date

        public static func == (a: GalleryItem, b: GalleryItem) -> Bool { a.url == b.url && a.modified == b.modified }
    }

    @ObservationIgnored public var onProjectSaved: ((URL, [String]) -> Void)?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored public var autosaveDelay: UInt64 = 4_000_000_000

    public init(galleryFolder: URL? = nil, cloud: ForgeCloudController? = nil) {
        self.cloud = cloud
        let saved = UserDefaults.standard.string(forKey: "Forge.galleryFolder").map { URL(fileURLWithPath: $0) }
        self.galleryFolder = galleryFolder ?? saved ?? Self.defaultGalleryFolder
        refreshGallery()
        if let cloud {
            onProjectSaved = { [weak cloud] url, _ in cloud?.projectDidChange(url) }
            cloud.onProjectUpdated = { [weak self] url in self?.projectChangedOnDisk(url) }
        }
    }

    private func projectChangedOnDisk(_ url: URL) {
        refreshGallery()
        guard let doc = document, doc.fileURL?.standardizedFileURL == url.standardizedFileURL,
              !doc.hasUnsavedChanges, let fresh = try? CadDocument.open(url) else { return }
        fresh.camera = doc.camera
        fresh.viewport = doc.viewport
        install(fresh)
    }

    public nonisolated static var defaultGalleryFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("Forge", isDirectory: true)
    }

    public func refreshGallery() {
        let fm = FileManager.default
        try? fm.createDirectory(at: galleryFolder, withIntermediateDirectories: true)
        let urls = (try? fm.contentsOfDirectory(at: galleryFolder, includingPropertiesForKeys: nil)) ?? []
        galleryItems = urls.filter { $0.pathExtension == CadDocument.fileExtension }.compactMap { url in
            guard let peek = CadDocument.peek(url) else { return nil }
            let m = peek.manifest
            return GalleryItem(url: url, name: url.deletingPathExtension().lastPathComponent, thumbnail: peek.thumbnail,
                               detail: "\(m.featureCount) feature\(m.featureCount == 1 ? "" : "s") · \(m.bodyCount) bod\(m.bodyCount == 1 ? "y" : "ies")",
                               modified: m.modified)
        }
        .sorted { $0.modified > $1.modified }
    }

    public func newDocument(name: String? = nil) {
        let base = name ?? "Part"
        var candidate = base
        var n = 2
        while FileManager.default.fileExists(atPath: galleryFolder.appendingPathComponent(candidate + ".forge").path) {
            candidate = "\(base) \(n)"
            n += 1
        }
        let doc = CadDocument(name: candidate)
        doc.fileURL = galleryFolder.appendingPathComponent(candidate + ".forge")
        install(doc)
        saveNow()
    }

    public func open(_ url: URL) {
        do {
            install(try CadDocument.open(url))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func install(_ doc: CadDocument) {
        document = doc
        doc.onChange = { [weak self] in self?.scheduleAutosave() }
    }

    public func closeDocument() {
        saveNow()
        document = nil
        refreshGallery()
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let delay = autosaveDelay
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    public func saveNow() {
        guard let doc = document, let url = doc.fileURL else { return }
        // Don't save half-finished sketches: the tree only changes when a sketch is finished.
        do {
            let changed = try doc.save(to: url, thumbnail: thumbnail(for: doc))
            lastSaved = Date()
            onProjectSaved?(url, changed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func thumbnail(for doc: CadDocument) -> CGImage? {
        guard let renderer else { return nil }
        var camera = CadCamera()
        var settings = ViewportSettings()
        settings.showGrid = false
        settings.showSketches = false
        let box = doc.bodies.reduce(AABB.empty) { $0.union($1.solid.bounds) }
        guard !box.isEmpty else { return nil }
        camera.frame(box, viewSize: CGSize(width: 512, height: 384))
        let scene = CadSceneDescription(bodies: doc.bodies, settings: settings, camera: camera, modelRevision: -2 - doc.modelRevision)
        return renderer.renderImage(scene, width: 512, height: 384)
    }

    public func appWillSuspend() {
        saveNow()
        cloud?.appWillSuspend()
    }

    public func exportSTL() -> Data? {
        document.map { STLExporter.data(for: $0.bodies) }
    }
}
