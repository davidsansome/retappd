import SwiftUI

struct GlobalTopListsView: View {
    @State private var model = GlobalTopListsModel()
    @State private var showingStylePicker = false
    @State private var showingBeerCountryPicker = false
    @State private var showingBreweryCountryPicker = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                Text("Global Top Lists")
                    .font(.system(size: 30, weight: .heavy))
                    .tracking(-0.6)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                    .accessibilityAddTraits(.isHeader)

                Section {
                    switch model.selectedTab {
                    case .beers: beersContent
                    case .breweries: breweriesContent
                    case .trending: trendingContent
                    }
                } header: {
                    TaproomPageTabs(tabs: [
                        TaproomTab(value: TopListsTab.beers, title: "Beers", systemImage: "mug.fill"),
                        TaproomTab(value: TopListsTab.breweries, title: "Breweries", systemImage: "building.2.fill"),
                        TaproomTab(value: TopListsTab.trending, title: "Trending", systemImage: "flame.fill"),
                    ], selection: $model.selectedTab)
                    .padding(.bottom, 10)
                    .background { Taproom.background.padding(.horizontal, -Taproom.margin) }
                }
            }
            .padding(.horizontal, Taproom.margin)
            .padding(.bottom, 24)
            .frame(maxWidth: .readableContentWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .taproomScreen()
        .taproomScrollTitle("Global Top Lists")
        .toolbarBackground(Taproom.background, for: .navigationBar)
        .refreshable { await model.loadCurrentTab(force: true) }
        .task(id: model.selectedTab) { await model.loadCurrentTab() }
        .task(id: model.trendingCategory) {
            if model.selectedTab == .trending {
                await model.loadTrending()
            }
        }
        .sheet(isPresented: $showingStylePicker) {
            TopListOptionPickerSheet(
                title: "Style",
                allTitle: "All styles",
                searchPrompt: "Search styles",
                options: model.styles,
                selection: model.beersFilter.style,
                name: \.name,
                searchIdentifier: "topLists.stylePicker.search"
            ) { style in
                Task { await model.setBeerStyle(style) }
            }
        }
        .sheet(isPresented: $showingBeerCountryPicker) {
            TopListOptionPickerSheet(
                title: "Country",
                allTitle: "All countries",
                searchPrompt: "Search countries",
                options: model.countries,
                selection: model.beersFilter.country,
                name: \.name,
                searchIdentifier: "topLists.countryPicker.search"
            ) { country in
                Task { await model.setBeerCountry(country) }
            }
        }
        .sheet(isPresented: $showingBreweryCountryPicker) {
            TopListOptionPickerSheet(
                title: "Country",
                allTitle: "All countries",
                searchPrompt: "Search countries",
                options: model.countries,
                selection: model.breweriesFilter.country,
                name: \.name,
                searchIdentifier: "topLists.breweryCountryPicker.search"
            ) { country in
                Task { await model.setBreweryCountry(country) }
            }
        }
    }

    // MARK: - Beers Tab

    private var beersFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button { showingStylePicker = true } label: {
                    HStack(spacing: 5) {
                        Text(model.beersFilter.style?.name ?? "Style").lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                }
                .buttonStyle(TaproomChip(on: model.beersFilter.style != nil))
                .disabled(model.styles.isEmpty && model.beersFilter.style == nil)
                .accessibilityLabel(model.beersFilter.style.map { "Style, \($0.name)" } ?? "Filter by style")
                .accessibilityAddTraits(model.beersFilter.style != nil ? .isSelected : [])
                .accessibilityIdentifier("topLists.beers.style")

                Button { showingBeerCountryPicker = true } label: {
                    HStack(spacing: 5) {
                        Text(model.beersFilter.country?.name ?? "Country").lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                }
                .buttonStyle(TaproomChip(on: model.beersFilter.country != nil))
                .disabled(model.countries.isEmpty && model.beersFilter.country == nil)
                .accessibilityLabel(model.beersFilter.country.map { "Country, \($0.name)" } ?? "Filter by country")
                .accessibilityAddTraits(model.beersFilter.country != nil ? .isSelected : [])
                .accessibilityIdentifier("topLists.beers.country")

                Button {
                    Task { await model.toggleInProduction() }
                } label: {
                    HStack(spacing: 5) {
                        if model.beersFilter.inProduction {
                            Image(systemName: "checkmark").font(.caption.weight(.bold))
                        }
                        Text("In production")
                    }
                }
                .buttonStyle(TaproomChip(on: model.beersFilter.inProduction))
                .accessibilityAddTraits(model.beersFilter.inProduction ? .isSelected : [])
                .accessibilityIdentifier("topLists.beers.inProduction")

                Button {
                    model.toggleHaventHad()
                } label: {
                    HStack(spacing: 5) {
                        if model.beersFilter.haventHad {
                            Image(systemName: "checkmark").font(.caption.weight(.bold))
                        }
                        Text("Haven't had")
                    }
                }
                .buttonStyle(TaproomChip(on: model.beersFilter.haventHad))
                .accessibilityAddTraits(model.beersFilter.haventHad ? .isSelected : [])
                .accessibilityIdentifier("topLists.beers.haventHad")

                if model.beersFilter.isActive {
                    Button {
                        Task { await model.resetBeersFilters() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark").font(.caption.weight(.bold))
                            Text("Clear")
                        }
                    }
                    .buttonStyle(TaproomChip(on: false, dashed: true))
                    .accessibilityIdentifier("topLists.beers.clearFiltersChip")
                }
            }
        }
        .scrollClipDisabled()
        .sensoryFeedback(.selection, trigger: model.beersFilter)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var beersContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            beersFilterBar
            if model.isLoadingBeers && model.beers.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            } else if let error = model.beersError, model.beers.isEmpty {
                ErrorRow(message: error) {
                    Task { await model.loadBeers(force: true) }
                }
                .padding(.top, 12)
            } else if model.visibleBeers.isEmpty {
                if model.beersFilter.isActive {
                    TaproomEmptyFilterView(
                        title: "No matching beers",
                        message: "Try adjusting your filters.",
                        clearButtonIdentifier: "topLists.beers.clearFilters"
                    ) {
                        Task { await model.resetBeersFilters() }
                    }
                } else {
                    Text("No top rated beers available.")
                        .font(.callout)
                        .foregroundStyle(Taproom.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.visibleBeers) { entry in
                        NavigationLink(value: BeerBreweryRoute.beer(entry.item.beer)) {
                            BeerRow(beer: entry.item.beer, number: "\(entry.rank)")
                        }
                        .buttonStyle(TaproomRowStyle())
                        .taproomRowDivider()
                        .accessibilityIdentifier("topLists.beerRow.\(entry.id)")
                    }
                }
                .opacity(model.isLoadingBeers ? 0.5 : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: model.isLoadingBeers)

                if let error = model.beersError {
                    ErrorRow(message: error) {
                        Task { await model.loadBeers(force: true) }
                    }
                    .padding(.top, 12)
                }
            }
        }
    }

    // MARK: - Breweries Tab

    private var breweriesFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Menu {
                    Button {
                        Task { await model.setBreweryType(nil) }
                    } label: {
                        if model.breweriesFilter.breweryType == nil {
                            Label("All types", systemImage: "checkmark")
                        } else {
                            Text("All types")
                        }
                    }
                    if !model.breweryTypes.isEmpty {
                        Divider()
                        ForEach(model.breweryTypes) { type in
                            Button {
                                Task { await model.setBreweryType(type) }
                            } label: {
                                if model.breweriesFilter.breweryType == type {
                                    Label(type.name, systemImage: "checkmark")
                                } else {
                                    Text(type.name)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(model.breweriesFilter.breweryType?.name ?? "Type").lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                    .taproomChipLabel(on: model.breweriesFilter.breweryType != nil)
                }
                .disabled(model.breweryTypes.isEmpty && model.breweriesFilter.breweryType == nil)
                .accessibilityLabel(model.breweriesFilter.breweryType.map { "Brewery type, \($0.name)" } ?? "Filter by brewery type")
                .accessibilityIdentifier("topLists.breweries.type")

                Button { showingBreweryCountryPicker = true } label: {
                    HStack(spacing: 5) {
                        Text(model.breweriesFilter.country?.name ?? "Country").lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                }
                .buttonStyle(TaproomChip(on: model.breweriesFilter.country != nil))
                .disabled(model.countries.isEmpty && model.breweriesFilter.country == nil)
                .accessibilityLabel(model.breweriesFilter.country.map { "Country, \($0.name)" } ?? "Filter by country")
                .accessibilityAddTraits(model.breweriesFilter.country != nil ? .isSelected : [])
                .accessibilityIdentifier("topLists.breweries.country")

                if model.breweriesFilter.isActive {
                    Button {
                        Task { await model.resetBreweriesFilters() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark").font(.caption.weight(.bold))
                            Text("Clear")
                        }
                    }
                    .buttonStyle(TaproomChip(on: false, dashed: true))
                    .accessibilityIdentifier("topLists.breweries.clearFiltersChip")
                }
            }
        }
        .scrollClipDisabled()
        .sensoryFeedback(.selection, trigger: model.breweriesFilter)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var breweriesContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            breweriesFilterBar
            if model.isLoadingBreweries && model.breweries.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            } else if let error = model.breweriesError, model.breweries.isEmpty {
                ErrorRow(message: error) {
                    Task { await model.loadBreweries(force: true) }
                }
                .padding(.top, 12)
            } else if model.breweries.isEmpty {
                if model.breweriesFilter.isActive {
                    TaproomEmptyFilterView(
                        title: "No matching breweries",
                        message: "Try adjusting your filters.",
                        clearButtonIdentifier: "topLists.breweries.clearFilters"
                    ) {
                        Task { await model.resetBreweriesFilters() }
                    }
                } else {
                    Text("No top rated breweries available.")
                        .font(.callout)
                        .foregroundStyle(Taproom.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.breweries.enumerated()), id: \.element.id) { index, brewery in
                        NavigationLink(
                            value: BeerBreweryRoute.brewery(id: brewery.id, name: brewery.name, label: brewery.label)
                        ) {
                            TopBreweryRow(brewery: brewery, rank: index + 1)
                        }
                        .buttonStyle(TaproomRowStyle())
                        .taproomRowDivider()
                        .accessibilityIdentifier("topLists.breweryRow.\(brewery.id)")
                    }
                }
                .opacity(model.isLoadingBreweries ? 0.5 : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: model.isLoadingBreweries)

                if let error = model.breweriesError {
                    ErrorRow(message: error) {
                        Task { await model.loadBreweries(force: true) }
                    }
                    .padding(.top, 12)
                }
            }
        }
    }

    // MARK: - Trending Tab

    private var trendingCategoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(TrendingCategory.allCases) { category in
                    let on = model.trendingCategory == category
                    Button {
                        if reduceMotion {
                            model.trendingCategory = category
                        } else {
                            withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.85)) {
                                model.trendingCategory = category
                            }
                        }
                    } label: {
                        Text(category.title)
                    }
                    .buttonStyle(TaproomChip(on: on))
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("topLists.trending.\(category.rawValue)")
                }
            }
        }
        .scrollClipDisabled()
        .sensoryFeedback(.selection, trigger: model.trendingCategory)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var trendingContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            trendingCategoryBar
            switch model.trendingCategory {
            case .craft, .macro:
                trendingBeersContent
            case .venues:
                trendingVenuesContent
            }
        }
    }

    @ViewBuilder private var trendingBeersContent: some View {
        let items = model.activeTrendingBeers
        if model.isLoadingTrendingBeers && items.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        } else if let error = model.trendingBeersError, items.isEmpty {
            ErrorRow(message: error) {
                Task { await model.loadTrending(force: true) }
            }
            .padding(.top, 12)
        } else if items.isEmpty {
            Text("No trending beers right now.")
                .font(.callout)
                .foregroundStyle(Taproom.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let detail = item.totalCount > 0 ? "\(item.totalCount.formatted()) check-ins" : nil
                    NavigationLink(value: BeerBreweryRoute.beer(item.beer)) {
                        BeerRow(beer: item.beer, detail: detail, number: "\(index + 1)")
                    }
                    .buttonStyle(TaproomRowStyle())
                    .taproomRowDivider()
                    .accessibilityIdentifier("topLists.trendingBeerRow.\(item.id)")
                }
            }
            .opacity(model.isLoadingTrendingBeers ? 0.5 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: model.isLoadingTrendingBeers)

            if let error = model.trendingBeersError {
                ErrorRow(message: error) {
                    Task { await model.loadTrending(force: true) }
                }
                .padding(.top, 12)
            }
        }
    }

    @ViewBuilder private var trendingVenuesContent: some View {
        if model.isLoadingTrendingVenues && model.trendingVenues.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        } else if let error = model.trendingVenuesError, model.trendingVenues.isEmpty {
            ErrorRow(message: error) {
                Task { await model.loadTrending(force: true) }
            }
            .padding(.top, 12)
        } else if model.trendingVenues.isEmpty {
            Text("No trending venues right now.")
                .font(.callout)
                .foregroundStyle(Taproom.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.trendingVenues.enumerated()), id: \.element.id) { index, item in
                    NavigationLink(value: item.venue) {
                        TopTrendingVenueRow(item: item, rank: index + 1)
                    }
                    .buttonStyle(TaproomRowStyle())
                    .taproomRowDivider()
                    .accessibilityIdentifier("topLists.trendingVenueRow.\(item.id)")
                }
            }
            .opacity(model.isLoadingTrendingVenues ? 0.5 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: model.isLoadingTrendingVenues)

            if let error = model.trendingVenuesError {
                ErrorRow(message: error) {
                    Task { await model.loadTrending(force: true) }
                }
                .padding(.top, 12)
            }
        }
    }
}

// MARK: - Supporting Rows

private struct TopRankBadge: View {
    let rank: Int

    var body: some View {
        Text("\(rank)")
            .font(.headline.monospacedDigit())
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .foregroundStyle(Taproom.background)
            .frame(width: 34, height: 34)
            .background(Taproom.ink, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Rank \(rank)")
    }
}

private struct TopBreweryRow: View {
    let brewery: TopRatedBrewery
    let rank: Int

    var body: some View {
        HStack(spacing: 12) {
            TopRankBadge(rank: rank)
            BeerLabel(beer: nil, brewery: brewery.label, size: 44, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(brewery.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                if !brewery.subtitle.isEmpty {
                    Text(brewery.subtitle)
                        .font(.footnote)
                        .foregroundStyle(Taproom.muted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if let r = brewery.rating, r > 0 {
                Text(r.formatted(.number.precision(.fractionLength(2))))
                    .font(.headline.weight(.heavy).monospacedDigit())
                    .accessibilityLabel("Average \(r.formatted(.number.precision(.fractionLength(2)))) out of 5")
            }
        }
        .foregroundStyle(Taproom.ink)
        .padding(.vertical, 8)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }
}

private struct TopTrendingVenueRow: View {
    let item: TrendingVenueItem
    let rank: Int

    var body: some View {
        HStack(spacing: 12) {
            TopRankBadge(rank: rank)
            VenueIcon(venue: item.venue, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.venue.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if item.venue.isVerified { VerifiedBadge() }
                }
                if !item.venue.subtitle.isEmpty {
                    Text(item.venue.subtitle)
                        .font(.footnote)
                        .foregroundStyle(Taproom.muted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if item.totalUsers > 0 {
                Text("\(item.totalUsers.formatted()) people")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Taproom.muted)
                    .fixedSize()
            }
        }
        .foregroundStyle(Taproom.ink)
        .padding(.vertical, 8)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }
}

// MARK: - Searchable Picker Sheet

private struct TopListOptionPickerSheet<Option: Identifiable & Hashable>: View {
    let title: String
    let allTitle: String
    let searchPrompt: String
    let options: [Option]
    let selection: Option?
    let name: KeyPath<Option, String>
    let searchIdentifier: String
    let onSelect: (Option?) -> Void

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var filteredOptions: [Option] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return options }
        return options.filter {
            $0[keyPath: name].range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TaproomSearchField(
                    text: $query,
                    prompt: searchPrompt,
                    capitalization: .words,
                    fieldIdentifier: searchIdentifier
                )
                .padding(.horizontal, Taproom.margin)
                .padding(.vertical, 10)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            pickerRow(title: allTitle, isSelected: selection == nil) {
                                onSelect(nil)
                                dismiss()
                            }
                            .accessibilityIdentifier("topLists.picker.all")
                        }

                        if filteredOptions.isEmpty {
                            Text("No matches for \"\(query.trimmingCharacters(in: .whitespacesAndNewlines))\".")
                                .font(.callout)
                                .foregroundStyle(Taproom.muted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 32)
                        } else {
                            ForEach(filteredOptions) { option in
                                pickerRow(title: option[keyPath: name], isSelected: selection == option) {
                                    onSelect(option)
                                    dismiss()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Taproom.margin)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .taproomScreen()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Taproom.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(Taproom.ink)
                }
            }
        }
    }

    private func pickerRow(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(isSelected ? .body.weight(.semibold) : .body)
                    .foregroundStyle(Taproom.ink)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.bold))
                        .foregroundStyle(Taproom.amber)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 10)
            .frame(minHeight: 48)
        }
        .buttonStyle(TaproomRowStyle())
        .taproomRowDivider()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
