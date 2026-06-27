import SwiftUI
import Photos

struct ContentView: View {
    @Environment(PhotoLibrary.self) private var library
    @State private var isReviewing = false

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
        } else if library.libraryTotalCount == 0 && library.hasStarted {
            CenteredMessage(systemImage: "photo",
                            title: "No photos found",
                            message: "Your photo library appears to be empty.")
        } else if isReviewing && !library.isFinished {
            ReviewView()
                .onChange(of: library.isFinished) { _, finished in
                    if finished { isReviewing = false }
                }
        } else {
            HomeView(onStartReview: { isReviewing = true })
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

            Picker("Media type", selection: Binding(
                get: { library.mediaFilter },
                set: { library.mediaFilter = $0 })) {
                ForEach(PhotoLibrary.MediaFilter.allCases) {
                    Label($0.rawValue, systemImage: $0.systemImage).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 560)

            DateRangeRow(
                enabled: Binding(get: { library.dateRangeEnabled }, set: { library.dateRangeEnabled = $0 }),
                startDate: Binding(get: { library.startDate }, set: { library.startDate = $0 }),
                endDate: Binding(get: { library.endDate }, set: { library.endDate = $0 })
            )
            .frame(maxWidth: 460)

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

// MARK: - Date range row (shared between WelcomeView and FilterSheet)

struct DateRangeRow: View {
    @Binding var enabled: Bool
    @Binding var startDate: Date
    @Binding var endDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Filter by date range", isOn: $enabled)
                .toggleStyle(.checkbox)

            if enabled {
                HStack(spacing: 6) {
                    Text("From").foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                    DatePicker("", selection: $startDate, in: ...endDate, displayedComponents: .date)
                        .labelsHidden()
                    Text("to").foregroundStyle(.secondary)
                    DatePicker("", selection: $endDate, in: startDate..., displayedComponents: .date)
                        .labelsHidden()
                }
            }
        }
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
