import SwiftUI

/// Picks a start and end date for the Statistics screen. Two chips show the dates; the one
/// that's on drives a graphical calendar below. The start can't pass the end (moving it past
/// pulls the end along) and neither can leave `earliest`...`latest`.
struct StatsRangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date
    @State private var editing = Field.start
    let earliest: Date
    let latest: Date
    let onDone: (Date, Date) -> Void

    private enum Field { case start, end }

    init(start: Date, end: Date, earliest: Date, latest: Date, onDone: @escaping (Date, Date) -> Void) {
        let cal = Calendar.current
        let hi = cal.startOfDay(for: latest)
        let lo = min(cal.startOfDay(for: earliest), hi)
        let clampedStart = min(max(cal.startOfDay(for: start), lo), hi)
        let clampedEnd = min(max(cal.startOfDay(for: end), clampedStart), hi)
        _start = State(initialValue: clampedStart)
        _end = State(initialValue: clampedEnd)
        self.earliest = earliest
        self.latest = latest
        self.onDone = onDone
    }

    private var hi: Date { Calendar.current.startOfDay(for: latest) }
    private var lo: Date { min(Calendar.current.startOfDay(for: earliest), hi) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                    HStack(spacing: 8) {
                        fieldChip("From", date: start, field: .start)
                        fieldChip("To", date: end, field: .end)
                    }
                    DatePicker("", selection: editing == .start ? startBinding : endBinding,
                               in: editing == .start ? lo...hi : min(start, hi)...hi, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .tint(Taproom.amber)
                        .labelsHidden()
                        .padding(8)
                        .taproomCard()
                        .id(editing)
                    Text("From your first check-in to today. A range of up to about two months shows days, up to three years months, longer years.")
                        .font(.caption).foregroundStyle(Taproom.muted)
                }
                .padding(.horizontal, Taproom.margin)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: .readableContentWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .taproomScreen()
            .navigationTitle("Date range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Taproom.background, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Button("Cancel") { dismiss() }.buttonStyle(TaproomOutlineButton())
                    Button("Done") { onDone(start, end); dismiss() }.buttonStyle(TaproomPrimaryButton(compact: true))
                }
                .taproomBottomBar()
            }
        }
    }

    private var startBinding: Binding<Date> {
        Binding(get: { start }, set: {
            let d = min(max(Calendar.current.startOfDay(for: $0), lo), hi)
            start = d
            if end < d { end = d }
        })
    }
    private var endBinding: Binding<Date> {
        Binding(get: { end }, set: {
            end = min(max(Calendar.current.startOfDay(for: $0), start), hi)
        })
    }

    private func fieldChip(_ title: String, date: Date, field: Field) -> some View {
        let on = editing == field
        return Button { editing = field } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                    .foregroundStyle(on ? Taproom.onAmber : Taproom.muted)
                Text(date.formatted(.dateTime.day().month(.abbreviated).year()))
                    .font(.body.weight(.heavy))
                    .foregroundStyle(on ? Taproom.onAmber : Taproom.ink)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(on ? Taproom.amber : Taproom.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(on ? Taproom.amber : Taproom.border, lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(date.formatted(date: .long, time: .omitted))")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
