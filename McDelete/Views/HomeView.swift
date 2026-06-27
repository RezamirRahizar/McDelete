import SwiftUI
import Photos

struct HomeView: View {
    @Environment(PhotoLibrary.self) private var library
    let onStartReview: () -> Void

    @State private var showReviewedMedia = false
    @State private var deletionFailed = false
    @Namespace private var statsNamespace

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Color.accentColor.opacity(0.14), Color.clear],
                center: UnitPoint(x: 0.5, y: 0.22),
                startRadius: 0,
                endRadius: 320
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                heroSection
                    .padding(.bottom, 44)

                if library.keptCount > 0 || library.pendingDeletion.count > 0 {
                    statsSection
                        .padding(.bottom, 40)
                }

                Button(action: handleStart) {
                    Text(ctaTitle)
                        .font(.title3.weight(.semibold))
                        .frame(minWidth: 260)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .disabled(library.isDeleting)

                secondarySection
                    .padding(.top, 12)

                Spacer()
            }
            .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showReviewedMedia) {
            ReviewedMediaView()
        }
        .alert("Couldn't delete items", isPresented: $deletionFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The deletion was cancelled or failed. Your photos are unchanged.")
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 116, height: 116)
                    .blur(radius: 24)

                Image(systemName: "rectangle.stack.badge.minus")
                    .font(.system(size: 62, weight: .medium))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
            }

            VStack(spacing: 5) {
                Text("McDelete")
                    .font(.system(size: 30, weight: .bold, design: .rounded))

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 14) {
                if library.keptCount > 0 {
                    statCard(library.keptCount, label: "Kept",
                             icon: "checkmark.circle.fill", color: .green)
                        .glassEffectID("kept", in: statsNamespace)
                }
                if library.pendingDeletion.count > 0 {
                    statCard(library.pendingDeletion.count, label: "To Delete",
                             icon: "trash.fill", color: .red)
                        .glassEffectID("delete", in: statsNamespace)
                }
            }
        }
    }

    private func statCard(_ count: Int, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
            Text("\(count)")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 100)
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .glassEffect(in: .rect(cornerRadius: 20))
    }

    // MARK: - Secondary actions

    private var secondarySection: some View {
        VStack(spacing: 8) {
            if library.pendingDeletion.count > 0 {
                Button {
                    Task {
                        let ok = await library.confirmDeletions()
                        deletionFailed = !ok
                    }
                } label: {
                    Label(deleteTitle, systemImage: "trash.fill")
                        .frame(minWidth: 260)
                }
                .buttonStyle(.glass)
                .tint(.red)
                .controlSize(.large)
                .disabled(library.isDeleting)
            }

            if library.keptCount > 0 || library.pendingDeletion.count > 0 {
                Button { showReviewedMedia = true } label: {
                    Label("View Reviewed Media", systemImage: "photo.stack")
                        .frame(minWidth: 260)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }

            if library.isDeleting {
                ProgressView().padding(.top, 4)
            }
        }
    }

    // MARK: - Computed

    private var subtitle: String {
        guard library.hasStarted else {
            return "Swipe right to keep · left to delete"
        }
        if library.isFinished {
            return library.pendingDeletion.isEmpty ? "All caught up!" : "Ready to clean up."
        }
        return "Swipe right to keep · left to delete"
    }

    private var ctaTitle: String {
        guard library.hasStarted else { return "Start Review" }
        if library.isFinished { return "Review Again" }
        let remaining = library.totalCount - library.reviewedCount
        return "Resume · \(remaining) left"
    }

    private var deleteTitle: String {
        let count = library.pendingDeletion.count
        let base = "Delete \(count) item\(count == 1 ? "" : "s")"
        return library.pendingDeletionBytes > 0 ? "\(base) · \(library.pendingDeletionSize)" : base
    }

    private func handleStart() {
        if library.isFinished {
            Task {
                await library.resetAndLoadAssets()
                onStartReview()
            }
        } else {
            onStartReview()
        }
    }
}
