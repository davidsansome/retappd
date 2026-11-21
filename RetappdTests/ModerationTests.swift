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
}
