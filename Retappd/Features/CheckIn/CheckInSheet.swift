import SwiftUI
import PhotosUI
import Photos

/// The full-screen check-in (and edit checkin) view: rate by filling the glass, add a photo,
/// pick a serving style, venue and the shop you bought it at, and tag friends.
struct CheckInSheet: View {
    let beer: BeerLite?
    /// The user's own checkin being edited; nil when making a new one.
    let editing: Checkin?
    /// A check-in saved for later that this finishes; removed from the list once it's posted.
    let pending: PendingCheckin?
    @State var venue: Venue?
    @Environment(\.dismiss) private var dismiss
    @Environment(LocationProvider.self) private var location
    @Environment(DiscoverModel.self) private var discover
    @State private var options = CheckInOptions.shared
    @State private var connectivity = Connectivity.shared
    @State private var rating: Double = 0
    @State private var prefillPour = 0
    @State private var userTouchedRating = false
    @State private var shout = ""
    @State private var serving: ServingType?
    @State private var tagged: [User] = []
    /// The flavours picked for this checkin.
    @State private var flavors: [FlavorTag] = []
    /// The flavours people tag this beer with most, most used first.
    @State private var beerFlavors: [FlavorTag] = []
    @State private var photo: UIImage?
    @State private var photoLoadTask: Task<Void, Never>?
    @State private var editingPhoto = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var showingVenuePicker = false
    /// A venue shown as a chip although it isn't a recent one: the one you're at, or one picked
    /// from the full list.
    @State private var extraVenue: Venue?
    /// Where the beer was bought ("Purchased at" in the official app).
    @State private var shop: Venue?
    /// A shop shown as a chip although it isn't a recent one: the edited checkin's, or one picked.
    @State private var extraShop: Venue?
    @State private var showingShopPicker = false
    /// Whether `shop` holds the edited checkin's real shop yet. Saving an edit without sending the
    /// shop back removes it, so it's looked up first if the checkin came without one.
    @State private var shopLoaded = true
    @State private var busy = false
    @State private var submitted = false
    @State private var error: String?
    @State private var preselectedServing = false

    init(beer: BeerLite, venue: Venue?) {
        self.beer = beer
        editing = nil
        pending = nil
        let v = venue?.foursquareId != nil ? venue : nil
        _venue = State(initialValue: v)
        _extraVenue = State(initialValue: v)
    }

    /// Edits the rating, comment, serving type and photo of one of the user's checkins.
    init(editing checkin: Checkin) {
        beer = checkin.beerLite
        editing = checkin
        pending = nil
        _venue = State(initialValue: nil)
        _rating = State(initialValue: checkin.rating ?? 0)
        _shout = State(initialValue: checkin.comment ?? "")
        _shop = State(initialValue: checkin.retailVenue)
        _extraShop = State(initialValue: checkin.retailVenue)
        // A shop without a Foursquare id couldn't be sent back, so look it up properly.
        _shopLoaded = State(initialValue: checkin.retailVenueKnown && checkin.retailVenue.map { $0.foursquareId != nil } ?? true)
    }

    /// Finishes a check-in saved for later, as `beer` (the saved one, or one found for a saved
    /// search): what was filled in comes back, and it's posted from where it was saved.
    init(pending item: PendingCheckin, beer: BeerLite) {
        self.beer = beer
        editing = nil
        pending = item
        _venue = State(initialValue: item.venue)
        _extraVenue = State(initialValue: item.venue)
        _rating = State(initialValue: item.rating)
        _shout = State(initialValue: item.shout)
        _photo = State(initialValue: PendingCheckins.shared.photo(for: item).flatMap(UIImage.init(data:)))
    }

    #if DEBUG
    init(demoBeer: BeerLite, venue: Venue?, rating: Double, shout: String,
         serving: ServingType?, flavors: [FlavorTag], photo: UIImage?) {
        self.beer = demoBeer
        editing = nil
        pending = nil
        _venue = State(initialValue: venue)
        _extraVenue = State(initialValue: venue)
        _rating = State(initialValue: rating)
        _userTouchedRating = State(initialValue: true)
        _shout = State(initialValue: shout)
        _serving = State(initialValue: serving)
        _preselectedServing = State(initialValue: serving != nil)
        _flavors = State(initialValue: flavors)
        _photo = State(initialValue: photo)
    }
    #endif

    /// Untappd hides check-ins that give their own time from friends' feeds, so a late one is
    /// posted now, and its shout starts "LCI" (late check-in) once it's more than this late.
    static let lateCheckInGrace: TimeInterval = 60 * 60

    /// The shout to post for a check-in saved at `savedAt`: "LCI" and a newline in front once
    /// it's past the grace period (and not already there).
    static func lateShout(_ shout: String, savedAt: Date?, now: Date = .now) -> String {
        guard let savedAt, now.timeIntervalSince(savedAt) > lateCheckInGrace else { return shout }
        if shout == "LCI" || shout.hasPrefix("LCI\n") { return shout }
        return shout.isEmpty ? "LCI" : "LCI\n" + shout
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                    if let pending { savedLine(pending) }
                    hero
                    comment
                    // The official app's order: serving, friends, venue, flavours, shop.
                    TaproomSection("Serving") { servingChips }
                    if editing == nil {
                        TaproomSection("With") { friendChips }
                        TaproomSection("Where") { venueChips }
                        TaproomSection("Flavours") { flavorChips }
                    }
                    TaproomSection("Purchased at") { shopChips }
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, Taproom.margin)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .frame(maxWidth: .readableContentWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
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
                ToolbarItem(placement: .primaryAction) {
                    TaproomOfflineSwitch().disabled(busy)
                }
            }
            .beerAndBreweryDestinations()
            .modifier(CheckinDestinations(enabled: true, me: discover.me))
            .navigationDestination(isPresented: $showingVenuePicker) { VenuePicker(selection: pickedVenue) }
            .navigationDestination(isPresented: $showingShopPicker) { VenuePicker(selection: pickedShop, kind: .shop) }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraPicker {
                    photoLoadTask?.cancel()
                    photoLoadTask = nil
                    error = nil
                    photo = $0
                }.ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $editingPhoto) {
                if let current = photo { PhotoEditor(image: current) { photo = $0 } }
            }
            .onChange(of: libraryItem) { _, item in loadLibraryPhoto(item) }
            .interactiveDismissDisabled(busy)
            .task { await options.loadServingTypes() }
            .task {
                #if DEBUG
                if ScreenshotDemo.isEnabled { return }
                #endif
                if editing == nil { location.start() }
            }
            .task { if editing == nil { await options.loadFriends() } }
            .task { await loadEditedShop() }
            .task { await prefillRating() }
            .task { await loadBeerFlavors() }
            .onChange(of: options.servingTypes, initial: true) { preselectServing() }
        }
        .environment(\.beerPageCanCheckIn, false)
        .tint(Taproom.amber)
    }

    // MARK: Sections

    private func savedLine(_ item: PendingCheckin) -> some View {
        Label {
            Text("Saved \(item.savedAt.formatted(.relative(presentation: .named))), \(item.savedAt.formatted(date: .omitted, time: .shortened))")
        } icon: {
            Image(systemName: "bookmark.fill").foregroundStyle(Taproom.amber)
        }
        .font(.footnote)
        .foregroundStyle(Taproom.muted)
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                if let beer { beerHeader(beer) }
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
            GlassRating(
                rating: $rating,
                step: options.ratingStep,
                pourTrigger: prefillPour,
                onUserInteraction: { userTouchedRating = true }
            )
            .frame(width: 112)
            .frame(minHeight: 262)
            .accessibilityIdentifier("checkIn.glassRating")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The brewery, beer name and style, each opening its page in this sheet's own navigation
    /// stack, so the rating, comment and photo are still here when you come back.
    private func beerHeader(_ beer: BeerLite) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let route = BeerBreweryRoute.brewery(of: beer), !beer.brewery.isEmpty {
                NavigationLink(value: route) {
                    TaproomLinkLabel(beer.brewery, font: .subheadline, chevronSize: 10)
                        .foregroundStyle(Taproom.muted)
                }
                .buttonStyle(TaproomLinkStyle())
                .accessibilityHint("Opens the brewery's page")
                .accessibilityAddTraits(.isLink)
            } else {
                Text(beer.brewery).font(.subheadline).foregroundStyle(Taproom.muted).lineLimit(1)
            }
            NavigationLink(value: BeerBreweryRoute.beer(beer)) {
                TaproomLinkLabel(beer.name, font: .system(size: 26, weight: .heavy), chevronSize: 15, tracking: -0.4,
                                 lineLimit: 3, minimumScaleFactor: 0.7)
            }
            .buttonStyle(TaproomLinkStyle())
            .padding(.top, 2)
            .accessibilityHint("Opens the beer's page")
            .accessibilityAddTraits(.isLink)
            let meta = [beer.style, beer.abv.map { "\($0.formatted(.number.precision(.fractionLength(0...1))))%" }]
                .compactMap { $0 }.joined(separator: " · ")
            if !meta.isEmpty {
                NavigationLink(value: BeerBreweryRoute.beer(beer)) {
                    TaproomLinkLabel(meta, font: .footnote, lineLimit: 2, showsChevron: false)
                        .foregroundStyle(Taproom.muted)
                }
                .buttonStyle(TaproomLinkStyle(extend: 6))
                .padding(.top, 4)
                .accessibilityHint("Opens the beer's page")
                .accessibilityAddTraits(.isLink)
            }
        }
    }

    @ViewBuilder private var photoControls: some View {
        if let photo {
            HStack(spacing: 10) {
                Button { editingPhoto = true } label: {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .accessibilityLabel("Edit photo")
                Text("Photo added").font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
                Button {
                    photoLoadTask?.cancel()
                    photoLoadTask = nil
                    error = nil
                    self.photo = nil
                    libraryItem = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(Taproom.muted)
                }
                .accessibilityLabel("Remove photo")
            }
        } else {
            TaproomButtonRow(spacing: 8) {
                Button { showingCamera = true } label: { photoButtonLabel("Camera", systemImage: "camera") }
                    .buttonStyle(TaproomOutlineButton())
                    .disabled(!CameraPicker.isAvailable)
                Button { useLastPhoto() } label: { photoButtonLabel("Last", systemImage: "clock.arrow.circlepath") }
                    .buttonStyle(TaproomOutlineButton())
                PhotosPicker(selection: $libraryItem, matching: .images) {
                    Image(systemName: "photo.on.rectangle")
                }
                .buttonStyle(TaproomOutlineButton())
                .frame(width: 44)
                .fixedInButtonRow()
                .accessibilityLabel("Photos")
            }
        }
    }

    /// A photo button's label: icon and title, or just the icon when the row is too narrow for the
    /// title (large Dynamic Type), rather than a truncated "Ca…".
    private func photoButtonLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        ViewThatFits(in: .horizontal) {
            Label(title, systemImage: systemImage).lineLimit(1).padding(.horizontal, 4)
            Image(systemName: systemImage)
        }
        .accessibilityLabel(Text(title))
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

    /// The serving styles that suit this drink: a spirit gets Neat, Rocks and so on, not Draft.
    private var servingChoices: [ServingType] {
        ServingType.choices(forStyle: beer?.style, beerTypes: options.servingTypes)
    }

    private var servingChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if servingChoices.isEmpty {
                    ProgressView().frame(height: 34)
                }
                ForEach(servingChoices) { t in
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
            .padding(.horizontal, Taproom.margin)
            .padding(.vertical, 1)
        }
        .padding(.horizontal, -Taproom.margin)
        .clipped()
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

    private var shopChips: some View {
        FlowLayout(spacing: 6) {
            ForEach(chipShops) { v in
                let on = shop?.id == v.id
                Button { shop = on ? nil : v; shopLoaded = true } label: {
                    Text(v.name).lineLimit(1).frame(maxWidth: 200)
                }
                .buttonStyle(TaproomChip(on: on))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            if chipShops.isEmpty {
                Button { showingShopPicker = true } label: { Text("+ Add shop") }
                    .buttonStyle(TaproomChip(on: false, dashed: true))
                    .disabled(!shopLoaded)
            } else {
                Button { showingShopPicker = true } label: {
                    Image(systemName: "ellipsis").frame(width: 20)
                }
                .buttonStyle(TaproomChip(on: false))
                .accessibilityLabel("All shops")
            }
        }
    }

    /// Friends you're likely to tag as one-tap chips (recently tagged, then friends checking in
    /// nearby), then anyone else you tagged from the full list, then "…" for the full list. Chips
    /// stay put when tapped; they just turn amber.
    private var friendChips: some View {
        let suggested = options.suggestedFriends(nearby: discover.nearbyFriends)
        let others = tagged.filter { t in !suggested.contains { $0.id == t.id } }
        return FlowLayout(spacing: 6) {
            ForEach(suggested + others) { u in
                let on = tagged.contains { $0.id == u.id }
                Button {
                    if on { tagged.removeAll { $0.id == u.id } } else { tagged.append(u) }
                } label: {
                    HStack(spacing: 6) {
                        if on { Avatar(url: u.avatar, size: 24) } else { Image(systemName: "plus").font(.caption.weight(.semibold)) }
                        Text(u.shortName).lineLimit(1).frame(maxWidth: 160)
                    }
                }
                .buttonStyle(TaproomChip(on: on, leading: on ? 4 : 12))
                .accessibilityLabel(u.shortName)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityHint(on ? "Removes the tag" : "Tags them")
            }
            if suggested.isEmpty && options.loadingFriends {
                ProgressView().frame(height: 34)
            }
            NavigationLink {
                FriendPicker(selected: $tagged)
            } label: {
                if suggested.isEmpty && others.isEmpty {
                    Text("+ Tag friends")
                } else {
                    Image(systemName: "ellipsis").frame(width: 20)
                }
            }
            .buttonStyle(TaproomChip(on: false, dashed: suggested.isEmpty && others.isEmpty))
            .accessibilityLabel("All friends")
        }
    }

    /// The flavours people tag this beer with most, then any others you picked, then "…" for
    /// every flavour.
    private var flavorChips: some View {
        let common = Array(beerFlavors.prefix(6))
        let others = flavors.filter { f in !common.contains { $0.id == f.id } }
        return FlowLayout(spacing: 6) {
            ForEach(common + others) { f in
                let on = flavors.contains { $0.id == f.id }
                Button {
                    if on { flavors.removeAll { $0.id == f.id } } else { flavors.append(f) }
                } label: {
                    HStack(spacing: 5) {
                        if !on { Image(systemName: "plus").font(.caption.weight(.semibold)) }
                        Text(f.name).lineLimit(1)
                    }
                }
                .buttonStyle(TaproomChip(on: on))
                .accessibilityLabel(f.name)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            NavigationLink {
                FlavorPicker(selected: $flavors, common: beerFlavors)
            } label: {
                if common.isEmpty && others.isEmpty {
                    Text("+ Add flavours")
                } else {
                    Image(systemName: "ellipsis").frame(width: 20)
                }
            }
            .buttonStyle(TaproomChip(on: false, dashed: common.isEmpty && others.isEmpty))
            .accessibilityLabel("All flavours")
        }
    }

    private var submitButton: some View {
        let offline = connectivity.offlineMode
        // A new check-in can be saved for later; an edit has to wait for the network.
        let savesForLater = offline && editing == nil
        return VStack(spacing: 8) {
            if savesForLater {
                Text("You're offline. This is saved on your phone with the time and roughly where you are.")
                    .font(.caption)
                    .foregroundStyle(Taproom.muted)
                    .multilineTextAlignment(.center)
            } else if offline {
                Text("Offline mode is on. Turn it off at the top to save changes.")
                    .font(.caption)
                    .foregroundStyle(Taproom.muted)
                    .multilineTextAlignment(.center)
            }
            if let pending {
                Button("Remove from list", role: .destructive) {
                    PendingCheckins.shared.remove(pending.id)
                    dismiss()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Taproom.destructive)
                .frame(minHeight: 36)
                .disabled(busy || submitted)
            }
            Button(action: savesForLater ? saveForLater : submit) {
                if busy {
                    ProgressView().tint(Taproom.background)
                } else if savesForLater {
                    Label("Save for later", systemImage: "bookmark")
                } else {
                    Text(editing == nil ? "Check in" : "Save")
                }
            }
            .buttonStyle(TaproomPrimaryButton())
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(busy || submitted || (offline && !savesForLater))
        }
        .taproomBottomBar()
    }

    /// Offline: keeps everything filled in so far, with the time and rough location, to finish
    /// once the connection is back.
    private func saveForLater() {
        guard let beer, editing == nil else { return }
        busy = true
        let image = photo
        Task {
            defer { busy = false }
            let jpeg: Data? = if let image { await Task.detached { CheckinPhoto.jpeg(image) }.value } else { nil }
            var item = PendingCheckin(username: "", savedAt: .now, beer: beer, venue: venue, rating: rating,
                                      shout: shout, servingId: serving?.id, servingName: serving?.name)
            item.setLocation(location.location)
            guard PendingCheckins.shared.add(item, photo: jpeg) != nil else {
                error = "Couldn't save this for later."
                return
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        }
    }

    // MARK: Venues

    /// Untappd at Home, then the venue you're at or picked, then (offline) places you've
    /// checked in at near here, then your recent venues.
    private var chipVenues: [Venue] {
        var out: [Venue] = [.atHome]
        // A saved check-in suggests places near where it was saved, not where you are now.
        let near = pending?.location ?? (connectivity.offlineMode ? location.location : nil)
        let visitedNearby = near.map { VenueHistory.shared.nearby($0, limit: 4) } ?? []
        for v in [extraVenue].compactMap({ $0 }) + visitedNearby + options.recentVenues where !out.contains(where: { $0.id == v.id }) {
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

    // MARK: Shops

    /// The shop you picked or are editing, then the shops you've recently bought beer at.
    private var chipShops: [Venue] {
        var out: [Venue] = []
        for v in [extraShop].compactMap({ $0 }) + options.recentShops where !out.contains(where: { $0.id == v.id }) {
            out.append(v)
        }
        return out
    }

    private var pickedShop: Binding<Venue?> {
        Binding(get: { shop }, set: { v in
            shop = v
            shopLoaded = true
            if let v, !chipShops.contains(where: { $0.id == v.id }) { extraShop = v }
        })
    }

    /// Looks up the edited checkin's shop when the checkin it was given didn't say.
    private func loadEditedShop() async {
        guard let editing, !shopLoaded else { return }
        guard let r = try? await UntappdAPI.shared.fetch(.checkinView(editing.id), as: CheckinView.self),
              let c = r.checkin, c.retailVenueKnown, c.retailVenue.map({ $0.foursquareId != nil }) ?? true,
              !shopLoaded else { return }
        shop = c.retailVenue
        extraShop = c.retailVenue ?? extraShop
        shopLoaded = true
    }

    // MARK: Actions

    private func loadLibraryPhoto(_ item: PhotosPickerItem?) {
        photoLoadTask?.cancel()
        photoLoadTask = nil
        guard let item else { return }
        error = nil
        photoLoadTask = Task {
            let data = try? await item.loadTransferable(type: Data.self)
            guard !Task.isCancelled else { return }
            if let data, let img = UIImage(data: data) {
                photo = img
            } else {
                error = "Couldn't load that photo."
            }
        }
    }

    /// Attaches the most recent image in the photo library.
    private func useLastPhoto() {
        photoLoadTask?.cancel()
        error = nil
        photoLoadTask = Task {
            var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
            guard !Task.isCancelled else { return }
            guard status == .authorized || status == .limited else {
                error = "Allow photo access in Settings to use your last photo."
                return
            }
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = 1
            guard let asset = PHAsset.fetchAssets(with: .image, options: options).firstObject else {
                error = "No photos found."
                return
            }
            let request = PHImageRequestOptions()
            request.deliveryMode = .highQualityFormat
            request.isNetworkAccessAllowed = true
            request.version = .current
            let data: Data? = await withCheckedContinuation { cont in
                PHImageManager.default().requestImageDataAndOrientation(for: asset, options: request) { data, _, _, _ in
                    cont.resume(returning: data)
                }
            }
            guard !Task.isCancelled else { return }
            if let data, let img = UIImage(data: data) {
                photo = img
            } else {
                error = "Couldn't load that photo."
            }
        }
    }

    /// Starts a new checkin at the rating the user last gave this beer, unless they've already
    /// moved the glass. Silently leaves it at 0 if the request fails.
    private func prefillRating() async {
        guard editing == nil, let beer else { return }
        let start = ContinuousClock.now
        guard let r = try? await UntappdAPI.shared.fetch(.userRating(beer.bid), as: UserBeerRating.self) else { return }
        let elapsed = ContinuousClock.now - start
        if elapsed < .milliseconds(220) {
            try? await Task.sleep(for: .milliseconds(220) - elapsed)
        }
        guard !Task.isCancelled,
              let last = r.rating,
              let target = GlassRating.prefillTarget(lastRating: last, step: options.ratingStep),
              rating == 0,
              !userTouchedRating else { return }
        rating = target
        prefillPour += 1
    }

    private func loadBeerFlavors() async {
        guard editing == nil, let beer else { return }
        let apply = { (l: FlavorTagList) in beerFlavors = l.items }
        if let l = try? await cacheThenNetwork(.beerFlavorProfile(beer.bid), as: FlavorTagList.self, onCached: apply) {
            apply(l)
        }
    }

    /// Selects the edited checkin's serving type once the list of types has loaded.
    private func preselectServing() {
        guard !preselectedServing else { return }
        let match: ServingType?
        if let id = pending?.servingId {
            match = servingChoices.first { $0.id == id }
        } else if let name = editing?.servingType {
            match = servingChoices.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        } else {
            return
        }
        guard let match else { return }
        serving = match
        preselectedServing = true
    }

    private func submit() {
        guard !busy, !submitted else { return }
        error = nil
        if let editing {
            if shopLoaded {
                submitted = true
                enqueueEdit(editing)
            } else {
                busy = true
                Task {
                    defer { busy = false }
                    await save(editing)
                }
            }
        } else if let v = venue, v.foursquareId == nil, let id = v.venueId {
            busy = true
            Task {
                defer { busy = false }
                await resolveVenueAndAdd(v, id: id)
            }
        } else {
            submitted = true
            add()
        }
    }

    private func resolveVenueAndAdd(_ initial: Venue, id: Int) async {
        var v = initial
        if let info = try? await UntappdAPI.shared.fetch(.venueInfo(id), as: VenueInfo.self), let full = info.venue {
            v.merge(full)
        }
        guard v.foursquareId != nil else {
            error = "Couldn't look up \(v.name). Pick the venue again from the list."
            return
        }
        venue = v
        submitted = true
        add()
    }

    private func add() {
        guard let beer else { return }
        // A saved check-in is posted from where it was saved.
        let loc = pending?.location ?? location.location
        let draft = NewCheckinDraft(
            beerBid: beer.bid,
            foursquareId: venue?.foursquareId,
            lat: loc?.coordinate.latitude,
            lng: loc?.coordinate.longitude,
            rating: rating,
            shout: Self.lateShout(shout, savedAt: pending?.savedAt),
            containerId: serving?.id,
            taggedUserIds: tagged.map(\.id),
            purchaseFoursquareId: shop?.foursquareId,
            flavorIds: flavors.map(\.id),
            venue: venue
        )
        let username = discover.me?.userName ?? UserDefaults.standard.string(forKey: "username") ?? ""
        CheckinQueue.shared.enqueueNew(draft, beerName: beer.name, breweryName: beer.brewery,
                                       username: username, photo: photo)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if let pending { PendingCheckins.shared.remove(pending.id) }
        Task { await LocalIndex.shared.add(beers: [beer]) }
        dismiss()
    }

    private func save(_ original: Checkin) async {
        if !shopLoaded { await loadEditedShop() }
        guard shopLoaded else {
            // Saving now would remove the checkin's shop, if it has one.
            error = "Couldn't load this checkin's shop. Check your connection and try again."
            return
        }
        submitted = true
        enqueueEdit(original)
    }

    private func enqueueEdit(_ original: Checkin) {
        let username = discover.me?.userName ?? UserDefaults.standard.string(forKey: "username") ?? ""
        CheckinQueue.shared.enqueueEdit(original, rating: rating, shout: shout, serving: serving,
                                        shop: shop, username: username, photo: photo)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        dismiss()
    }
}

/// Every flavour tag, searchable, with the beer's common ones first.
struct FlavorPicker: View {
    @Binding var selected: [FlavorTag]
    let common: [FlavorTag]
    @State private var options = CheckInOptions.shared
    @State private var filter = ""

    var body: some View {
        let match = { (f: FlavorTag) in filter.isEmpty || LocalIndex.matches(query: filter, text: f.name) }
        let commonIds = Set(common.map(\.id))
        let top = common.filter(match)
        let rest = options.flavorTags.filter { !commonIds.contains($0.id) && match($0) }
        List {
            if !top.isEmpty {
                Section("Common for this beer") { ForEach(top) { row($0) } }
            }
            Section(top.isEmpty ? "Flavours" : "All flavours") {
                ForEach(rest) { row($0) }
                if options.flavorTags.isEmpty { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search flavours")
        .navigationTitle(selected.isEmpty ? "Flavours" : "\(selected.count) picked")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Taproom.amber)
        .task { await options.loadFlavorTags() }
    }

    private func row(_ f: FlavorTag) -> some View {
        let on = selected.contains { $0.id == f.id }
        return Button {
            if on { selected.removeAll { $0.id == f.id } } else { selected.append(f) }
        } label: {
            HStack {
                Text(f.name).foregroundStyle(Taproom.ink)
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(on ? Taproom.amber : Taproom.border)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct FriendPicker: View {
    @Binding var selected: [User]
    @Environment(DiscoverModel.self) private var discover
    @State private var options = CheckInOptions.shared
    @State private var filter = ""

    var body: some View {
        let recentIds = Set(options.recentlyTagged.map(\.id))
        let recent = User.filter(options.recentlyTagged, matching: filter)
        let nearby = User.filter(options.nearbyFriends(discover.nearbyFriends), matching: filter)
            .filter { !recentIds.contains($0.id) }
        let shownIds = recentIds.union(nearby.map(\.id))
        let all = User.filter(options.allFriends, matching: filter)
        let rest = filter.isEmpty ? all : all.filter { !shownIds.contains($0.id) }
        let featured = !recent.isEmpty || !nearby.isEmpty
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                if !recent.isEmpty {
                    TaproomSection("Recently tagged") { rows(recent) }
                }
                if !nearby.isEmpty {
                    TaproomSection("Nearby") { rows(nearby) }
                }
                TaproomSection(featured ? "All friends" : "Friends") {
                    rows(rest)
                    if options.loadingFriends {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
                    } else if !featured && rest.isEmpty {
                        Text(filter.isEmpty ? "No friends yet." : "No friends found.")
                            .foregroundStyle(Taproom.muted)
                    }
                }
            }
            .padding(.horizontal, Taproom.margin)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .readableContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.immediately)
        .taproomScreen()
        .navigationTitle(selected.isEmpty ? "Tag friends" : "\(selected.count) tagged")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Taproom.background, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            TaproomSearchField(text: $filter, prompt: "Search friends")
                .padding(.horizontal, Taproom.margin)
                .padding(.top, 6)
                .padding(.bottom, 8)
                .frame(maxWidth: .readableContentWidth)
                .frame(maxWidth: .infinity)
                .background(Taproom.background)
        }
        .task { await options.loadFriends() }
    }

    private func rows(_ users: [User]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(users) { row($0) }
        }
    }

    private func row(_ u: User) -> some View {
        let on = selected.contains { $0.id == u.id }
        return Button {
            if on { selected.removeAll { $0.id == u.id } } else { selected.append(u) }
        } label: {
            HStack(spacing: 12) {
                Avatar(url: u.avatar, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(u.displayName).foregroundStyle(Taproom.ink)
                    Text("@\(u.userName)").font(.caption).foregroundStyle(Taproom.muted)
                }
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(on ? Taproom.amber : Taproom.border)
            }
            .padding(.vertical, 10)
            .frame(minHeight: 44)
        }
        .buttonStyle(TaproomRowStyle())
        .taproomRowDivider()
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

extension View {
    /// Presents a check-in composer as a centered page-sized modal sheet on iPad (regular width)
    /// and a full-screen cover on iPhone (compact width).
    func checkInPresentation<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        modifier(CheckInPresentation(item: item, content: content))
    }
}

private struct CheckInPresentation<Item: Identifiable, SheetContent: View>: ViewModifier {
    @Binding var item: Item?
    @ViewBuilder let content: (Item) -> SheetContent
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content base: Content) -> some View {
        if horizontalSizeClass == .regular {
            base.sheet(item: $item) { value in
                content(value)
                    .presentationSizing(.page)
            }
        } else {
            base.fullScreenCover(item: $item, content: content)
        }
    }
}
