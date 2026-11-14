import SwiftUI
import PhotosUI

/// The full-screen check-in (and edit checkin) view: rate by filling the glass, add a photo,
/// pick a serving style and venue, and tag friends.
struct CheckInSheet: View {
    let beer: BeerLite?
    /// The user's own checkin being edited; nil when making a new one.
    let editing: Checkin?
    @State var venue: Venue?
    @Environment(\.dismiss) private var dismiss
    @Environment(LocationProvider.self) private var location
    @State private var options = CheckInOptions.shared
    @State private var rating: Double = 0
    @State private var shout = ""
    @State private var serving: ServingType?
    @State private var tagged: [User] = []
    @State private var photo: UIImage?
    @State private var libraryItem: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var showingVenuePicker = false
    /// A venue shown as a chip although it isn't a recent one: the one you're at, or one picked
    /// from the full list.
    @State private var extraVenue: Venue?
    @State private var busy = false
    /// Set once the checkin is saved but something after it (the photo upload) failed.
    @State private var finished = false
    @State private var error: String?
    @State private var preselectedServing = false

    init(beer: BeerLite, venue: Venue?) {
        self.beer = beer
        editing = nil
        let v = venue?.foursquareId != nil ? venue : nil
        _venue = State(initialValue: v)
        _extraVenue = State(initialValue: v)
    }

    /// Edits the rating, comment, serving type and photo of one of the user's checkins.
    init(editing checkin: Checkin) {
        beer = checkin.beerLite
        editing = checkin
        _venue = State(initialValue: nil)
        _rating = State(initialValue: checkin.rating ?? 0)
        _shout = State(initialValue: checkin.comment ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                    hero
                    comment
                    TaproomSection("Serving") { servingChips }
                    if editing == nil {
                        TaproomSection("Where") { venueChips }
                        friends
                    }
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, Taproom.margin)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .foregroundStyle(Taproom.ink)
            .background(Taproom.background)
            .safeAreaInset(edge: .bottom) { submitButton }
            .navigationTitle(editing == nil ? "Check in" : "Edit checkin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Taproom.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                        .disabled(busy)
                }
            }
            .navigationDestination(isPresented: $showingVenuePicker) { VenuePicker(selection: pickedVenue) }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraPicker { photo = $0 }.ignoresSafeArea()
            }
            .onChange(of: libraryItem) { _, item in loadLibraryPhoto(item) }
            .interactiveDismissDisabled(busy)
            .task { await options.loadServingTypes() }
            .task { if editing == nil { await options.loadFriends() } }
            .onChange(of: options.servingTypes, initial: true) { preselectServing() }
        }
        .tint(Taproom.amber)
    }

    // MARK: Sections

    private var hero: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                if let beer {
                    Text(beer.brewery).font(.subheadline).foregroundStyle(Taproom.muted).lineLimit(1)
                    Text(beer.name)
                        .font(.system(size: 26, weight: .heavy))
                        .tracking(-0.4)
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                        .padding(.top, 2)
                    let meta = [beer.style, beer.abv.map { "\($0.formatted(.number.precision(.fractionLength(0...1))))%" }]
                        .compactMap { $0 }.joined(separator: " · ")
                    if !meta.isEmpty {
                        Text(meta).font(.footnote).foregroundStyle(Taproom.muted).lineLimit(2).padding(.top, 4)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(GlassRating.format(rating, step: options.ratingStep))
                        .font(.system(size: 64, weight: .heavy).monospacedDigit())
                        .foregroundStyle(rating == 0 ? Taproom.glassRim : Taproom.ink)
                        .tracking(-1.5)
                        .contentTransition(.numericText(value: rating))
                    Text("/ 5").font(.body.weight(.medium)).foregroundStyle(Taproom.muted)
                }
                .padding(.top, 14)
                .accessibilityHidden(true)
                Label(rating == 0 ? "Slide the glass to rate" : "Slide the glass up or down", systemImage: "arrow.right")
                    .labelStyle(TaproomTrailingIconLabel())
                    .font(.caption)
                    .foregroundStyle(Taproom.muted)
                    .accessibilityHidden(true)
                Spacer(minLength: 14)
                photoControls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            GlassRating(rating: $rating, step: options.ratingStep)
                .frame(width: 112)
                .frame(minHeight: 262)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var photoControls: some View {
        if let photo {
            HStack(spacing: 10) {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                Text("Photo added").font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
                Button {
                    self.photo = nil
                    libraryItem = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(Taproom.muted)
                }
                .accessibilityLabel("Remove photo")
            }
        } else {
            HStack(spacing: 8) {
                Button { showingCamera = true } label: { Label("Camera", systemImage: "camera") }
                    .buttonStyle(TaproomOutlineButton())
                    .disabled(!CameraPicker.isAvailable)
                PhotosPicker(selection: $libraryItem, matching: .images) {
                    Label("Photos", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(TaproomOutlineButton())
            }
        }
    }

    private var comment: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("What did you think?", text: $shout, axis: .vertical)
                .lineLimit(2...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .taproomCard()
            if editing?.comment != nil {
                Text("Untappd keeps the existing comment if you leave this empty.")
                    .font(.caption).foregroundStyle(Taproom.muted)
            }
        }
    }

    private var servingChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if options.servingTypes.isEmpty {
                    ProgressView().frame(height: 34)
                }
                ForEach(options.servingTypes) { t in
                    let on = serving?.id == t.id
                    Button { serving = on ? nil : t } label: {
                        HStack(spacing: 5) {
                            ServingIcon(name: t.name, size: 16, color: on ? Taproom.onAmber : Taproom.amber)
                            Text(t.name)
                        }
                    }
                    .buttonStyle(TaproomChip(on: on))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.vertical, 1)
        }
        .scrollClipDisabled()
    }

    private var venueChips: some View {
        FlowLayout(spacing: 6) {
            ForEach(chipVenues) { v in
                let on = venue?.id == v.id
                Button { venue = on ? nil : v } label: {
                    HStack(spacing: 5) {
                        if v.id == Venue.atHome.id {
                            Image(systemName: "house.fill").font(.caption2)
                        }
                        Text(v.name).lineLimit(1).frame(maxWidth: 200)
                    }
                }
                .buttonStyle(TaproomChip(on: on))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Button { showingVenuePicker = true } label: {
                Image(systemName: "ellipsis").frame(width: 20)
            }
            .buttonStyle(TaproomChip(on: false))
            .accessibilityLabel("All venues")
        }
    }

    private var friends: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("With").font(Taproom.sectionLabel)
            FlowLayout(spacing: 6) {
                ForEach(tagged) { u in
                    Button { tagged.removeAll { $0.id == u.id } } label: {
                        HStack(spacing: 6) {
                            Avatar(url: u.avatar, size: 24)
                            Text(u.shortName).lineLimit(1)
                        }
                    }
                    .buttonStyle(TaproomChip(on: false, leading: 4))
                    .accessibilityLabel(u.shortName)
                    .accessibilityHint("Removes the tag")
                }
                NavigationLink {
                    FriendPicker(selected: $tagged)
                } label: {
                    Text(tagged.isEmpty ? "+ Tag friends" : "+ Tag")
                }
                .buttonStyle(TaproomChip(on: false, dashed: true))
            }
        }
    }

    private var submitButton: some View {
        Button(action: finished ? { dismiss() } : submit) {
            if busy {
                ProgressView().tint(Taproom.background)
            } else {
                Text(finished ? "Done" : editing == nil ? "Check in" : "Save")
            }
        }
        .buttonStyle(TaproomPrimaryButton())
        .disabled(busy)
        .taproomBottomBar()
    }

    // MARK: Venues

    /// Untappd at Home, then the venue you're at or picked, then your recent venues.
    private var chipVenues: [Venue] {
        var out: [Venue] = [.atHome]
        for v in [extraVenue].compactMap({ $0 }) + options.recentVenues where !out.contains(where: { $0.id == v.id }) {
            out.append(v)
        }
        return out
    }

    /// The full picker's selection; a venue that isn't already a chip becomes one.
    private var pickedVenue: Binding<Venue?> {
        Binding(get: { venue }, set: { v in
            venue = v
            if let v, !chipVenues.contains(where: { $0.id == v.id }) { extraVenue = v }
        })
    }

    // MARK: Actions

    private func loadLibraryPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                photo = img
            } else {
                error = "Couldn't load that photo."
            }
        }
    }

    /// Selects the edited checkin's serving type once the list of types has loaded.
    private func preselectServing() {
        guard !preselectedServing, let name = editing?.servingType else { return }
        guard let match = options.servingTypes.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { return }
        serving = match
        preselectedServing = true
    }

    private func submit() {
        busy = true
        error = nil
        let image = photo
        Task {
            defer { busy = false }
            let jpeg: Data? = if let image { await Task.detached { CheckinPhoto.jpeg(image) }.value } else { nil }
            if let editing {
                await save(editing, jpeg: jpeg)
            } else {
                await add(jpeg: jpeg)
            }
        }
    }

    private func add(jpeg: Data?) async {
        guard let beer else { return }
        let loc = location.location
        let req = APIRequest.checkin(beer: beer.bid, foursquareId: venue?.foursquareId,
                                     lat: loc?.coordinate.latitude, lng: loc?.coordinate.longitude,
                                     rating: rating, shout: shout, containerId: serving?.id,
                                     taggedUserIds: tagged.map(\.id), isPhoto: jpeg != nil)
        let r: CheckinAddResponse
        do {
            r = try await UntappdAPI.shared.fetch(req, as: CheckinAddResponse.self)
        } catch {
            self.error = error.localizedDescription
            return
        }
        let uploaded = await upload(jpeg, r)
        NotificationCenter.default.post(name: .didCheckIn, object: nil)
        if uploaded { dismiss() }
    }

    private func save(_ original: Checkin, jpeg: Data?) async {
        let trimmed = shout.trimmingCharacters(in: .whitespacesAndNewlines)
        let req = APIRequest.editCheckin(original, rating: rating, shout: trimmed, containerId: serving?.id,
                                         isPhoto: jpeg != nil)
        let r: CheckinAddResponse
        do {
            r = try await UntappdAPI.shared.fetch(req, as: CheckinAddResponse.self)
        } catch {
            self.error = error.localizedDescription
            return
        }
        let uploaded = await upload(jpeg, r)
        var updated = original
        updated.rating = rating > 0 ? rating : nil
        // Untappd leaves the comment alone when it's sent empty.
        updated.comment = trimmed.isEmpty ? original.comment : trimmed
        updated.servingType = serving?.name ?? original.servingType
        if jpeg != nil, uploaded, let d = r.photoDestinationURL {
            updated.photo = Checkin.Photo(small: d, medium: d, large: d)
        }
        NotificationCenter.default.post(name: .checkinEdited, object: updated)
        if uploaded { dismiss() }
    }

    /// Uploads the photo, if there is one, to where the checkin response said. Returns false
    /// (leaving the screen up with an error) if that fails: the checkin itself is already saved.
    private func upload(_ jpeg: Data?, _ r: CheckinAddResponse) async -> Bool {
        guard let jpeg else { return true }
        do {
            guard let url = r.photoUploadURL else { throw APIError.decoding }
            try await UntappdAPI.shared.uploadPhoto(jpeg, to: url)
            return true
        } catch {
            self.error = "Your checkin was saved, but the photo couldn't be uploaded."
            finished = true
            return false
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
