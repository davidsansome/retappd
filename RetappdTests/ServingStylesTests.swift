import XCTest
@testable import Retappd

final class ServingStylesTests: XCTestCase {
    private func beerTypes() throws -> [ServingType] {
        let json = """
        {"count": 2, "items": [
          {"container_id": 3, "container_key": "draft", "container_name": "Draft", "container_position": "1"},
          {"container_id": 2, "container_key": "bottle", "container_name": "Bottle", "container_position": "2"}
        ]}
        """
        return try JSONDecoder().decode(ServingTypes.self, from: Data(json.utf8)).items
    }

    func testWhiskyGetsSpiritStyles() throws {
        let choices = ServingType.choices(forStyle: "Spirit - Whiskey - Scotch - Single Malt", beerTypes: try beerTypes())
        XCTAssertEqual(choices.map(\.name), ["Neat", "Taster", "Rocks", "Cocktail", "Mixer", "Shot"])
        XCTAssertEqual(choices.map(\.id), [16, 8, 17, 13, 18, 19])
    }

    func testGinGetsSpiritStyles() throws {
        XCTAssertEqual(ServingType.choices(forStyle: "Spirit - Gin - London Dry", beerTypes: try beerTypes()),
                       ServingType.spirits)
    }

    func testBeerAndOtherDrinksKeepTheAPIList() throws {
        let beer = try beerTypes()
        for style in ["IPA - American", "Stout - Irish Dry", "Cider - Dry", "Mead - Braggot",
                      "RTD - Spritz", "Sake - Other", "Winter Ale", nil] {
            XCTAssertEqual(ServingType.choices(forStyle: style, beerTypes: beer), beer, "\(style ?? "nil")")
        }
    }

    func testWineGetsWineStyles() throws {
        let choices = ServingType.choices(forStyle: "Wine - Sauvignon Blanc", beerTypes: try beerTypes())
        XCTAssertEqual(choices.map(\.name), ["Bottle", "Taster", "Draft", "Can", "Box", "Cocktail"])
        XCTAssertEqual(choices.map(\.id), [2, 8, 3, 1, 12, 13])
    }

    func testSpiritDetectionIgnoresCaseAndSpace() {
        XCTAssertTrue(ServingType.isSpirit(style: " spirit - Rum"))
        XCTAssertFalse(ServingType.isSpirit(style: "Spirited Pale Ale"))
        XCTAssertTrue(ServingType.isWine(style: "wine - Rosé"))
        XCTAssertFalse(ServingType.isWine(style: "Winter Warmer"))
    }
}
