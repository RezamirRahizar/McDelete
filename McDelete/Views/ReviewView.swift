import SwiftUI
import Photos

/// The main swipe-to-decide screen.
struct ReviewView: View {
    @Environment(PhotoLibrary.self) private var library
    @State private var dragOffset: CGSize = .zero
    @State private var isAnimatingOut = false
    @State private var showFilterSheet = false

    private let swipeThreshold: CGFloat = 110

    private var isFilterActive: Bool {
        library.mediaFilter != .all || library.dateRangeEnabled || !library.selectedAlbumID.isEmpty
    }

    private var filterHelpText: String {
        var parts: [String] = []
        if library.mediaFilter != .all { parts.append(library.mediaFilter.rawValue) }
        if library.dateRangeEnabled { parts.append("Date range") }
        if !library.selectedAlbumID.isEmpty {
            let name = library.albums.first(where: { $0.localIdentifier == library.selectedAlbumID })?.localizedTitle ?? "Album"
            parts.append(name)
        }
        return parts.isEmpty ? "Filter" : "Filter: \(parts.joined(separator: " · "))"
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider()
                cardArea
                controls
            }
            Divider()
            TimelineView()
                .frame(width: 88)
        }
        .background(.background)
        .sheet(isPresented: $showFilterSheet) {
            FilterSheet()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Reviewing \(library.reviewedCount + 1) of \(library.totalCount)")
                    .font(.headline)
                Spacer()
                Label("\(library.keptCount) kept", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label("\(library.pendingDeletion.count) to delete", systemImage: "trash.fill")
                    .foregroundStyle(.red)
                Button { showFilterSheet = true } label: {
                    Image(systemName: isFilterActive
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(library.mediaFilter == .all && !library.dateRangeEnabled && library.selectedAlbumID.isEmpty
                                 ? Color.secondary : Color.accentColor)
                .help(filterHelpText)
            }
            .font(.subheadline)

            ProgressView(value: library.progress)
                .tint(.accentColor)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Card

    private var cardArea: some View {
        ZStack {
            if let asset = library.currentAsset {
                MediaCardView(asset: asset, imageManager: library.imageManager)
                    .id(asset.localIdentifier)
                    .overlay(decisionOverlay)
                    .offset(dragOffset)
                    .rotationEffect(.degrees(Double(dragOffset.width) / 22), anchor: .bottom)
                    .gesture(dragGesture)
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                    .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Green KEEP / red DELETE stamp that fades in as the card is dragged.
    private var decisionOverlay: some View {
        let magnitude = min(abs(dragOffset.width) / swipeThreshold, 1)
        let keeping = dragOffset.width > 0
        return RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(keeping ? Color.green : Color.red, lineWidth: 6)
            .opacity(magnitude)
            .overlay(alignment: keeping ? .topLeading : .topTrailing) {
                Text(keeping ? "KEEP" : "DELETE")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(keeping ? .green : .red)
                    .padding(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(keeping ? Color.green : Color.red, lineWidth: 4)
                    )
                    .rotationEffect(.degrees(keeping ? -16 : 16))
                    .padding(24)
                    .opacity(magnitude)
            }
            .allowsHitTesting(false)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard !isAnimatingOut else { return }
                dragOffset = value.translation
            }
            .onEnded { value in
                guard !isAnimatingOut else { return }
                if value.translation.width > swipeThreshold {
                    decide(keep: true)
                } else if value.translation.width < -swipeThreshold {
                    decide(keep: false)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        dragOffset = .zero
                    }
                }
            }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 16) {
            decisionButton(title: "Delete", systemImage: "trash.fill", tint: .red,
                           shortcut: .leftArrow) { decide(keep: false) }

            Button { library.undo() } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut(.upArrow, modifiers: [])
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!library.canUndo)

            decisionButton(title: "Keep", systemImage: "checkmark", tint: .green,
                           shortcut: .rightArrow) { decide(keep: true) }
        }
        .padding(20)
    }

    private func decisionButton(title: String, systemImage: String, tint: Color,
                                shortcut: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .controlSize(.large)
        .keyboardShortcut(shortcut, modifiers: [])
        .disabled(library.currentAsset == nil || isAnimatingOut)
    }

    // MARK: - Decision animation

    private func decide(keep: Bool) {
        guard library.currentAsset != nil, !isAnimatingOut else { return }
        isAnimatingOut = true
        let direction: CGFloat = keep ? 1 : -1
        withAnimation(.easeOut(duration: 0.22)) {
            dragOffset = CGSize(width: direction * 1400, height: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if keep { library.keep() } else { library.markForDeletion() }
            dragOffset = .zero          // next card (new .id) appears centered
            isAnimatingOut = false
        }
    }
}

// MARK: - Filter sheet

private struct FilterSheet: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFilter: PhotoLibrary.MediaFilter = .all
    @State private var dateRangeEnabled: Bool = false
    @State private var startDate: Date = Date()
    @State private var endDate: Date = Date()
    @State private var selectedAlbumID: String = ""

    private var hasChanges: Bool {
        selectedFilter != library.mediaFilter ||
        dateRangeEnabled != library.dateRangeEnabled ||
        (dateRangeEnabled && (startDate != library.startDate || endDate != library.endDate)) ||
        selectedAlbumID != library.selectedAlbumID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Change Filter")
                .font(.headline)

            Picker("Media Type", selection: $selectedFilter) {
                ForEach(PhotoLibrary.MediaFilter.allCases) {
                    Label($0.rawValue, systemImage: $0.systemImage).tag($0)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Divider()

            DateRangeRow(enabled: $dateRangeEnabled, startDate: $startDate, endDate: $endDate)

            Divider()

            HStack {
                Text("Album").foregroundStyle(.secondary)
                Picker("Album", selection: $selectedAlbumID) {
                    Text("All Albums").tag("")
                    if !library.albums.isEmpty {
                        Divider()
                        ForEach(library.albums, id: \.localIdentifier) { album in
                            Text(album.localizedTitle ?? "Untitled").tag(album.localIdentifier)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            if hasChanges {
                Label("Changing filters resets the current session.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    library.mediaFilter = selectedFilter
                    library.dateRangeEnabled = dateRangeEnabled
                    library.startDate = startDate
                    library.endDate = endDate
                    library.selectedAlbumID = selectedAlbumID
                    dismiss()
                    Task { await library.loadAssets() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!hasChanges)
            }
        }
        .padding(24)
        .frame(minWidth: 360)
        .onAppear {
            selectedFilter = library.mediaFilter
            dateRangeEnabled = library.dateRangeEnabled
            startDate = library.startDate
            endDate = library.endDate
            selectedAlbumID = library.selectedAlbumID
        }
    }
}
