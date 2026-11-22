import XCTest
@testable import Retappd

final class TopListsTests: XCTestCase {
    // MARK: - APIRequest Parameter Verification

    func testTopRatedBeersRequestParams() {
        let initial = APIRequest.topRatedBeers(includeStyles: true, includeCountries: true)
        XCTAssertEqual(initial.method, .get)
        XCTAssertEqual(initial.path, "/v4/beer/top_rated")
        XCTAssertEqual(initial.query, ["styles": "true", "countries": "true"])

        let filtered = APIRequest.topRatedBeers(
            styleId: 128,
            countryId: 86,
            inProduction: true,
            includeStyles: false,
            includeCountries: false
        )
        XCTAssertEqual(filtered.path, "/v4/beer/top_rated")
        XCTAssertEqual(filtered.query, [
            "type_id": "128",
            "country_id": "86",
            "in_production": "true",
        ])
        XCTAssertNil(filtered.query["styles"])
        XCTAssertNil(filtered.query["countries"])
    }

    func testTopRatedBreweriesRequestUsesNumericBreweryType() {
        let req = APIRequest.topRatedBreweries(countryId: 86, breweryTypeId: 2, includeCountries: true)
        XCTAssertEqual(req.method, .get)
        XCTAssertEqual(req.path, "/v4/brewery/top_rated")
        // Must be numeric brewery_type_id ("2"), never a slug like "micro_brewery".
        XCTAssertEqual(req.query["brewery_type"], "2")
        XCTAssertEqual(req.query["country_id"], "86")
        XCTAssertEqual(req.query["countries"], "true")

        let minimal = APIRequest.topRatedBreweries()
        XCTAssertTrue(minimal.query.isEmpty)
    }

    func testTrendingRequests() {
        let beers = APIRequest.trendingBeersGlobal
        XCTAssertEqual(beers.method, .get)
        XCTAssertEqual(beers.path, "/v4/beer/trending")
        XCTAssertNil(beers.query["type"])

        let venues = APIRequest.trendingVenuesGlobal
        XCTAssertEqual(venues.method, .get)
        XCTAssertEqual(venues.path, "/v4/venue/trending")
        XCTAssertEqual(venues.query["type"], "global")
    }

    // MARK: - Decoding: Top Rated Beers

    func testDecodeTopRatedBeersResponseAndEdgeCases() throws {
        let json = """
        {
          "meta": {"code": 200},
          "response": {
            "beers": {
              "count": 3,
              "items": [
                {
                  "has_had": true,
                  "beer": {
                    "bid": 1001,
                    "beer_name": "Kentucky Brunch Brand Stout",
                    "beer_label": "https://assets.untappd.com/site/beer_logos/beer-1001.jpeg",
                    "beer_abv": 12.0,
                    "beer_ibu": 70,
                    "beer_style": "Stout - Imperial / Double",
                    "rating_score": 4.78,
                    "rating_count": 4200,
                    "is_in_production": 1
                  },
                  "brewery": {
                    "brewery_id": 501,
                    "brewery_name": "Toppling Goliath Brewing Co.",
                    "brewery_label": "https://assets.untappd.com/site/brewery_logos/brewery-501.jpeg",
                    "country_name": "United States"
                  }
                },
                {
                  "has_had": "0",
                  "beer": {
                    "bid": "1002",
                    "beer_name": "Unrated Mystery",
                    "beer_abv": "6.5",
                    "rating_score": 0,
                    "rating_count": "0",
                    "is_in_production": false
                  },
                  "brewery": {
                    "brewery_id": "502",
                    "brewery_name": "Quiet Brewery"
                  }
                },
                {
                  "has_had": false,
                  "beer": {
                    "bid": 0,
                    "beer_name": "Invalid zero bid"
                  }
                }
              ]
            },
            "styles": {
              "count": 2,
              "items": [
                {"type_id": 128, "type_name": "IPA - American", "type_name_slug": "ipa-american"},
                {"type_id": "41", "type_name": "Stout - Imperial / Double", "type_name_slug": "stout-imperial-double"}
              ]
            },
            "countries": {
              "count": 2,
              "items": [
                {"country_id": 86, "country_name": "United States", "country_name_slug": "united-states"},
                {"country_id": "7", "country_name": "Australia", "country_name_slug": "australia"}
              ]
            }
          }
        }
        """

        let decoded = try UntappdAPI.decode(TopRatedBeersResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.beers.count, 2)

        let first = decoded.beers[0]
        XCTAssertEqual(first.id, 1001)
        XCTAssertEqual(first.beer.name, "Kentucky Brunch Brand Stout")
        XCTAssertEqual(first.beer.brewery, "Toppling Goliath Brewing Co.")
        XCTAssertEqual(first.beer.breweryId, 501)
        XCTAssertEqual(first.beer.abv, 12.0)
        XCTAssertEqual(first.beer.rating ?? 0, 4.78, accuracy: 0.001)
        XCTAssertEqual(first.beer.ratingCount, 4200)
        XCTAssertTrue(first.hasHad)
        XCTAssertEqual(first.beer.hasHad, true)
        XCTAssertEqual(first.isInProduction, true)

        let second = decoded.beers[1]
        XCTAssertEqual(second.id, 1002)
        XCTAssertEqual(second.beer.breweryId, 502)
        XCTAssertEqual(second.beer.abv ?? 0, 6.5, accuracy: 0.001)
        XCTAssertNil(second.beer.rating)
        XCTAssertEqual(second.beer.ratingCount, 0)
        XCTAssertFalse(second.hasHad)
        XCTAssertEqual(second.isInProduction, false)

        XCTAssertEqual(decoded.styles.map(\.id), [128, 41])
        XCTAssertEqual(decoded.styles.map(\.name), ["IPA - American", "Stout - Imperial / Double"])
        XCTAssertEqual(decoded.countries.map(\.id), [86, 7])
        XCTAssertEqual(decoded.countries.map(\.name), ["United States", "Australia"])
    }

    // MARK: - Decoding: Top Rated Breweries

    func testDecodeTopRatedBreweriesResponseAndEdgeCases() throws {
        let json = """
        {
          "meta": {"code": 200},
          "response": {
            "breweries": {
              "count": 2,
              "items": [
                {
                  "brewery": {
                    "brewery_id": 2001,
                    "brewery_name": "Side Project Brewing",
                    "brewery_type": "Micro Brewery",
                    "brewery_label": "https://assets.untappd.com/site/brewery_logos/2001.jpeg",
                    "country_name": "United States",
                    "location": {
                      "brewery_city": "Maplewood",
                      "brewery_state": "MO"
                    },
                    "rating_count": 125000,
                    "rating_score": 4.46,
                    "beer_count": 310
                  }
                },
                {
                  "brewery": {
                    "brewery_id": "2002",
                    "brewery_name": "Tiny Tap",
                    "brewery_type": "",
                    "country_name": "Australia",
                    "location": {
                      "brewery_city": "",
                      "brewery_state": ""
                    },
                    "rating_score": "0",
                    "beer_count": 1
                  }
                }
              ]
            },
            "brewery_types": {
              "count": 2,
              "items": [
                {"brewery_type_id": 2, "brewery_type_name_plain": "Micro Brewery", "brewery_type_slug": "micro_brewery"},
                {"brewery_type_id": "4", "brewery_type_name_plain": "Nano Brewery", "brewery_type_slug": "nano_brewery"}
              ]
            },
            "countries": {
              "count": 1,
              "items": [
                {"country_id": 86, "country_name": "United States", "country_name_slug": "united-states"}
              ]
            }
          }
        }
        """

        let decoded = try UntappdAPI.decode(TopRatedBreweriesResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.breweries.count, 2)

        let first = decoded.breweries[0]
        XCTAssertEqual(first.id, 2001)
        XCTAssertEqual(first.name, "Side Project Brewing")
        XCTAssertEqual(first.type, "Micro Brewery")
        XCTAssertEqual(first.locality, "Maplewood, MO, United States")
        XCTAssertEqual(first.subtitle, "Micro Brewery · Maplewood, MO, United States · 310 beers")
        XCTAssertEqual(first.rating ?? 0, 4.46, accuracy: 0.001)
        XCTAssertEqual(first.ratingCount, 125000)

        let second = decoded.breweries[1]
        XCTAssertEqual(second.id, 2002)
        XCTAssertNil(second.type)
        XCTAssertNil(second.rating)
        XCTAssertEqual(second.locality, "Australia")
        XCTAssertEqual(second.subtitle, "Australia · 1 beer")

        XCTAssertEqual(decoded.breweryTypes.map(\.id), [2, 4])
        XCTAssertEqual(decoded.breweryTypes.map(\.name), ["Micro Brewery", "Nano Brewery"])
        XCTAssertEqual(decoded.countries.map(\.id), [86])
    }

    // MARK: - Decoding: Trending Beers

    func testDecodeTrendingBeersResponse() throws {
        let json = """
        {
          "meta": {"code": 200},
          "response": {
            "micro": {
              "count": 1,
              "items": [
                {
                  "total_count": 842,
                  "your_count": 2,
                  "beer": {
                    "bid": 3001,
                    "beer_name": "Pliny the Elder",
                    "beer_label": "https://assets.untappd.com/site/beer_logos/3001.jpeg",
                    "beer_style": "IPA - Imperial / Double",
                    "beer_abv": 8.0,
                    "rating_score": 4.51
                  },
                  "brewery": {
                    "brewery_id": 601,
                    "brewery_name": "Russian River Brewing Company",
                    "brewery_label": "https://assets.untappd.com/site/brewery_logos/601.jpeg"
                  }
                }
              ]
            },
            "macro": {
              "count": 1,
              "items": [
                {
                  "total_count": "1520",
                  "your_count": "0",
                  "beer": {
                    "bid": "3002",
                    "beer_name": "Guinness Draught",
                    "beer_style": "Stout - Irish Dry",
                    "beer_abv": "4.2",
                    "rating_score": 0
                  },
                  "brewery": {
                    "brewery_id": "602",
                    "brewery_name": "Guinness"
                  }
                }
              ]
            }
          }
        }
        """

        let decoded = try UntappdAPI.decode(TrendingBeersResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.micro.count, 1)
        XCTAssertEqual(decoded.macro.count, 1)

        let craft = decoded.micro[0]
        XCTAssertEqual(craft.id, 3001)
        XCTAssertEqual(craft.totalCount, 842)
        XCTAssertEqual(craft.yourCount, 2)
        XCTAssertEqual(craft.beer.hasHad, true)
        XCTAssertEqual(craft.beer.rating ?? 0, 4.51, accuracy: 0.001)

        let macro = decoded.macro[0]
        XCTAssertEqual(macro.id, 3002)
        XCTAssertEqual(macro.totalCount, 1520)
        XCTAssertEqual(macro.yourCount, 0)
        XCTAssertNil(macro.beer.rating)
    }

    // MARK: - Decoding: Trending Venues

    func testDecodeTrendingVenuesResponse() throws {
        let json = """
        {
          "meta": {"code": 200},
          "response": {
            "items": [
              {
                "total_users": 137,
                "your_count": 3,
                "venue": {
                  "venue_id": 9001,
                  "venue_name": "Monk's Cafe",
                  "primary_category": "Beer Bar",
                  "categories": {
                    "count": 1,
                    "items": [{"category_name": "Beer Bar", "is_primary": true}]
                  },
                  "location": {
                    "venue_address": "264 S 16th St",
                    "venue_city": "Philadelphia",
                    "venue_state": "PA",
                    "lat": 39.9477,
                    "lng": -75.1683
                  },
                  "venue_icon": {
                    "md": "https://ss3.4sqi.net/img/categories_v2/nightlife/pub_bg_88.png"
                  },
                  "foursquare": {
                    "foursquare_id": "4a5b6c7d"
                  },
                  "is_verified": true
                }
              }
            ]
          }
        }
        """

        let decoded = try UntappdAPI.decode(TrendingVenuesResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.items.count, 1)
        let item = decoded.items[0]
        XCTAssertEqual(item.totalUsers, 137)
        XCTAssertEqual(item.yourCount, 3)
        XCTAssertEqual(item.venue.venueId, 9001)
        XCTAssertEqual(item.venue.foursquareId, "4a5b6c7d")
        XCTAssertEqual(item.venue.name, "Monk's Cafe")
        XCTAssertEqual(item.venue.category, "Beer Bar")
        XCTAssertEqual(item.venue.address, "264 S 16th St")
        XCTAssertEqual(item.venue.city, "Philadelphia")
        XCTAssertEqual(item.venue.state, "PA")
        XCTAssertEqual(item.venue.lat ?? 0, 39.9477, accuracy: 0.0001)
        XCTAssertEqual(item.venue.lng ?? 0, -75.1683, accuracy: 0.0001)
        XCTAssertTrue(item.venue.isVerified)
        XCTAssertEqual(item.venue.icon?.absoluteString, "https://ss3.4sqi.net/img/categories_v2/nightlife/pub_bg_88.png")
    }

    // MARK: - Model: Caching Styles/Countries & Filters

    @MainActor
    func testModelCachesStylesAndCountriesAcrossFilterChanges() async {
        var beerRequests: [APIRequest] = []
        var breweryRequests: [APIRequest] = []

        let ipa = TopListStyle(id: 128, name: "IPA - American")
        let usa = TopListCountry(id: 86, name: "United States")
        let microType = TopListBreweryType(id: 2, name: "Micro Brewery", slug: "micro_brewery")

        let model = GlobalTopListsModel(
            beersLoader: { req, _ in
                beerRequests.append(req)
                return TopRatedBeersResponse(
                    beers: [Self.sampleBeerItem(bid: 1, name: "Beer 1")],
                    styles: req.query["styles"] == "true" ? [ipa] : [],
                    countries: req.query["countries"] == "true" ? [usa] : []
                )
            },
            breweriesLoader: { req, _ in
                breweryRequests.append(req)
                return TopRatedBreweriesResponse(
                    breweries: [TopRatedBrewery(id: 10, name: "Brewery 10")],
                    breweryTypes: [microType],
                    countries: []
                )
            }
        )

        await model.loadBeers()
        XCTAssertEqual(beerRequests.count, 1)
        XCTAssertEqual(beerRequests[0].query["styles"], "true")
        XCTAssertEqual(beerRequests[0].query["countries"], "true")
        XCTAssertEqual(model.styles, [ipa])
        XCTAssertEqual(model.countries, [usa])

        // Applying a style filter must NOT re-request styles or countries.
        await model.setBeerStyle(ipa)
        XCTAssertEqual(beerRequests.count, 2)
        XCTAssertNil(beerRequests[1].query["styles"])
        XCTAssertNil(beerRequests[1].query["countries"])
        XCTAssertEqual(beerRequests[1].query["type_id"], "128")

        // Countries already cached from Beers tab, so Breweries tab skips countries=true.
        await model.loadBreweries()
        XCTAssertEqual(breweryRequests.count, 1)
        XCTAssertNil(breweryRequests[0].query["countries"])

        // Selecting a brewery type sends numeric brewery_type_id ("2").
        await model.setBreweryType(microType)
        XCTAssertEqual(breweryRequests.count, 2)
        XCTAssertEqual(breweryRequests[1].query["brewery_type"], "2")
    }

    // MARK: - Model: Generation Cancellation (Stale Response Guard)

    @MainActor
    func testStaleFilterResponseIsIgnored() async {
        var firstContinuation: CheckedContinuation<TopRatedBeersResponse, Error>?
        var callIndex = 0

        let styleA = TopListStyle(id: 10, name: "Stout")
        let styleB = TopListStyle(id: 20, name: "Pilsner")

        let model = GlobalTopListsModel(
            beersLoader: { req, _ in
                callIndex += 1
                if callIndex == 1 {
                    return try await withCheckedThrowingContinuation { cont in
                        firstContinuation = cont
                    }
                }
                return TopRatedBeersResponse(
                    beers: [Self.sampleBeerItem(bid: 200, name: "Fresh Pilsner")]
                )
            }
        )

        let slowTask = Task { await model.setBeerStyle(styleA) }
        // Yield so slowTask enters beersLoader and parks on firstContinuation.
        await Task.yield()

        // Rapidly switch filter to styleB, which completes immediately.
        await model.setBeerStyle(styleB)
        XCTAssertEqual(model.beers.map(\.id), [200])

        // Now complete the stale styleA request; its response must be ignored.
        firstContinuation?.resume(returning: TopRatedBeersResponse(
            beers: [Self.sampleBeerItem(bid: 100, name: "Stale Stout")]
        ))
        await slowTask.value

        XCTAssertEqual(model.beers.map(\.id), [200])
        XCTAssertEqual(model.beersFilter.style, styleB)
    }

    // MARK: - Model: Haven't Had Local Filter

    @MainActor
    func testHaventHadLocalFilterPreservesRanksAndAvoidsNetworkReload() async {
        var fetchCount = 0
        let hadIds: Set<Int> = [1, 3]

        let model = GlobalTopListsModel(
            beersLoader: { _, _ in
                fetchCount += 1
                return TopRatedBeersResponse(beers: [
                    Self.sampleBeerItem(bid: 1, name: "One"),
                    Self.sampleBeerItem(bid: 2, name: "Two"),
                    Self.sampleBeerItem(bid: 3, name: "Three"),
                    Self.sampleBeerItem(bid: 4, name: "Four"),
                ])
            },
            hasHad: { hadIds.contains($0.bid) }
        )

        await model.loadBeers()
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(model.visibleBeers.map(\.rank), [1, 2, 3, 4])

        // Toggle Haven't had -> filters locally without refetching, keeping original ranks #2 and #4.
        model.toggleHaventHad()
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(model.visibleBeers.map(\.id), [2, 4])
        XCTAssertEqual(model.visibleBeers.map(\.rank), [2, 4])

        // Resetting when only local filter is active does not refetch.
        await model.resetBeersFilters()
        XCTAssertEqual(fetchCount, 1)
        XCTAssertFalse(model.beersFilter.haventHad)
        XCTAssertEqual(model.visibleBeers.map(\.id), [1, 2, 3, 4])
    }

    // MARK: - Helpers

    private static func sampleBeerItem(bid: Int, name: String) -> TopRatedBeerItem {
        TopRatedBeerItem(
            beer: BeerLite(bid: bid, name: name, brewery: "Test Brewery", style: "IPA", abv: 6.5, rating: 4.25),
            hasHad: false,
            isInProduction: true
        )
    }
}
