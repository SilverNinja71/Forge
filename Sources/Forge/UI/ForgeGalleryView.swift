import SwiftUI
import CommonKit

/// The first screen: gallery when nothing's open, the workspace once a project is.
public struct ForgeRootView: View {
    @Bindable var model: ForgeAppModel

    public init(model: ForgeAppModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if let doc = model.document {
                ForgeWorkspaceView(model: model, document: doc)
                    .id(ObjectIdentifier(doc))
            } else {
                ForgeGalleryView(model: model)
            }
        }
        .alert("Forge", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

public struct ForgeGalleryView: View {
    @Bindable var model: ForgeAppModel
    @State private var showCloud = false

    public init(model: ForgeAppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Forge").font(.largeTitle.bold())
                Spacer()
                if let cloud = model.cloud {
                    Text(cloud.statusText).font(.caption).foregroundStyle(.secondary)
                    Button("Cloud Sync…") { showCloud = true }
                }
                Button {
                    model.newDocument()
                } label: { Label("New Part", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
            Divider()
            if model.galleryItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "cube.transparent").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("No parts yet").font(.title3)
                    Text("Make a new part to start sketching.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                        ForEach(model.galleryItems) { item in card(item) }
                    }
                    .padding(16)
                }
            }
        }
        .sheet(isPresented: $showCloud) {
            if let cloud = model.cloud { ForgeCloudSettingsView(cloud: cloud, galleryFolder: model.galleryFolder) { showCloud = false } }
        }
    }

    private func card(_ item: ForgeAppModel.GalleryItem) -> some View {
        Button {
            model.open(item.url)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if let t = item.thumbnail {
                        Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "cube").font(.largeTitle).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 150)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(item.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Which accounts are connected and where the gallery syncs.
public struct ForgeCloudSettingsView: View {
    @Bindable var cloud: ForgeCloudController
    let galleryFolder: URL
    let dismiss: () -> Void

    public init(cloud: ForgeCloudController, galleryFolder: URL, dismiss: @escaping () -> Void) {
        self.cloud = cloud
        self.galleryFolder = galleryFolder
        self.dismiss = dismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Cloud Sync").font(.title2.bold())
                Spacer()
                Text(cloud.statusText).font(.caption).foregroundStyle(.secondary)
                Button("Done", action: dismiss)
            }
            Text("Parts are always saved on this device first. Synced folders upload changes 10 seconds after you stop editing, or right away when you switch apps. If two devices edit the same part, Forge keeps both as a “Conflicted Copy”.")
                .font(.callout).foregroundStyle(.secondary)
            GroupBox("Accounts") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(cloud.providers) { p in
                        HStack {
                            Text(p.displayName)
                            Spacer()
                            switch p.authState {
                            case .signedIn:
                                Button("Sync gallery") { Task { await cloud.connect(folder: galleryFolder, to: p.id) } }
                            case .notConfigured:
                                Text("Needs app keys").font(.caption).foregroundStyle(.secondary)
                            default:
                                Button("Sign in") { Task { await cloud.signIn(p.id) } }
                            }
                        }
                    }
                    if cloud.providers.isEmpty { ProgressView() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            GroupBox("Synced folders") {
                VStack(alignment: .leading, spacing: 6) {
                    if cloud.folders.isEmpty {
                        Text("None yet.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(cloud.folders) { f in
                        Text("\(f.localFolderURL.lastPathComponent) → \(f.remoteFolder.description)").font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            if let error = cloud.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(18)
        .frame(width: 520)
    }
}
