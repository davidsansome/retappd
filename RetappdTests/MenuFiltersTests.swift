import XCTest
@testable import Retappd

final class MenuFiltersTests: XCTestCase {

    // MARK: - Request Parameter Building

    func testBreweryBeersDefaultRequest() {
        let req = APIRequest.breweryBeers(198631)
        XCTAssertEqual(req.method, .get)
        XCTAssertEqual(req.path, "/v4/brewery/beer_list/198631")
        XCTAssertEqual(req.query["hasNotHadBefore"], "false")
        XCTAssertEqual(req.query["q"], "")
        XCTAssertEqual(req.query["showAllBeers"], "false")
        XCTAssertEqual(req.query["sort"], "most_popular")
        XCTAssertEqual(req.query["styles"], "true")
        XCTAssertEqual(req.query["type_id"], "")
        XCTAssertNil(req.query["offset"])
    }

    func testBreweryBeersFilteredRequest() {
        let req = APIRequest.breweryBeers(
            198631,
            offset: 25,
            query: "Stout",
            hasNotHadBefore: true,
            sort: "highest_rated",
            styleId: 310,
            showAllBeers: true
        )
        XCTAssertEqual(req.query["hasNotHadBefore"], "true")
        XCTAssertEqual(req.query["q"], "Stout")
        XCTAssertEqual(req.query["showAllBeers"], "true")
        XCTAssertEqual(req.query["sort"], "highest_rated")
        XCTAssertEqual(req.query["styles"], "true")
        XCTAssertEqual(req.query["type_id"], "310")
        XCTAssertEqual(req.query["offset"], "25")
    }

    func testVenueMenuDefaultRequest() {
        let req = APIRequest.venueMenu(17058)
        XCTAssertEqual(req.method, .post)
        XCTAssertEqual(req.path, "/v4/menus/sections")
        XCTAssertEqual(req.form?["venue_id"], "17058")
        XCTAssertEqual(req.form?["limit"], "100")
        XCTAssertEqual(req.form?["has_not_had_before"], "false")
        XCTAssertEqual(req.form?["q"], "")
        XCTAssertEqual(req.form?["sort"], "")
        XCTAssertEqual(req.form?["styles"], "")
        XCTAssertEqual(req.form?["serving_styles"], "")
        XCTAssertEqual(req.form?["brewery"], "")
        XCTAssertEqual(req.form?["countries"], "")
        XCTAssertEqual(req.form?["menu_id"], "")
        XCTAssertEqual(req.form?["flatten_when_filtering"], "true")
    }

    func testVenueMenuFilteredRequest() {
        let req = APIRequest.venueMenu(
            17058,
            limit: 50,
            query: "Hazy",
            hasNotHadBefore: true,
            sort: "highest_rated",
            styles: ["IPA - New England / Hazy", "Pale Ale - American"],
            servingStyles: ["Draft"],
            brewery: "Banks Brewing",
            countries: ["Australia", "New Zealand"],
            menuId: 55772,
            flattenWhenFiltering: false
        )
        XCTAssertEqual(req.form?["venue_id"], "17058")
        XCTAssertEqual(req.form?["limit"], "50")
        XCTAssertEqual(req.form?["q"], "Hazy")
        XCTAssertEqual(req.form?["has_not_had_before"], "true")
        XCTAssertEqual(req.form?["sort"], "highest_rated")
        XCTAssertEqual(req.form?["styles"], "IPA - New England / Hazy,Pale Ale - American")
        XCTAssertEqual(req.form?["serving_styles"], "Draft")
        XCTAssertEqual(req.form?["brewery"], "Banks Brewing")
        XCTAssertEqual(req.form?["countries"], "Australia,New Zealand")
        XCTAssertEqual(req.form?["menu_id"], "55772")
        XCTAssertEqual(req.form?["flatten_when_filtering"], "false")
    }

    func testVenueMenuFiltersRequest() {
        let req = APIRequest.venueMenuFilters(17058)
        XCTAssertEqual(req.method, .get)
        XCTAssertEqual(req.path, "/v4/menus/filters")
        XCTAssertEqual(req.query["venue_id"], "17058")
    }

    // MARK: - Response Decoding

    func testBreweryBeerListDecodingStylesAndSortOptions() throws {
        let json = """
        {
          "meta": {"code": 200},
          "response": {
            "total_count_filtered": 12,
            "total_count": 46,
            "sort_key": "highest_rated",
            "beers": {
              "count": 1,
              "items": [
                {
                  "has_had": true,
                  "beer": {
                    "bid": 1719356,
                    "beer_name": "Let's Bee Friends",
                    "beer_style": "Mead - Other",
                    "beer_abv": 11.03,
                    "rating_score": 4.25,
                    "rating_count": 29
                  },
                  "brewery": {
                    "brewery_id": 198631,
                    "brewery_name": "Bathtub Brewing"
                  }
                }
              ]
            },
            "styles": {
              "count": 2,
              "items": [
                {"type_id": 7, "type_name": "Barleywine - American", "total_count": 2},
                {"type_id": 64, "type_name": "Belgian Quadrupel", "total_count": 3}
              ]
            },
            "sorting_options": [
              {"sort_key": "most_popular", "sort_name": "Most Popular"},
              {"sort_key": "highest_rated", "sort_name": "Highest Rated"},
              {"sort_key": "beer_name_asc", "sort_name": "Beer Name (A to Z)"}
            ]
          }
        }
        """
        let list = try UntappdAPI.decode(BreweryBeerList.self, from: Data(json.utf8))
        XCTAssertEqual(list.total, 12)
        XCTAssertEqual(list.totalUnfiltered, 46)
        XCTAssertEqual(list.activeSortKey, "highest_rated")
        XCTAssertEqual(list.beers.count, 1)
        XCTAssertEqual(list.beers[0].bid, 1719356)
        XCTAssertEqual(list.beers[0].hasHad, true)
        XCTAssertEqual(list.styles.map(\.id), [7, 64])
        XCTAssertEqual(list.styles.map(\.name), ["Barleywine - American", "Belgian Quadrupel"])
        XCTAssertEqual(list.styles.map(\.count), [2, 3])
        XCTAssertEqual(list.sortingOptions.map(\.key), ["most_popular", "highest_rated", "beer_name_asc"])
    }

    func testVenueMenuFiltersDecoding() throws {
        let json = """
        {
          "meta": {"code": 200},
          "response": {
            "total_beer": 140,
            "filters": {
              "styles": {
                "Stout - Imperial": 3,
                "IPA - American": 14,
                "Empty Style": 0
              },
              "breweries": {
                "Banks Brewing": 2,
                "Akasha Brewing Company": 1
              },
              "countries": {
                "New Zealand": 11,
                "Australia": 121
              }
            }
          }
        }
        """
        let filters = try UntappdAPI.decode(VenueMenuFilters.self, from: Data(json.utf8))
        XCTAssertEqual(filters.totalBeer, 140)
        XCTAssertEqual(filters.styles.map(\.name), ["IPA - American", "Stout - Imperial"])
        XCTAssertEqual(filters.styles.map(\.count), [14, 3])
        XCTAssertEqual(filters.breweries.map(\.name), ["Akasha Brewing Company", "Banks Brewing"])
        XCTAssertEqual(filters.countries.map(\.name), ["Australia", "New Zealand"])
    }

    func testMenuSectionsTruncationDecoding() throws {
        let json = """
        {
          "meta": {"code": 200},
          "response": {
            "sections": [
              {
                "section_id": 1,
                "section_name": "Tap List",
                "total_count": 1,
                "last_page": true,
                "items": [{"id": 10, "untappd_id": 100, "name": "Hazy IPA", "brewery": "Co", "style": "IPA", "abv": "6.5", "rating": "4.1"}]
              },
              {
                "section_id": 2,
                "section_name": "Bottleshop",
                "total_count": 150,
                "last_page": false,
                "items": [{"id": 11, "untappd_id": 101, "name": "Stout", "brewery": "Co", "style": "Stout", "abv": "10.0", "rating": "4.3"}]
              }
            ]
          }
        }
        """
        let menu = try UntappdAPI.decode(MenuSections.self, from: Data(json.utf8))
        XCTAssertEqual(menu.sections.count, 2)
        XCTAssertFalse(menu.sections[0].isTruncated)
        XCTAssertTrue(menu.sections[1].isTruncated)
    }

    // MARK: - BreweryModel Filter & Pagination Transitions

    @MainActor
    func testBreweryModelFilterTransitionsAndPaginationReset() async {
        final class Recorder: @unchecked Sendable {
            var requests: [APIRequest] = []
        }
        let recorder = Recorder()
        let styles = [
            BreweryBeerList.StyleOption(id: 128, name: "IPA - American", count: 10),
            BreweryBeerList.StyleOption(id: 310, name: "Stout - Pastry", count: 4),
        ]
        let sorts = [
            BreweryBeerList.SortOption(key: "most_popular", name: "Most Popular"),
            BreweryBeerList.SortOption(key: "highest_rated", name: "Highest Rated"),
        ]
        let beer1 = BeerLite(bid: 1, name: "Hop Bomb", brewery: "Test", style: "IPA - American", abv: 6.5, rating: 4.1, hasHad: true)
        let beer2 = BeerLite(bid: 2, name: "Dark Star", brewery: "Test", style: "Stout - Pastry", abv: 9.0, rating: 4.4, hasHad: false)

        let model = BreweryModel(
            brewery: BreweryPreview(id: 42, name: "Test Brewery", label: nil),
            fetchBeers: { req in
                recorder.requests.append(req)
                if req.query["offset"] == "1" {
                    return BreweryBeerList(beers: [beer2], total: 2, styles: styles, sortingOptions: sorts)
                }
                if req.query["hasNotHadBefore"] == "true" {
                    return BreweryBeerList(beers: [beer2], total: 1, styles: [], sortingOptions: sorts)
                }
                return BreweryBeerList(beers: [beer1], total: 2, styles: styles, sortingOptions: sorts)
            }
        )

        // Initial load
        await model.applyFilter(BreweryBeerFilter())
        XCTAssertEqual(model.beers.map(\.bid), [1])
        XCTAssertEqual(model.availableStyles.count, 2)
        XCTAssertEqual(model.sortingOptions.count, 2)
        XCTAssertTrue(model.hasMoreBeers)

        // Load page 2 (offset = 1)
        await model.loadMoreBeers()
        XCTAssertEqual(model.beers.map(\.bid), [1, 2])
        XCTAssertEqual(recorder.requests.last?.query["offset"], "1")

        // Toggle "Haven't had" -> resets pagination (no offset) and preserves availableStyles
        await model.toggleHasNotHadBefore()
        XCTAssertTrue(model.filter.hasNotHadBefore)
        XCTAssertTrue(model.filter.isActive)
        XCTAssertEqual(model.beers.map(\.bid), [2])
        XCTAssertNil(recorder.requests.last?.query["offset"])
        XCTAssertEqual(recorder.requests.last?.query["hasNotHadBefore"], "true")
        XCTAssertEqual(model.availableStyles.count, 2)

        // Change sort and style and search
        await model.setSortKey("highest_rated")
        await model.setStyleId(310)
        await model.setSearchQuery("  Dark  ")
        XCTAssertEqual(recorder.requests.last?.query["sort"], "highest_rated")
        XCTAssertEqual(recorder.requests.last?.query["type_id"], "310")
        XCTAssertEqual(recorder.requests.last?.query["q"], "Dark")

        // Reset filters
        await model.resetFilters()
        XCTAssertFalse(model.filter.isActive)
        XCTAssertEqual(recorder.requests.last?.query["hasNotHadBefore"], "false")
        XCTAssertEqual(recorder.requests.last?.query["sort"], "most_popular")
        XCTAssertEqual(recorder.requests.last?.query["type_id"], "")
        XCTAssertEqual(recorder.requests.last?.query["q"], "")
    }

    // MARK: - VenueModel Client Filtering, Sorting & Truncated Server Sync

    @MainActor
    func testVenueModelClientFilteringAndSorting() async {
        let b1 = BeerLite(bid: 10, name: "Zebra Pils", brewery: "Alpha", style: "Pilsner", abv: 4.8, rating: 3.7, hasHad: true)
        let b2 = BeerLite(bid: 11, name: "Amber Ale", brewery: "Beta", style: "IPA - American", abv: 6.2, rating: 4.3, hasHad: false)
        let b3 = BeerLite(bid: 12, name: "Imperial Stout", brewery: "Gamma", style: "Stout", abv: 11.5, rating: 4.1, hasHad: false)

        let section = MenuSections.Section(
            id: 1,
            name: "On Tap",
            items: [
                MenuSections.Item(id: 101, beer: b1),
                MenuSections.Item(id: 102, beer: b2),
                MenuSections.Item(id: 103, beer: b3),
            ],
            totalCount: 3,
            lastPage: true
        )

        let venue = Venue(venueId: 17058, name: "Test Taproom", isVerified: true)
        let model = VenueModel(
            venue: venue,
            fetchMenu: { _ in MenuSections(sections: [section]) },
            fetchMenuFilters: { _ in VenueMenuFilters() }
        )
        await model.load()

        // Derived styles fallback when menus/filters is empty
        XCTAssertEqual(model.availableStyles.map(\.name), ["IPA - American", "Pilsner", "Stout"])

        // Default order
        let hadSet: Set<Int> = [10]
        XCTAssertEqual(model.filteredItems(in: section, hasHad: { hadSet.contains($0.bid) }).map(\.id), [101, 102, 103])

        // Sort: Highest Rated
        model.setSort(.highestRated)
        XCTAssertEqual(model.filteredItems(in: section, hasHad: { hadSet.contains($0.bid) }).map(\.id), [102, 103, 101])

        // Sort: Name A-Z
        model.setSort(.nameAsc)
        XCTAssertEqual(model.filteredItems(in: section, hasHad: { hadSet.contains($0.bid) }).map(\.id), [102, 103, 101])

        // Sort: ABV High-Low
        model.setSort(.abvDesc)
        XCTAssertEqual(model.filteredItems(in: section, hasHad: { hadSet.contains($0.bid) }).map(\.id), [103, 102, 101])

        // Filter: Haven't had (excludes bid 10)
        await model.toggleHasNotHadBefore()
        XCTAssertEqual(model.filteredItems(in: section, hasHad: { hadSet.contains($0.bid) }).map(\.id), [103, 102])

        // Filter: Style
        await model.setStyle("IPA - American")
        XCTAssertEqual(model.filteredItems(in: section, hasHad: { hadSet.contains($0.bid) }).map(\.id), [102])

        // Filter: Non-matching search
        model.setSearchQuery("Saison")
        XCTAssertTrue(model.filteredItems(in: section, hasHad: { hadSet.contains($0.bid) }).isEmpty)

        // Reset
        await model.resetFilters()
        XCTAssertFalse(model.filter.isActive)
        XCTAssertEqual(model.filteredItems(in: section, hasHad: { hadSet.contains($0.bid) }).map(\.id), [101, 102, 103])
    }

    @MainActor
    func testVenueModelTruncatedSectionSyncsWithServer() async {
        final class Recorder: @unchecked Sendable {
            var requests: [APIRequest] = []
        }
        let recorder = Recorder()
        let b1 = BeerLite(bid: 10, name: "First Tap", brewery: "Co", style: "IPA", abv: 6.0, rating: 4.0)
        let b2 = BeerLite(bid: 20, name: "Hidden Gem", brewery: "Co", style: "Stout", abv: 9.5, rating: 4.5)

        let venue = Venue(venueId: 17058, name: "Big Shop", isVerified: true)
        let model = VenueModel(
            venue: venue,
            fetchMenu: { req in
                recorder.requests.append(req)
                if req.form?["has_not_had_before"] == "true" {
                    return MenuSections(sections: [
                        MenuSections.Section(id: 99, name: "Filtered", items: [MenuSections.Item(id: 200, beer: b2)])
                    ])
                }
                return MenuSections(sections: [
                    MenuSections.Section(id: 1, name: "Bottleshop", items: [MenuSections.Item(id: 100, beer: b1)],
                                         totalCount: 180, lastPage: false)
                ])
            },
            fetchMenuFilters: { _ in
                VenueMenuFilters(totalBeer: 180, styles: [
                    VenueMenuFilters.FilterOption(name: "IPA", count: 80),
                    VenueMenuFilters.FilterOption(name: "Stout", count: 20),
                ])
            }
        )

        await model.load()
        XCTAssertTrue(model.hasTruncatedSection)
        XCTAssertEqual(model.availableStyles.map(\.name), ["IPA", "Stout"])

        await model.toggleHasNotHadBefore()
        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertEqual(recorder.requests.last?.form?["has_not_had_before"], "true")
        XCTAssertEqual(model.filteredSections(hasHad: { _ in false }).first?.1.map(\.id), [200])

        await model.resetFilters()
        XCTAssertNil(model.filteredServerSections)
    }

    @MainActor
    func testVenueModelTruncatedClearSearchResyncsWithRemainingFilterAndRefresh() async {
        final class Recorder: @unchecked Sendable {
            var requests: [APIRequest] = []
        }
        let recorder = Recorder()
        let b1 = BeerLite(bid: 10, name: "First Tap", brewery: "Co", style: "IPA", abv: 6.0, rating: 4.0)
        let b2 = BeerLite(bid: 20, name: "Hidden Stout", brewery: "Co", style: "Stout", abv: 9.5, rating: 4.5)
        let b3 = BeerLite(bid: 30, name: "Hidden IPA", brewery: "Co", style: "IPA", abv: 6.8, rating: 4.2)

        let venue = Venue(venueId: 17058, name: "Big Shop", isVerified: true)
        let model = VenueModel(
            venue: venue,
            fetchMenu: { req in
                recorder.requests.append(req)
                if req.form?["has_not_had_before"] == "true" {
                    if req.form?["q"] == "Stout" {
                        return MenuSections(sections: [
                            MenuSections.Section(id: 99, name: "Filtered", items: [MenuSections.Item(id: 200, beer: b2)])
                        ])
                    }
                    return MenuSections(sections: [
                        MenuSections.Section(id: 99, name: "Filtered", items: [
                            MenuSections.Item(id: 200, beer: b2),
                            MenuSections.Item(id: 300, beer: b3),
                        ])
                    ])
                }
                return MenuSections(sections: [
                    MenuSections.Section(id: 1, name: "Bottleshop", items: [MenuSections.Item(id: 100, beer: b1)],
                                         totalCount: 180, lastPage: false)
                ])
            },
            fetchMenuFilters: { _ in VenueMenuFilters() }
        )

        await model.load()
        await model.toggleHasNotHadBefore()
        XCTAssertEqual(model.filteredSections(hasHad: { _ in false }).first?.1.map(\.id), [200, 300])

        // Search while hasNotHadBefore is active
        model.setSearchQuery("Stout")
        await model.syncServerFilterIfNeeded()
        XCTAssertEqual(recorder.requests.last?.form?["q"], "Stout")
        XCTAssertEqual(recorder.requests.last?.form?["has_not_had_before"], "true")
        XCTAssertEqual(model.filteredSections(hasHad: { _ in false }).first?.1.map(\.id), [200])

        // Clear search while hasNotHadBefore stays active -> must re-sync with q=""
        model.setSearchQuery("")
        await model.syncServerFilterIfNeeded()
        XCTAssertEqual(recorder.requests.last?.form?["q"], "")
        XCTAssertEqual(recorder.requests.last?.form?["has_not_had_before"], "true")
        XCTAssertEqual(model.filteredSections(hasHad: { _ in false }).first?.1.map(\.id), [200, 300])

        // Pull-to-refresh re-syncs filteredServerSections when truncated + server filter active
        let beforeRefreshCount = recorder.requests.count
        await model.load(force: true)
        XCTAssertEqual(recorder.requests.count, beforeRefreshCount + 2)
        XCTAssertEqual(recorder.requests.last?.form?["has_not_had_before"], "true")
    }

    @MainActor
    func testBreweryModelRetryBeersDistinguishesReloadAndLoadMoreErrors() async {
        final class State: @unchecked Sendable {
            var requests: [APIRequest] = []
            var failNext = false
        }
        let state = State()
        let beer1 = BeerLite(bid: 1, name: "Hop Bomb", brewery: "Test", style: "IPA", abv: 6.5, rating: 4.1)
        let beer2 = BeerLite(bid: 2, name: "Dark Star", brewery: "Test", style: "Stout", abv: 9.0, rating: 4.4)

        let model = BreweryModel(
            brewery: BreweryPreview(id: 42, name: "Test Brewery", label: nil),
            fetchBeers: { req in
                state.requests.append(req)
                if state.failNext {
                    state.failNext = false
                    throw APIError.http(503)
                }
                if req.query["offset"] == "1" {
                    return BreweryBeerList(beers: [beer2], total: 2)
                }
                if req.query["hasNotHadBefore"] == "true" {
                    return BreweryBeerList(beers: [beer2], total: 1)
                }
                return BreweryBeerList(beers: [beer1], total: 2)
            }
        )

        // Initial load succeeds with beer1 (total 2 -> hasMoreBeers == true)
        await model.applyFilter(BreweryBeerFilter())
        XCTAssertEqual(model.beers.map(\.bid), [1])
        XCTAssertTrue(model.hasMoreBeers)

        // Filter reload fails while beers is non-empty
        state.failNext = true
        await model.toggleHasNotHadBefore()
        XCTAssertNotNil(model.beersError)
        XCTAssertEqual(model.beers.map(\.bid), [1]) // retained previous list

        // Retry must re-run first-page filter reload (no offset), NOT loadMoreBeers
        await model.retryBeers()
        XCTAssertNil(model.beersError)
        XCTAssertNil(state.requests.last?.query["offset"])
        XCTAssertEqual(state.requests.last?.query["hasNotHadBefore"], "true")
        XCTAssertEqual(model.beers.map(\.bid), [2])

        // Reset back to unfiltered (total 2), then fail loadMoreBeers
        await model.resetFilters()
        state.failNext = true
        await model.loadMoreBeers()
        XCTAssertNotNil(model.beersError)
        XCTAssertEqual(model.beers.map(\.bid), [1])

        // Retry must re-run loadMoreBeers (offset == 1)
        await model.retryBeers()
        XCTAssertNil(model.beersError)
        XCTAssertEqual(state.requests.last?.query["offset"], "1")
        XCTAssertEqual(model.beers.map(\.bid), [1, 2])
    }
}
