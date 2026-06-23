import SwiftUI
import Photos

struct ContentView: View {
    @Environment(PhotoLibrary.self) private var library

    var body: some View {
        Group {
            switch library.status {
            case .notDetermined:
                WelcomeView()
            case .denied, .restricted:
                DeniedView()
            case .authorized, .limited:
                authorizedContent
            @unknown default:
                DeniedView()
            }
        }
        .task {
            if (library.status == .authorized || library.status == .limited) && !library.hasStarted {
                await library.loadAssets()
            }
        }
    }

    @ViewBuilder
    private var authorizedContent: some View {
        if library.isLoading {
            CenteredMessage(systemImage: "photo.on.rectangle.angled",
                            title: "Loading your library…",
                            message: nil) { ProgressView() }
        } else if library.libraryTotalCount == 0 {
            CenteredMessage(systemImage: "photo",
                            title: "No photos found",
                            message: "Your photo library appears to be empty.")
        } else if library.isFinished {
            SummaryView()
        } else {
            ReviewView()
        }
    }
}

// MARK: - Welcome

private struct WelcomeView: View {
    @Environment(PhotoLibrary.self) private var library

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "rectangle.stack.badge.person.crop")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("PhotoSweep")
                .font(.largeTitle.bold())
            Text("Quickly review your photos and videos one at a time.\nSwipe right to keep, left to delete.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Picker("Start with", selection: Binding(
                get: { library.sortOrder },
                set: { library.sortOrder = $0 })) {
                ForEach(PhotoLibrary.SortOrder.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)

            Button {
                Task { await library.requestAccess() }
            } label: {
                Text("Grant Photo Access & Start")
                    .font(.headline)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Denied

private struct DeniedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Photo access is required")
                .font(.title2.bold())
            Text("PhotoSweep needs permission to show and delete photos.\nEnable it in System Settings → Privacy & Security → Photos.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open Privacy Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Summary / finish

private struct SummaryView: View {
    @Environment(PhotoLibrary.self) private var library
    @State private var deletionFailed = false

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: library.pendingDeletion.isEmpty ? "checkmark.seal.fill" : "trash.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(library.pendingDeletion.isEmpty ? .green : .red)

            Text(library.pendingDeletion.isEmpty ? "All caught up!" : "Ready to clean up")
                .font(.largeTitle.bold())

            HStack(spacing: 40) {
                stat(count: library.keptCount, label: "Kept", tint: .green)
                stat(count: library.pendingDeletion.count, label: "To delete", tint: .red)
            }

            if !library.pendingDeletion.isEmpty {
                Text("These move to Recently Deleted, where they stay for 30 days before being permanently removed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)

                Button {
                    Task {
                        let ok = await library.confirmDeletions()
                        deletionFailed = !ok
                    }
                } label: {
                    Label("Delete \(library.pendingDeletion.count) item\(library.pendingDeletion.count == 1 ? "" : "s")",
                          systemImage: "trash.fill")
                        .font(.headline)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(library.isDeleting)
            }

            Button("Review Again") {
                Task { await library.resetAndLoadAssets() }
            }
            .controlSize(.large)
            .disabled(library.isDeleting)

            if library.isDeleting { ProgressView() }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Couldn't delete items", isPresented: $deletionFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The deletion was cancelled or failed. Your photos are unchanged.")
        }
    }

    private func stat(count: Int, label: String, tint: Color) -> some View {
        VStack {
            Text("\(count)").font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(tint)
            Text(label).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Reusable

private struct CenteredMessage<Accessory: View>: View {
    let systemImage: String
    let title: String
    let message: String?
    @ViewBuilder var accessory: () -> Accessory

    init(systemImage: String, title: String, message: String?,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.accessory = accessory
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage).font(.system(size: 52)).foregroundStyle(.secondary)
            Text(title).font(.title2.bold())
            if let message {
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            accessory()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
