import SwiftUI

struct CheckInSheet: View {
    let beer: BeerLite
    @State var venue: Venue?
    @Environment(\.dismiss) private var dismiss
    @Environment(LocationProvider.self) private var location
    @Environment(DiscoverModel.self) private var discover
    @State private var options = CheckInOptions.shared
    @State private var rating: Double = 0
    @State private var shout = ""
    @State private var serving: ServingType?
    @State private var tagged: [User] = []
    @State private var busy = false
    @State private var error: String?

    init(beer: BeerLite, venue: Venue?) {
        self.beer = beer
        _venue = State(initialValue: venue?.foursquareId != nil ? venue : nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    BeerRow(beer: beer)
                }
                Section("Rating") {
                    HStack {
                        Slider(value: $rating, in: 0...5, step: 0.25)
                        Text(rating == 0 ? "None" : rating.formatted(.number.precision(.fractionLength(2))))
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                Section {
                    TextField("What did you think?", text: $shout, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section("Serving") {
                    servingPicker
                }
                Section("Where") {
                    Picker("Venue", selection: $venue) {
                        Text("No venue").tag(Venue?.none)
                        ForEach(venueChoices) { v in Text(v.name).tag(Optional(v)) }
                    }
                }
                Section("Friends") {
                    if !tagged.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(tagged) { u in
                                Button { tagged.removeAll { $0.id == u.id } } label: { UserChip(user: u) }
                                    .buttonStyle(.plain)
                                    .accessibilityHint("Removes the tag")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    NavigationLink {
                        FriendPicker(selected: $tagged)
                    } label: {
                        Label(tagged.isEmpty ? "Tag friends" : "Edit tagged friends", systemImage: "person.badge.plus")
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("Check in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else { Button("Check in", action: submit).bold() }
                }
            }
            .interactiveDismissDisabled(busy)
            .task { await options.loadServingTypes() }
            .task { await options.loadFriends() }
        }
        .presentationDetents([.large])
    }

    private var servingPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if options.servingTypes.isEmpty {
                    ProgressView().frame(height: 64)
                }
                ForEach(options.servingTypes) { t in
                    let on = serving?.id == t.id
                    Button { serving = on ? nil : t } label: {
                        VStack(spacing: 4) {
                            ServingIcon(name: t.name, size: 26)
                                .frame(width: 32, height: 32)
                            Text(t.name).font(.caption2).lineLimit(1)
                        }
                        .frame(minWidth: 60, minHeight: 60)
                        .padding(.horizontal, 4)
                        .background(on ? Color.orange.opacity(0.18) : Color(.tertiarySystemFill),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Color.orange : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }

    private var venueChoices: [Venue] {
        var vs = discover.checkInVenues
        if let venue, venue.foursquareId != nil, !vs.contains(where: { $0.id == venue.id }) {
            vs.insert(venue, at: vs.first?.isCustom == true ? 1 : 0)
        }
        return vs
    }

    private func submit() {
        busy = true
        error = nil
        let loc = location.location
        let req = APIRequest.checkin(beer: beer.bid, foursquareId: venue?.foursquareId,
                                     lat: loc?.coordinate.latitude, lng: loc?.coordinate.longitude,
                                     rating: rating, shout: shout,
                                     containerId: serving?.id, taggedUserIds: tagged.map(\.id))
        Task {
            defer { busy = false }
            do {
                _ = try await UntappdAPI.shared.fetch(req, as: CheckinAddResponse.self)
                NotificationCenter.default.post(name: .didCheckIn, object: nil)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct FriendPicker: View {
    @Binding var selected: [User]
    @State private var options = CheckInOptions.shared
    @State private var filter = ""

    var body: some View {
        let recentIds = Set(options.recentlyTagged.map(\.id))
        let all = options.orderedFriends.filter {
            filter.isEmpty || LocalIndex.matches(query: filter, text: "\($0.displayName) \($0.userName)")
        }
        let recent = all.filter { recentIds.contains($0.id) }
        let rest = all.filter { !recentIds.contains($0.id) }
        List {
            if !recent.isEmpty {
                Section("Recently tagged") { ForEach(recent) { row($0) } }
            }
            Section(recent.isEmpty ? "Friends" : "All friends") {
                ForEach(rest) { row($0) }
                if options.loadingFriends && options.friends.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        }
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search friends")
        .navigationTitle(selected.isEmpty ? "Tag friends" : "\(selected.count) tagged")
        .navigationBarTitleDisplayMode(.inline)
        .task { await options.loadFriends() }
    }

    private func row(_ u: User) -> some View {
        let on = selected.contains { $0.id == u.id }
        return Button {
            if on { selected.removeAll { $0.id == u.id } } else { selected.append(u) }
        } label: {
            HStack(spacing: 12) {
                Avatar(url: u.avatar, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(u.displayName).foregroundStyle(.primary)
                    Text("@\(u.userName)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(on ? Color.orange : Color(.tertiaryLabel))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
