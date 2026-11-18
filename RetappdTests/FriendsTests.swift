import XCTest
@testable import Retappd

final class FriendsTests: XCTestCase {
    // Shaped like the sample in docs/API.md for GET /v4/user/friends (the docs truncate each user,
    // so the names here are made up).
    private let json = """
    {"meta":{"code":200},"response":{"found":3,"count":3,"items":[
      {"friendship_hash":"a","created_at":"Sat, 04 Jul 2026 05:10:03 +0000","mutual_friends":{"count":0,"items":[]},
       "user":{"uid":6825036,"user_name":"Jackdup_","location":"Sydney","bio":"","is_supporter":0,
               "first_name":"Jack","last_name":"Dup","relationship":"friends","user_avatar":"https://x/a.jpg"}},
      {"friendship_hash":"b","created_at":"Sun, 05 Jul 2026 00:36:37 +0000","mutual_friends":{"count":0,"items":[]},
       "user":{"uid":6974987,"user_name":"adam_shaw_1519","location":"","bio":"",
               "first_name":"Adam","last_name":"Shaw","relationship":"friends"}},
      {"friendship_hash":"c","created_at":"Mon, 01 Jun 2026 10:00:00 +0000",
       "user":{"uid":7,"user_name":"zed","first_name":"Zoë","last_name":""}}
    ],"pagination":{"next_url":"https://api.untappd.com/v4/user/friends/sampleuser?utv=4.0.0&limit=10&offset=10","offset":10,"max_id":false}}}
    """

    private func page() throws -> FriendPage {
        try UntappdAPI.decode(FriendPage.self, from: Data(json.utf8))
    }

    func testDecodesFriendsPage() throws {
        let p = try page()
        XCTAssertEqual(p.found, 3)
        XCTAssertEqual(p.friends.count, 3)
        XCTAssertEqual(p.friends[0].user.userName, "Jackdup_")
        XCTAssertEqual(p.friends[0].location, "Sydney")
        XCTAssertNil(p.friends[1].location)  // empty string
        XCTAssertNotNil(p.friends[0].createdAt)
        XCTAssertEqual(p.friends[2].user.displayName, "Zoë")
    }

    func testSortsNewestFriendshipFirst() throws {
        let names = Friend.sortedByRecent(try page().friends).map(\.user.userName)
        XCTAssertEqual(names, ["adam_shaw_1519", "Jackdup_", "zed"])
    }

    func testUndatedFriendsSortLast() throws {
        var friends = try page().friends
        friends.append(Friend(user: User(id: 1, userName: "nodate", firstName: nil, lastName: nil, avatar: nil)))
        XCTAssertEqual(Friend.sortedByRecent(friends).last?.user.userName, "nodate")
    }

    func testFilterMatchesUsernameFirstAndLastName() throws {
        let friends = try page().friends
        XCTAssertEqual(Friend.filter(friends, matching: "").count, 3)
        XCTAssertEqual(Friend.filter(friends, matching: "SHAW").map(\.user.userName), ["adam_shaw_1519"])
        XCTAssertEqual(Friend.filter(friends, matching: "jack").map(\.user.userName), ["Jackdup_"])
        XCTAssertEqual(Friend.filter(friends, matching: "dup").map(\.user.userName), ["Jackdup_"])
        XCTAssertEqual(Friend.filter(friends, matching: "adam sh").map(\.user.userName), ["adam_shaw_1519"])
        XCTAssertEqual(Friend.filter(friends, matching: "zoe").map(\.user.userName), ["zed"])  // accents ignored
        XCTAssertTrue(Friend.filter(friends, matching: "nobody").isEmpty)
    }

    // Sample from docs/API.md for POST /v4/friend/request/{id}.
    func testFollowResponseIsWordedAsFollowing() throws {
        let json = """
        {"meta":{"code":200},"response":{"result":"success","request_type":"follow","friendship_type":"follow",
         "target_user":{"uid":8867567,"user_name":"KicksBrewing","first_name":"Jane","last_name":"Doe"}}}
        """
        let r = try UntappdAPI.decode(FriendRequestResult.self, from: Data(json.utf8))
        XCTAssertTrue(r.isFollow)
        XCTAssertEqual(r.confirmation, "Following")
    }

    func testNonFollowResponseIsAFriendRequest() throws {
        // Only "follow" was captured; the friend value here is an assumption.
        let r = try UntappdAPI.decode(FriendRequestResult.self, from: Data("""
        {"meta":{"code":200},"response":{"result":"success","request_type":"friend"}}
        """.utf8))
        XCTAssertEqual(r.confirmation, "Friend request sent")
    }

    func testSendRequestIsAPostToTheUserId() {
        let r = APIRequest.sendFriendRequest(42)
        XCTAssertEqual(r.method, .post)
        XCTAssertEqual(r.path, "/v4/friend/request/42")
    }

    func testUsernameNormalizing() {
        XCTAssertEqual(Friends.normalized("  @Jackdup_ "), "Jackdup_")
        XCTAssertNil(Friends.normalized("   "))
        XCTAssertNil(Friends.normalized("a/b"))
        XCTAssertNil(Friends.normalized("two words"))
    }

    func testAddStatus() throws {
        func profile(_ name: String, id: Int, rel: String?) throws -> UserInfo.Profile {
            let r = rel.map { "\"relationship\":\"\($0)\"," } ?? ""
            let info = try UntappdAPI.decode(UserInfo.self, from: Data("""
            {"meta":{"code":200},"response":{"user":{"uid":\(id),\(r)"user_name":"\(name)"}}}
            """.utf8))
            return info.user!
        }
        let ids: Set<Int> = [2]
        XCTAssertEqual(Friends.status(of: try profile("Me", id: 1, rel: nil), me: "me", friendIDs: ids), .you)
        XCTAssertEqual(Friends.status(of: try profile("a", id: 2, rel: nil), me: "me", friendIDs: ids), .friends)
        XCTAssertEqual(Friends.status(of: try profile("b", id: 3, rel: "friends"), me: "me", friendIDs: ids), .friends)
        XCTAssertEqual(Friends.status(of: try profile("c", id: 4, rel: "follow"), me: "me", friendIDs: ids), .following)
        XCTAssertEqual(Friends.status(of: try profile("d", id: 5, rel: "none"), me: "me", friendIDs: ids), .canAdd)
    }

    func testNotFoundErrors() {
        XCTAssertTrue(Friends.isNotFound(.server(code: 404, detail: nil)))
        XCTAssertTrue(Friends.isNotFound(.http(404)))
        XCTAssertFalse(Friends.isNotFound(.http(500)))
        XCTAssertFalse(Friends.isNotFound(.unauthorized))
    }
}
