import SwiftUI

/// Persistent status banner shown above the tabs whenever check-ins are saving in the background,
/// have failed and need a retry, or just finished. Collapses to zero height when empty.
struct CheckinQueueBanner: View {
    let queue: CheckinQueue
    @State private var confirmDiscardJob: PendingCheckin?
    @State private var confirmCancelJob: PendingCheckin?

    private var isVisible: Bool { !queue.jobs.isEmpty || queue.completedToast != nil }

    var body: some View {
        Group {
            if isVisible {
                VStack(spacing: 8) {
                    ForEach(queue.jobs) { job in
                        jobCard(job)
                    }
                    if let toast = queue.completedToast {
                        toastCard(toast)
                    }
                }
                .padding(.horizontal, Taproom.margin)
                .padding(.vertical, 8)
                .frame(maxWidth: .readableContentWidth)
                .frame(maxWidth: .infinity)
                .background(Taproom.background)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Taproom.border).frame(height: 1)
                }
                .accessibilityIdentifier("checkinQueue.banner")
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.85), value: queue.jobs)
        .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.85), value: queue.completedToast)
        .confirmationDialog(
            "Discard check-in?",
            isPresented: Binding(
                get: { confirmDiscardJob != nil },
                set: { if !$0 { confirmDiscardJob = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmDiscardJob
        ) { job in
            Button("Discard", role: .destructive) {
                queue.discard(job.id)
                confirmDiscardJob = nil
            }
            Button("Cancel", role: .cancel) {
                confirmDiscardJob = nil
            }
        } message: { job in
            Text("Your check-in for \(job.beerName) hasn't been saved yet.")
        }
        .confirmationDialog(
            "Cancel check-in?",
            isPresented: Binding(
                get: { confirmCancelJob != nil },
                set: { if !$0 { confirmCancelJob = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmCancelJob
        ) { job in
            Button("Cancel check-in", role: .destructive) {
                queue.cancel(job.id)
                confirmCancelJob = nil
            }
            Button("Keep waiting", role: .cancel) {
                confirmCancelJob = nil
            }
        } message: { job in
            Text("If \(job.beerName) already reached Untappd, it won't be deleted automatically.")
        }
    }

    @ViewBuilder
    private func jobCard(_ job: PendingCheckin) -> some View {
        switch job.phase {
        case .preparing, .submittingCheckin:
            activeRow(job.isEdit ? "Saving \(job.beerName)…" : "Checking in \(job.beerName)…", job: job)
        case .uploadingPhoto, .completingPhoto:
            activeRow("Uploading photo for \(job.beerName)…", job: job)
        case .failed(_, let message):
            failedCard(job, message: message)
        }
    }

    private func activeRow(_ text: String, job: PendingCheckin) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(Taproom.amber)
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Taproom.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                if job.phase == .submittingCheckin {
                    confirmCancelJob = job
                } else {
                    queue.cancel(job.id)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Taproom.muted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel \(job.beerName)")
            .accessibilityIdentifier("checkinQueue.cancel")
            .padding(.trailing, -10)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 48)
        .taproomCard(cornerRadius: 14)
        .accessibilityElement(children: .contain)
    }

    private func failedCard(_ job: PendingCheckin, message: String) -> some View {
        let title = job.checkinAlreadySaved
            ? "Photo failed for \(job.beerName)"
            : (job.isEdit ? "Couldn't save \(job.beerName)" : "Couldn't check in \(job.beerName)")

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(Taproom.destructive)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Taproom.ink)
                        .lineLimit(2)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Taproom.muted)
                        .lineLimit(3)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button("Retry") {
                    queue.retry(job.id)
                }
                .buttonStyle(TaproomPrimaryButton(compact: true))
                .accessibilityIdentifier("checkinQueue.retry")

                Button("Discard", role: .destructive) {
                    if job.checkinAlreadySaved {
                        queue.discard(job.id)
                    } else {
                        confirmDiscardJob = job
                    }
                }
                .buttonStyle(TaproomOutlineButton())
                .accessibilityIdentifier("checkinQueue.discard")
            }
        }
        .padding(14)
        .taproomCard(cornerRadius: 14)
    }

    private func toastCard(_ toast: CheckinCompletedToast) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
                .foregroundStyle(Taproom.had)
                .accessibilityHidden(true)
            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Taproom.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .taproomCard(cornerRadius: 14)
        .accessibilityElement(children: .combine)
    }
}
