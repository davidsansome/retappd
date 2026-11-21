import XCTest
@testable import Retappd

final class ModerationTests: XCTestCase {
    func testWebURLs() {
        XCTAssertEqual(UntappdWebURL.flagCheckin(1616041773)?.absoluteString,
                       "https://untappd.com/checkin/flag/1616041773")
        XCTAssertEqual(UntappdWebURL.reportUser("DrunkenMaster98")?.absoluteString,
                       "https://untappd.com/report/user?username=DrunkenMaster98")
        XCTAssertEqual(UntappdWebURL.reportUser("a b&c")?.absoluteString,
                       "https://untappd.com/report/user?username=a%20b%26c")
    }

    func testBlockAndMuteRequests() {
        let block = APIRequest.toggleBlockUser(6647432)
        XCTAssertEqual(block.method, .post)
        XCTAssertEqual(block.path, "/v4/account/block")
        XCTAssertEqual(block.form, ["target_id": "6647432"])

        let muteWeek = APIRequest.muteUser(6647432, days: 7)
        XCTAssertEqual(muteWeek.method, .post)
        XCTAssertEqual(muteWeek.path, "/v4/user/mute/6647432")
        XCTAssertEqual(muteWeek.form, ["period_of_time": "7"])

        let muteForever = APIRequest.muteUser(6647432, days: 0)
        XCTAssertEqual(muteForever.form, ["period_of_time": "0"])

        let unmute = APIRequest.unmuteUser(6647432)
        XCTAssertEqual(unmute.method, .post)
        XCTAssertEqual(unmute.path, "/v4/user/unmute/6647432")
        XCTAssertEqual(unmute.form, [:])
    }

    func testDecodesBlockUserResult() throws {
        let blocked = try UntappdAPI.decode(BlockUserResult.self, from: Data("""
        {"meta":{"code":200},"response":{"result":"success","method":"block","friendshipStatus":{"error":"You are not friends with this user."}}}
        """.utf8))
        XCTAssertEqual(blocked.method, "block")
        XCTAssertTrue(blocked.isBlocked)

        let unblocked = try UntappdAPI.decode(BlockUserResult.self, from: Data("""
        {"meta":{"code":200},"response":{"result":"success","method":"unblock","friendshipStatus":[]}}
        """.utf8))
        XCTAssertEqual(unblocked.method, "unblock")
        XCTAssertFalse(unblocked.isBlocked)
    }

    func testDecodesProfileBlockAndMuteStatus() throws {
        let normal = try UntappdAPI.decode(UserInfo.self, from: Data("""
        {"meta":{"code":200},"response":{"user":{"uid":9,"user_name":"alice","relationship":"friends","block_status":"none","mute_status":"unmute"}}}
        """.utf8)).user!
        XCTAssertFalse(normal.isBlocked)
        XCTAssertFalse(normal.isMuted)

        let blocked = try UntappdAPI.decode(UserInfo.self, from: Data("""
        {"meta":{"code":200},"response":{"user":{"uid":9,"user_name":"alice","relationship":"none","block_status":"blocked_you","mute_status":"unmute"}}}
        """.utf8)).user!
        XCTAssertTrue(blocked.isBlocked)
        XCTAssertFalse(blocked.isMuted)

        let muted = try UntappdAPI.decode(UserInfo.self, from: Data("""
        {"meta":{"code":200},"response":{"user":{"uid":9,"user_name":"alice","relationship":"friends","block_status":"none","mute_status":"mute"}}}
        """.utf8)).user!
        XCTAssertFalse(muted.isBlocked)
        XCTAssertTrue(muted.isMuted)
    }

    func testBlockedAndMutedListRequests() {
        XCTAssertEqual(APIRequest.blockedUsers.method, .get)
        XCTAssertEqual(APIRequest.blockedUsers.path, "/v4/user/blockusers")
        XCTAssertEqual(APIRequest.mutedUsers.method, .get)
        XCTAssertEqual(APIRequest.mutedUsers.path, "/v4/user/muteusers")
    }

    func testDecodesBlockedUsersResponse() throws {
        let response = try UntappdAPI.decode(BlockedUsersResponse.self, from: Data("""
        {
          "meta": {"code": 200},
          "response": {
            "count": 1,
            "items": [
              {
                "created_at": "Sat, 21 Nov 2026 12:07:46 +0000",
                "user": {
                  "uid": 13425056,
                  "user_name": "retappd-test-2",
                  "first_name": "Test 2",
                  "last_name": "Account",
                  "user_avatar": "https://example.com/a.jpg"
                }
              }
            ]
          }
        }
        """.utf8))
        XCTAssertEqual(response.items.count, 1)
        let item = try XCTUnwrap(response.items.first)
        XCTAssertEqual(item.id, 13425056)
        XCTAssertEqual(item.user.userName, "retappd-test-2")
        XCTAssertEqual(item.user.displayName, "Test 2 Account")
        XCTAssertNotNil(item.createdAt)
    }

    func testDecodesMutedUsersResponse() throws {
        let response = try UntappdAPI.decode(MutedUsersResponse.self, from: Data("""
        {
          "meta": {"code": 200},
          "response": {
            "count": 2,
            "items": [
              {
                "created_at": "Sat, 21 Nov 2026 12:07:45 +0000",
                "expire_date": "Sun, 22 Nov 2026 12:07:45 +0000",
                "mute_forever": 0,
                "period_of_time": 1,
                "user": {
                  "uid": 1,
                  "user_name": "timed",
                  "first_name": "Timed",
                  "last_name": "Friend"
                }
              },
              {
                "created_at": "Thu, 12 Dec 2024 14:44:56 +0000",
                "expire_date": "Thu, 01 Jan 1970 00:00:00 +0000",
                "mute_forever": 1,
                "period_of_time": 0,
                "user": {
                  "uid": 2,
                  "user_name": "forever",
                  "first_name": "Forever",
                  "last_name": "Friend"
                }
              }
            ]
          }
        }
        """.utf8))
        XCTAssertEqual(response.items.count, 2)

        let timed = response.items[0]
        XCTAssertEqual(timed.id, 1)
        XCTAssertFalse(timed.muteForever)
        XCTAssertEqual(timed.periodOfTime, 1)
        XCTAssertNotNil(timed.expireDate)

        let forever = response.items[1]
        XCTAssertEqual(forever.id, 2)
        XCTAssertTrue(forever.muteForever)
        XCTAssertEqual(forever.periodOfTime, 0)
        XCTAssertNil(forever.expireDate)
    }

    func testDecodesAccountSettingsModerationCounts() throws {
        let settings = try UntappdAPI.decode(AccountSettings.self, from: Data("""
        {
          "meta": {"code": 200},
          "response": {
            "user": {
              "is_private": 0,
              "user_block_count": 3,
              "user_mute_count": 5,
              "settings": {"is_search": 1, "public_toasts": 1}
            }
          }
        }
        """.utf8))
        XCTAssertEqual(settings.blockedUsersCount, 3)
        XCTAssertEqual(settings.mutedUsersCount, 5)
    }

    func testModerationSubtitles() {
        let user = User(id: 1, userName: "alice", firstName: "Alice", lastName: nil, avatar: nil)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let twoHoursAgo = now.addingTimeInterval(-7200)

        let blockedWithDate = BlockedUser(user: user, createdAt: twoHoursAgo)
        XCTAssertEqual(ModerationUserSubtitle.blocked(blockedWithDate, now: now), "@alice · blocked 2 hours ago")

        let blockedNoDate = BlockedUser(user: user, createdAt: nil)
        XCTAssertEqual(ModerationUserSubtitle.blocked(blockedNoDate, now: now), "@alice")

        let mutedForever = MutedUser(user: user, muteForever: true, periodOfTime: 0)
        XCTAssertEqual(ModerationUserSubtitle.muted(mutedForever), "@alice · muted forever")

        let expire = Date(timeIntervalSince1970: 1_700_086_400)
        let mutedTimed = MutedUser(user: user, expireDate: expire, muteForever: false, periodOfTime: 1)
        XCTAssertTrue(ModerationUserSubtitle.muted(mutedTimed).hasPrefix("@alice · until "))
    }
}
