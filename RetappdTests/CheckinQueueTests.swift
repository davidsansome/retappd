import XCTest
import UIKit
import UserNotifications
@testable import Retappd

// MARK: - Mocks

private final class MockCheckinTransport: CheckinBackgroundTransport {
    struct RecordedUpload {
        var request: URLRequest
        var fileURL: URL
        var fileBytes: Data?
        var taskDescription: String
    }

    weak var delegate: CheckinBackgroundTransportDelegate?

    var uploads: [RecordedUpload] = []
    var activeTaskList: [ActiveBackgroundTask] = []
    var holdActiveTasks = false
    private var activeTasksContinuation: CheckedContinuation<[ActiveBackgroundTask], Never>?
    var isHoldingActiveTasks: Bool { activeTasksContinuation != nil }
    var cancelledJobIDs: [UUID] = []
    var cancelAllCount = 0

    func releaseActiveTasks() {
        holdActiveTasks = false
        let cont = activeTasksContinuation
        activeTasksContinuation = nil
        cont?.resume(returning: activeTaskList)
    }

    func startUpload(request: URLRequest, fromFile fileURL: URL, taskDescription: String) {
        let bytes = try? Data(contentsOf: fileURL)
        uploads.append(RecordedUpload(
            request: request,
            fileURL: fileURL,
            fileBytes: bytes,
            taskDescription: taskDescription
        ))
    }

    func activeTasks() async -> [ActiveBackgroundTask] {
        if holdActiveTasks {
            return await withCheckedContinuation { activeTasksContinuation = $0 }
        }
        return activeTaskList
    }

    func cancelTasks(matching jobID: UUID) async {
        cancelledJobIDs.append(jobID)
    }

    func cancelAllTasks() async {
        cancelAllCount += 1
        activeTaskList.removeAll()
    }

    @MainActor
    func complete(
        taskDescription: String,
        status: Int = 200,
        json: String = "",
        error: Error? = nil
    ) {
        let url = URL(string: "https://api.untappd.com/v4/test")!
        let response = error == nil
            ? HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
            : nil
        delegate?.transportDidComplete(
            taskDescription: taskDescription,
            response: response,
            data: Data(json.utf8),
            error: error
        )
    }

    @MainActor
    func finishBackgroundEvents() {
        delegate?.transportDidFinishBackgroundEvents()
    }
}

private final class MockBackgroundTaskBeginner: BackgroundTaskBeginner {
    var begunNames: [String] = []
    var endedIDs: [UIBackgroundTaskIdentifier] = []
    private var nextRaw = 1

    @MainActor
    func beginBackgroundTask(name: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        begunNames.append(name)
        let id = UIBackgroundTaskIdentifier(rawValue: nextRaw)
        nextRaw += 1
        return id
    }

    @MainActor
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        endedIDs.append(identifier)
    }
}

// MARK: - Tests

@MainActor
final class CheckinQueueTests: XCTestCase {
    private var tempDir: URL!
    private var transport: MockCheckinTransport!
    private var bgTasks: MockBackgroundTaskBeginner!
    private var center: NotificationCenter!
    private var appActive = true
    private var authStatus: UNAuthorizationStatus = .authorized
    private var scheduledNotifications: [(UUID, String)] = []
    private var hapticCount = 0
    private var savedBeerIDs: [Int] = []
    private var savedVenues: [(venue: Venue?, checkinId: Int?)] = []
    private var unauthorizedCount = 0

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CheckinQueueTests-\(UUID().uuidString)", isDirectory: true)
        transport = MockCheckinTransport()
        bgTasks = MockBackgroundTaskBeginner()
        center = NotificationCenter()
        appActive = true
        authStatus = .authorized
        scheduledNotifications = []
        hapticCount = 0
        savedBeerIDs = []
        savedVenues = []
        unauthorizedCount = 0
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeQueue(
        transport: MockCheckinTransport? = nil,
        jpegBytes: Data? = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
    ) -> CheckinQueue {
        CheckinQueue(
            transport: transport ?? self.transport,
            storageDirectory: tempDir,
            backgroundTasks: bgTasks,
            imageEncoder: { _ in jpegBytes },
            tokenProvider: { "test-token" },
            onUnauthorized: { [weak self] in self?.unauthorizedCount += 1 },
            notificationCenter: center,
            isAppActive: { [weak self] in self?.appActive ?? true },
            notificationAuthStatus: { [weak self] in self?.authStatus ?? .notDetermined },
            scheduleFailureNotification: { [weak self] id, beer in
                self?.scheduledNotifications.append((id, beer))
            },
            onSuccessHaptic: { [weak self] in self?.hapticCount += 1 },
            onCheckinSaved: { [weak self] bid, _, _, venue, checkinId in
                self?.savedBeerIDs.append(bid)
                self?.savedVenues.append((venue, checkinId))
            },
            toastDuration: .milliseconds(50)
        )
    }

    private func sampleDraft(bid: Int = 42, venue: Venue? = nil) -> NewCheckinDraft {
        NewCheckinDraft(
            beerBid: bid,
            foursquareId: "fsq-1",
            lat: -37.8136,
            lng: 144.9631,
            rating: 4.25,
            shout: "Crisp and piney",
            containerId: 1,
            taggedUserIds: [10, 20],
            purchaseFoursquareId: "shop-1",
            flavorIds: [5],
            venue: venue
        )
    }

    private func sampleImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        return renderer.image { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    private func sampleCheckin(id: Int = 999) throws -> Checkin {
        let json = """
        {
          "checkin_id": \(id),
          "rating_score": 3.75,
          "checkin_comment": "Original comment",
          "beer": { "bid": 42, "beer_name": "Pacific Ale" },
          "brewery": { "brewery_id": 7, "brewery_name": "Stone & Wood" },
          "venue": { "venue_id": 100, "venue_name": "The Local", "foursquare": { "foursquare_id": "v-fsq-1" }, "location": { "lat": -37.8, "lng": 144.9 } },
          "retail_venue": [],
          "serving_type": "Draft"
        }
        """
        return try JSONDecoder().decode(Checkin.self, from: Data(json.utf8))
    }

    private func waitForUploads(in transport: MockCheckinTransport? = nil, count: Int) async {
        let t = transport ?? self.transport!
        await waitUntil { t.uploads.count >= count }
    }

    private func waitUntil(timeout: Duration = .seconds(2), condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    // MARK: (a) No-photo happy path + .didCheckIn

    func testNoPhotoHappyPathPostsDidCheckIn() async {
        let queue = makeQueue()
        var didCheckInCount = 0
        let token = center.addObserver(forName: .didCheckIn, object: nil, queue: nil) { _ in
            didCheckInCount += 1
        }
        defer { center.removeObserver(token) }

        let venue = Venue(venueId: 77, foursquareId: "fsq-1", name: "The Taproom", isVerified: false)
        let jobID = queue.enqueueNew(sampleDraft(venue: venue), beerName: "Pacific Ale", breweryName: "Stone & Wood",
                                     username: "alice", photo: nil)
        await waitForUploads(count: 1)

        XCTAssertEqual(transport.uploads.count, 1)
        let upload = transport.uploads[0]
        XCTAssertNil(upload.request.httpBody, "Background URLSession upload must have nil httpBody")
        XCTAssertEqual(upload.request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(upload.taskDescription, CheckinQueue.taskDescription(jobID, .step1))
        XCTAssertEqual(queue.jobs.first?.phase, .submittingCheckin)

        let step1JSON = #"{"meta":{"code":200},"response":{"result":"success","checkin_id":12345}}"#
        transport.complete(taskDescription: upload.taskDescription, status: 200, json: step1JSON)

        XCTAssertTrue(queue.jobs.isEmpty)
        XCTAssertEqual(didCheckInCount, 1)
        XCTAssertEqual(savedBeerIDs, [42])
        XCTAssertEqual(savedVenues.count, 1)
        XCTAssertEqual(savedVenues.first?.venue?.venueId, 77)
        XCTAssertEqual(savedVenues.first?.checkinId, 12345)
        XCTAssertEqual(hapticCount, 1)
        XCTAssertEqual(queue.completedToast?.message, "Checked in Pacific Ale")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(jobID.uuidString).path))
        XCTAssertEqual(bgTasks.begunNames.count, bgTasks.endedIDs.count)
    }

    // MARK: (b) Photo 3-step happy path + disk cleanup

    func testPhotoThreeStepHappyPathAndDiskCleanup() async {
        let queue = makeQueue()
        var didCheckInCount = 0
        let token = center.addObserver(forName: .didCheckIn, object: nil, queue: nil) { _ in
            didCheckInCount += 1
        }
        defer { center.removeObserver(token) }

        let jobID = queue.enqueueNew(sampleDraft(), beerName: "Hazy IPA", breweryName: "Range",
                                     username: "alice", photo: sampleImage())
        await waitForUploads(count: 1)

        // Step 1
        let step1 = transport.uploads[0]
        XCTAssertEqual(step1.taskDescription, CheckinQueue.taskDescription(jobID, .step1))
        let step1JSON = """
        {
          "meta": {"code": 200},
          "response": {
            "result": "success",
            "checkin_id": 555,
            "photo_upload": {
              "url": "https://s3.amazonaws.com/untappd-upload/presigned-1",
              "destination_url": "https://assets.untappd.com/photos/555.jpg"
            }
          }
        }
        """
        transport.complete(taskDescription: step1.taskDescription, status: 200, json: step1JSON)

        // Step 2 (S3 PUT without Untappd headers)
        XCTAssertEqual(transport.uploads.count, 2)
        let step2 = transport.uploads[1]
        XCTAssertEqual(step2.taskDescription, CheckinQueue.taskDescription(jobID, .step2))
        XCTAssertEqual(step2.request.httpMethod, "PUT")
        XCTAssertEqual(step2.request.url?.absoluteString, "https://s3.amazonaws.com/untappd-upload/presigned-1")
        XCTAssertEqual(step2.request.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertNil(step2.request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(step2.request.value(forHTTPHeaderField: "X-Untappd-App"))
        XCTAssertNil(step2.request.httpBody)
        XCTAssertEqual(queue.jobs.first?.phase, .uploadingPhoto(
            checkinId: 555,
            uploadURL: URL(string: "https://s3.amazonaws.com/untappd-upload/presigned-1")!,
            destinationURL: URL(string: "https://assets.untappd.com/photos/555.jpg")!
        ))
        transport.complete(taskDescription: step2.taskDescription, status: 200)

        // Step 3 (photoUploadComplete)
        XCTAssertEqual(transport.uploads.count, 3)
        let step3 = transport.uploads[2]
        XCTAssertEqual(step3.taskDescription, CheckinQueue.taskDescription(jobID, .step3))
        XCTAssertTrue(step3.request.url?.path.contains("/v4/photo/uploadComplete") == true)
        XCTAssertEqual(step3.request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertNil(step3.request.httpBody)
        let step3Body = String(data: step3.fileBytes ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(step3Body.contains("checkin_id=555"))
        XCTAssertEqual(queue.jobs.first?.phase, .completingPhoto(
            checkinId: 555,
            destinationURL: URL(string: "https://assets.untappd.com/photos/555.jpg")!
        ))

        transport.complete(taskDescription: step3.taskDescription, status: 200,
                           json: #"{"meta":{"code":200},"response":{"result":"success"}}"#)

        XCTAssertTrue(queue.jobs.isEmpty)
        XCTAssertEqual(didCheckInCount, 2, "Expected .didCheckIn after Step 1 save and after Step 3 photo completion")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(jobID.uuidString).path))
    }

    // MARK: (c) Step 1 failure -> retry succeeds

    func testStep1FailureAndRetrySucceeds() async {
        let queue = makeQueue()
        let jobID = queue.enqueueNew(sampleDraft(), beerName: "Lager", breweryName: "Brew",
                                     username: "alice", photo: nil)
        await waitForUploads(count: 1)

        transport.complete(
            taskDescription: transport.uploads[0].taskDescription,
            status: 500,
            json: #"{"meta":{"code":500,"error_detail":"Server busy"}}"#
        )

        guard case .failed(let step, let msg) = queue.jobs.first?.phase else {
            return XCTFail("Expected failed phase")
        }
        XCTAssertEqual(step, .checkin)
        XCTAssertEqual(msg, "Server busy")

        queue.retry(jobID)
        XCTAssertEqual(transport.uploads.count, 2)
        XCTAssertEqual(transport.uploads[1].taskDescription, CheckinQueue.taskDescription(jobID, .step1))

        transport.complete(
            taskDescription: transport.uploads[1].taskDescription,
            status: 200,
            json: #"{"meta":{"code":200},"response":{"result":"success","checkin_id":777}}"#
        )
        XCTAssertTrue(queue.jobs.isEmpty)
    }

    // MARK: (d) Step 2 failure -> retry does NOT re-call Step 1

    func testStep2FailureRetryDoesNotReCallStep1() async {
        let queue = makeQueue()
        let jobID = queue.enqueueNew(sampleDraft(), beerName: "Stout", breweryName: "Brew",
                                     username: "alice", photo: sampleImage())
        await waitForUploads(count: 1)

        let uploadURL = "https://s3.amazonaws.com/upload/abc"
        let destURL = "https://assets.untappd.com/photos/888.jpg"
        transport.complete(
            taskDescription: transport.uploads[0].taskDescription,
            status: 200,
            json: #"{"meta":{"code":200},"response":{"checkin_id":888,"photo_upload":{"url":"\#(uploadURL)","destination_url":"\#(destURL)"}}}"#
        )
        XCTAssertEqual(transport.uploads.count, 2)

        // Fail Step 2 with network error
        transport.complete(
            taskDescription: transport.uploads[1].taskDescription,
            error: URLError(.networkConnectionLost)
        )

        guard case .failed(let step, _) = queue.jobs.first?.phase else {
            return XCTFail("Expected failed phase")
        }
        XCTAssertEqual(step, .photoUpload(checkinId: 888, uploadURL: URL(string: uploadURL)!, destinationURL: URL(string: destURL)!))
        XCTAssertTrue(queue.jobs.first?.checkinAlreadySaved == true)

        // Retry: must start Step 2 directly, NEVER Step 1!
        queue.retry(jobID)
        XCTAssertEqual(transport.uploads.count, 3)
        XCTAssertEqual(transport.uploads[2].taskDescription, CheckinQueue.taskDescription(jobID, .step2))
        let step1Count = transport.uploads.filter { $0.taskDescription.hasSuffix("|step1") }.count
        XCTAssertEqual(step1Count, 1)

        // Complete Step 2 -> Step 3
        transport.complete(taskDescription: transport.uploads[2].taskDescription, status: 200)
        XCTAssertEqual(transport.uploads.count, 4)
        XCTAssertEqual(transport.uploads[3].taskDescription, CheckinQueue.taskDescription(jobID, .step3))
        transport.complete(taskDescription: transport.uploads[3].taskDescription, status: 200,
                           json: #"{"meta":{"code":200},"response":{"result":"success"}}"#)
        XCTAssertTrue(queue.jobs.isEmpty)
    }

    // MARK: (e) Step 2 HTTP 403 expired URL -> refreshes via editCheckin -> succeeds

    func testStep2HTTP403RefreshesPresignedURLAndSucceeds() async {
        let queue = makeQueue()
        let jobID = queue.enqueueNew(sampleDraft(), beerName: "Pilsner", breweryName: "Brew",
                                     username: "alice", photo: sampleImage())
        await waitForUploads(count: 1)

        let expiredURL = "https://s3.amazonaws.com/upload/expired"
        let freshURL = "https://s3.amazonaws.com/upload/fresh"
        let destURL = "https://assets.untappd.com/photos/901.jpg"

        transport.complete(
            taskDescription: transport.uploads[0].taskDescription,
            status: 200,
            json: #"{"meta":{"code":200},"response":{"checkin_id":901,"photo_upload":{"url":"\#(expiredURL)","destination_url":"\#(destURL)"}}}"#
        )
        XCTAssertEqual(transport.uploads.count, 2)

        // S3 returns 403 Forbidden (expired presigned URL)
        transport.complete(taskDescription: transport.uploads[1].taskDescription, status: 403)

        // Queue automatically calls editCheckin (step2refresh) with is_photo=true
        XCTAssertEqual(transport.uploads.count, 3)
        let refresh = transport.uploads[2]
        XCTAssertEqual(refresh.taskDescription, CheckinQueue.taskDescription(jobID, .step2refresh))
        XCTAssertTrue(refresh.request.url?.path.contains("/v4/checkin/edit/901") == true)
        let refreshBody = String(data: refresh.fileBytes ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(refreshBody.contains("is_photo=true"))

        // Refresh succeeds with fresh presigned URL -> retries Step 2 with freshURL
        transport.complete(
            taskDescription: refresh.taskDescription,
            status: 200,
            json: #"{"meta":{"code":200},"response":{"photo_upload":{"url":"\#(freshURL)","destination_url":"\#(destURL)"}}}"#
        )
        XCTAssertEqual(transport.uploads.count, 4)
        XCTAssertEqual(transport.uploads[3].taskDescription, CheckinQueue.taskDescription(jobID, .step2))
        XCTAssertEqual(transport.uploads[3].request.url?.absoluteString, freshURL)

        // Step 2 -> Step 3 -> Done
        transport.complete(taskDescription: transport.uploads[3].taskDescription, status: 200)
        XCTAssertEqual(transport.uploads.count, 5)
        XCTAssertEqual(transport.uploads[4].taskDescription, CheckinQueue.taskDescription(jobID, .step3))
        transport.complete(taskDescription: transport.uploads[4].taskDescription, status: 200,
                           json: #"{"meta":{"code":200},"response":{"result":"success"}}"#)
        XCTAssertTrue(queue.jobs.isEmpty)
    }

    // MARK: (f) Step 3 failure -> retry does NOT re-call Step 1 or Step 2

    func testStep3FailureRetryDoesNotReCallStep1OrStep2() async {
        let queue = makeQueue()
        let jobID = queue.enqueueNew(sampleDraft(), beerName: "Sour", breweryName: "Brew",
                                     username: "alice", photo: sampleImage())
        await waitForUploads(count: 1)

        let uploadURL = "https://s3.amazonaws.com/upload/u"
        let destURL = "https://assets.untappd.com/photos/333.jpg"
        transport.complete(
            taskDescription: transport.uploads[0].taskDescription,
            status: 200,
            json: #"{"meta":{"code":200},"response":{"checkin_id":333,"photo_upload":{"url":"\#(uploadURL)","destination_url":"\#(destURL)"}}}"#
        )
        transport.complete(taskDescription: transport.uploads[1].taskDescription, status: 200)
        XCTAssertEqual(transport.uploads.count, 3)

        // Fail Step 3
        transport.complete(taskDescription: transport.uploads[2].taskDescription, status: 503)

        guard case .failed(let step, _) = queue.jobs.first?.phase else {
            return XCTFail("Expected failed phase")
        }
        XCTAssertEqual(step, .photoComplete(checkinId: 333, destinationURL: URL(string: destURL)!))

        // Retry: ONLY Step 3 runs
        queue.retry(jobID)
        XCTAssertEqual(transport.uploads.count, 4)
        XCTAssertEqual(transport.uploads[3].taskDescription, CheckinQueue.taskDescription(jobID, .step3))
        XCTAssertEqual(transport.uploads.filter { $0.taskDescription.hasSuffix("|step1") }.count, 1)
        XCTAssertEqual(transport.uploads.filter { $0.taskDescription.hasSuffix("|step2") }.count, 1)

        transport.complete(taskDescription: transport.uploads[3].taskDescription, status: 200,
                           json: #"{"meta":{"code":200},"response":{"result":"success"}}"#)
        XCTAssertTrue(queue.jobs.isEmpty)
    }

    // MARK: (g) Persistence & reload across simulated app kill + taskDescription correlation

    func testPersistenceAndReloadMatchesActiveBackgroundTask() async {
        let queue1 = makeQueue()
        let jobID = queue1.enqueueNew(sampleDraft(), beerName: "Pale Ale", breweryName: "Brew",
                                      username: "alice", photo: sampleImage())
        await waitForUploads(count: 1)
        let step1Desc = transport.uploads[0].taskDescription

        // Simulate app termination and relaunch with a fresh CheckinQueue & transport
        // where iOS still has the Step 1 task running in the background URLSession.
        let transport2 = MockCheckinTransport()
        transport2.activeTaskList = [ActiveBackgroundTask(taskDescription: step1Desc)]
        let queue2 = makeQueue(transport: transport2)
        queue2.start()
        await queue2.reconcile()

        // Job stayed in .submittingCheckin (not marked failed) because the task is active.
        XCTAssertEqual(queue2.jobs.count, 1)
        XCTAssertEqual(queue2.jobs[0].id, jobID)
        XCTAssertEqual(queue2.jobs[0].phase, .submittingCheckin)

        // Background URLSession wakes the relaunched app and delivers Step 1 completion.
        var bgHandlerCalled = false
        queue2.handleBackgroundSessionEvents(identifier: BackgroundURLSessionTransport.sessionIdentifier) {
            bgHandlerCalled = true
        }
        let step1JSON = #"{"meta":{"code":200},"response":{"checkin_id":444,"photo_upload":{"url":"https://s3.test/p","destination_url":"https://cdn.test/444.jpg"}}}"#
        transport2.complete(taskDescription: step1Desc, status: 200, json: step1JSON)

        // Step 2 must already be enqueued BEFORE background events completion handler fires.
        XCTAssertEqual(transport2.uploads.count, 1)
        XCTAssertEqual(transport2.uploads[0].taskDescription, CheckinQueue.taskDescription(jobID, .step2))
        XCTAssertFalse(bgHandlerCalled)

        transport2.finishBackgroundEvents()
        XCTAssertTrue(bgHandlerCalled)
    }

    // MARK: (h) Orphan .submittingCheckin reconciliation marks failed (never silently double-posts)

    func testOrphanSubmittingCheckinMarksFailedInsteadOfDoublePosting() async {
        let queue1 = makeQueue()
        let jobID = queue1.enqueueNew(sampleDraft(), beerName: "Amber", breweryName: "Brew",
                                      username: "alice", photo: nil)
        await waitForUploads(count: 1)

        // Relaunch with NO active background tasks in the session
        let transport2 = MockCheckinTransport()
        transport2.activeTaskList = []
        let queue2 = makeQueue(transport: transport2)
        queue2.start()
        await queue2.reconcile()

        XCTAssertEqual(transport2.uploads.count, 0, "Must never silently re-POST Step 1")
        XCTAssertEqual(queue2.jobs.count, 1)
        XCTAssertEqual(queue2.jobs[0].id, jobID)
        guard case .failed(let step, _) = queue2.jobs[0].phase else {
            return XCTFail("Orphan .submittingCheckin must be marked failed")
        }
        XCTAssertEqual(step, .checkin)
    }

    // MARK: (i) Orphan .uploadingPhoto and .completingPhoto automatically resume

    func testOrphanUploadingPhotoAndCompletingPhotoAutoResume() async {
        let queue1 = makeQueue()
        let jobID1 = queue1.enqueueNew(sampleDraft(bid: 1), beerName: "Beer 1", breweryName: "Brew",
                                       username: "alice", photo: sampleImage())
        let jobID2 = queue1.enqueueNew(sampleDraft(bid: 2), beerName: "Beer 2", breweryName: "Brew",
                                       username: "alice", photo: sampleImage())
        await waitForUploads(count: 2)

        // Advance job1 to .uploadingPhoto
        let upload1 = transport.uploads.first { $0.taskDescription == CheckinQueue.taskDescription(jobID1, .step1) }!
        transport.complete(
            taskDescription: upload1.taskDescription,
            status: 200,
            json: #"{"meta":{"code":200},"response":{"checkin_id":101,"photo_upload":{"url":"https://s3.test/1","destination_url":"https://cdn.test/1.jpg"}}}"#
        )

        // Advance job2 to .completingPhoto
        let upload2 = transport.uploads.first { $0.taskDescription == CheckinQueue.taskDescription(jobID2, .step1) }!
        transport.complete(
            taskDescription: upload2.taskDescription,
            status: 200,
            json: #"{"meta":{"code":200},"response":{"checkin_id":102,"photo_upload":{"url":"https://s3.test/2","destination_url":"https://cdn.test/2.jpg"}}}"#
        )
        let step2ForJob2 = transport.uploads.first { $0.taskDescription == CheckinQueue.taskDescription(jobID2, .step2) }!
        transport.complete(taskDescription: step2ForJob2.taskDescription, status: 200)

        // Relaunch with NO active tasks: both safe phases must automatically re-enqueue
        let transport2 = MockCheckinTransport()
        transport2.activeTaskList = []
        let queue2 = makeQueue(transport: transport2)
        queue2.start()
        await queue2.reconcile()

        let descriptions = Set(transport2.uploads.map(\.taskDescription))
        XCTAssertTrue(descriptions.contains(CheckinQueue.taskDescription(jobID1, .step2)))
        XCTAssertTrue(descriptions.contains(CheckinQueue.taskDescription(jobID2, .step3)))
    }

    // MARK: (j) File protection completeUntilFirstUserAuthentication

    func testPersistedFilesUseCompleteUntilFirstUserAuthentication() async throws {
        let queue = makeQueue()
        let jobID = queue.enqueueNew(sampleDraft(), beerName: "IPA", breweryName: "Brew",
                                     username: "alice", photo: sampleImage())
        await waitForUploads(count: 1)

        let filesToCheck = [
            tempDir.appendingPathComponent("jobs.json"),
            tempDir.appendingPathComponent(jobID.uuidString).appendingPathComponent("photo.jpg"),
            tempDir.appendingPathComponent(jobID.uuidString).appendingPathComponent("step1.form"),
        ]
        var checkedAttributes = 0
        for file in filesToCheck {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Missing \(file.lastPathComponent)")
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            if let protection = attrs[.protectionKey] as? FileProtectionType {
                checkedAttributes += 1
                XCTAssertEqual(protection, .completeUntilFirstUserAuthentication,
                               "Unexpected protection on \(file.lastPathComponent)")
            }
        }
        try XCTSkipIf(checkedAttributes == 0, "File protection attributes are not exposed on this simulator filesystem")
    }

    // MARK: (k) cancelAllForSignOut cancels & wipes jobs

    func testCancelAllForSignOutCancelsAndWipesJobs() async throws {
        let queue = makeQueue()
        let jobID = queue.enqueueNew(sampleDraft(), beerName: "IPA", breweryName: "Brew",
                                     username: "alice", photo: sampleImage())
        await waitForUploads(count: 1)
        XCTAssertEqual(queue.jobs.count, 1)

        queue.cancelAllForSignOut()
        await waitUntil { self.transport.cancelledJobIDs.contains(jobID) }

        XCTAssertTrue(queue.jobs.isEmpty)
        XCTAssertNil(queue.completedToast)
        XCTAssertTrue(transport.cancelledJobIDs.contains(jobID))
        XCTAssertEqual(transport.cancelAllCount, 0, "Should cancel only snapshotted jobs, not future sessions")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(jobID.uuidString).path))
        let jobsData = try Data(contentsOf: tempDir.appendingPathComponent("jobs.json"))
        XCTAssertEqual(try JSONDecoder().decode([QueuedCheckin].self, from: jobsData), [])
    }

    // MARK: (l) Edit check-in flow posts .checkinEdited

    func testEditCheckinPostsCheckinEditedWithUpdatedFields() async throws {
        let queue = makeQueue()
        let original = try sampleCheckin(id: 999)
        let newShop = Venue(venueId: 50, foursquareId: "shop-fsq-50", name: "Bottle Shop", isVerified: false)
        let serving = try JSONDecoder().decode(
            ServingType.self,
            from: Data(#"{"container_id": 2, "container_name": "Can"}"#.utf8)
        )

        var editedCheckin: Checkin?
        let token = center.addObserver(forName: .checkinEdited, object: nil, queue: nil) { note in
            editedCheckin = note.object as? Checkin
        }
        defer { center.removeObserver(token) }

        let jobID = queue.enqueueEdit(original, rating: 4.5, shout: "Updated note", serving: serving,
                                      shop: newShop, username: "alice", photo: sampleImage())
        await waitForUploads(count: 1)

        // Step 1: editCheckin
        let step1 = transport.uploads[0]
        XCTAssertTrue(step1.request.url?.path.contains("/v4/checkin/edit/999") == true)
        let destURL = "https://assets.untappd.com/photos/999-new.jpg"
        transport.complete(
            taskDescription: step1.taskDescription,
            status: 200,
            json: #"{"meta":{"code":200},"response":{"result":"success","photo_upload":{"url":"https://s3.test/edit","destination_url":"\#(destURL)"}}}"#
        )

        // Step 2: S3 PUT
        XCTAssertEqual(transport.uploads.count, 2)
        transport.complete(taskDescription: transport.uploads[1].taskDescription, status: 200)

        // Step 3: photoUploadComplete
        XCTAssertEqual(transport.uploads.count, 3)
        XCTAssertEqual(transport.uploads[2].taskDescription, CheckinQueue.taskDescription(jobID, .step3))
        transport.complete(taskDescription: transport.uploads[2].taskDescription, status: 200,
                           json: #"{"meta":{"code":200},"response":{"result":"success"}}"#)

        XCTAssertTrue(queue.jobs.isEmpty)
        XCTAssertEqual(editedCheckin?.id, 999)
        XCTAssertEqual(editedCheckin?.rating, 4.5)
        XCTAssertEqual(editedCheckin?.comment, "Updated note")
        XCTAssertEqual(editedCheckin?.servingType, "Can")
        XCTAssertEqual(editedCheckin?.retailVenue?.foursquareId, "shop-fsq-50")
        XCTAssertEqual(editedCheckin?.photo?.large?.absoluteString, destURL)
        XCTAssertEqual(queue.completedToast?.message, "Updated Pacific Ale")
    }

    // MARK: Background failure local notification

    func testBackgroundFailureSchedulesLocalNotificationOnlyWhenInactiveAndAuthorized() async {
        let queue = makeQueue()
        appActive = false
        authStatus = .authorized

        let jobID = queue.enqueueNew(sampleDraft(), beerName: "Saison", breweryName: "Brew",
                                     username: "alice", photo: nil)
        await waitForUploads(count: 1)
        transport.complete(taskDescription: transport.uploads[0].taskDescription, error: URLError(.timedOut))
        await waitUntil { !self.scheduledNotifications.isEmpty }

        XCTAssertEqual(scheduledNotifications.count, 1)
        XCTAssertEqual(scheduledNotifications[0].0, jobID)
        XCTAssertEqual(scheduledNotifications[0].1, "Saison")

        // Denied authorization: no notification scheduled
        authStatus = .denied
        queue.retry(jobID)
        transport.complete(taskDescription: transport.uploads[1].taskDescription, error: URLError(.timedOut))
        await waitUntil { self.queueFailed(queue, jobID) }
        XCTAssertEqual(scheduledNotifications.count, 1)
    }

    func testFailureNotificationContentHasNoSoundOrBadge() {
        let content = CheckinQueue.failureNotificationContent(beerName: "Saison")
        XCTAssertEqual(content.title, "Check-in failed")
        XCTAssertNil(content.sound)
        XCTAssertNil(content.badge)
        XCTAssertFalse(NotificationRoute.isActivity(userInfo: content.userInfo))
    }

    private func queueFailed(_ queue: CheckinQueue, _ jobID: UUID) -> Bool {
        queue.jobs.first { $0.id == jobID }?.isFailed == true
    }

    // MARK: Delegate / reconcile race ordering & background completion handler

    func testReconcileDoesNotDuplicateWhenStep1CompletesDuringActiveTasksLookup() async {
        let queue1 = makeQueue()
        let jobID = queue1.enqueueNew(sampleDraft(), beerName: "IPA", breweryName: "Brew",
                                      username: "alice", photo: sampleImage())
        await waitForUploads(count: 1)
        let step1Desc = transport.uploads[0].taskDescription

        // Relaunch with activeTasks() suspended while iOS delivers the queued Step 1 completion.
        let transport2 = MockCheckinTransport()
        transport2.activeTaskList = []
        transport2.holdActiveTasks = true
        let queue2 = makeQueue(transport: transport2)
        queue2.start()
        await waitUntil { transport2.isHoldingActiveTasks }

        // Step 1 completes while reconcile() is awaiting activeTasks() -> transitions to Step 2.
        let step1JSON = #"{"meta":{"code":200},"response":{"checkin_id":601,"photo_upload":{"url":"https://s3.test/601","destination_url":"https://cdn.test/601.jpg"}}}"#
        transport2.complete(taskDescription: step1Desc, status: 200, json: step1JSON)
        XCTAssertEqual(transport2.uploads.count, 1)
        XCTAssertEqual(transport2.uploads[0].taskDescription, CheckinQueue.taskDescription(jobID, .step2))

        // Release activeTasks() returning [] -> reconcile MUST NOT re-enqueue Step 2!
        transport2.releaseActiveTasks()
        await queue2.reconcile()

        XCTAssertEqual(transport2.uploads.count, 1, "reconcile() must not start a duplicate Step 2 PUT")
        XCTAssertTrue(scheduledNotifications.isEmpty)
    }

    func testDelayedStep1CompletionRecoversAfterReconcileAndIgnoresDuplicate() async {
        let queue1 = makeQueue()
        let jobID = queue1.enqueueNew(sampleDraft(), beerName: "IPA", breweryName: "Brew",
                                      username: "alice", photo: sampleImage())
        await waitForUploads(count: 1)
        let step1Desc = transport.uploads[0].taskDescription

        // Relaunch: reconcile() runs first with no active tasks and marks .submittingCheckin failed
        // (without scheduling a local notification).
        appActive = false
        let transport2 = MockCheckinTransport()
        transport2.activeTaskList = []
        let queue2 = makeQueue(transport: transport2)
        queue2.start()
        await queue2.reconcile()

        XCTAssertEqual(queue2.jobs.first?.phase, .failed(
            step: .checkin,
            message: "Check-in was interrupted while sending. Check your feed before retrying."
        ))
        XCTAssertTrue(scheduledNotifications.isEmpty, "reconcile-inferred failure must not fire local notification")

        // Queued Step 1 success arrives after reconcile() -> recovers into Step 2.
        let step1JSON = #"{"meta":{"code":200},"response":{"checkin_id":701,"photo_upload":{"url":"https://s3.test/701","destination_url":"https://cdn.test/701.jpg"}}}"#
        transport2.complete(taskDescription: step1Desc, status: 200, json: step1JSON)
        XCTAssertEqual(transport2.uploads.count, 1)
        XCTAssertEqual(transport2.uploads[0].taskDescription, CheckinQueue.taskDescription(jobID, .step2))

        // A stale/duplicate Step 1 completion arriving while in .uploadingPhoto MUST be ignored.
        let dupJSON = #"{"meta":{"code":200},"response":{"checkin_id":999,"photo_upload":{"url":"https://s3.test/999","destination_url":"https://cdn.test/999.jpg"}}}"#
        transport2.complete(taskDescription: step1Desc, status: 200, json: dupJSON)
        XCTAssertEqual(transport2.uploads.count, 1, "Stale duplicate Step 1 completion must be ignored")
        XCTAssertEqual(queue2.jobs.first?.phase, .uploadingPhoto(
            checkinId: 701,
            uploadURL: URL(string: "https://s3.test/701")!,
            destinationURL: URL(string: "https://cdn.test/701.jpg")!
        ))
    }

    func testReconcileDoesNotFailNewlyEnqueuedPreparingJobDuringAwait() async {
        let transport2 = MockCheckinTransport()
        transport2.activeTaskList = []
        transport2.holdActiveTasks = true

        var releaseEncoder: CheckedContinuation<Data?, Never>?
        let queue = CheckinQueue(
            transport: transport2,
            storageDirectory: tempDir,
            backgroundTasks: bgTasks,
            imageEncoder: { _ in
                await withCheckedContinuation { releaseEncoder = $0 }
            },
            tokenProvider: { "test-token" },
            notificationCenter: center,
            toastDuration: .milliseconds(50)
        )

        queue.start()
        await waitUntil { transport2.isHoldingActiveTasks }

        // Enqueue a new check-in while reconcile() is suspended awaiting activeTasks().
        let newJobID = queue.enqueueNew(sampleDraft(), beerName: "Fresh", breweryName: "Brew",
                                        username: "alice", photo: sampleImage())
        XCTAssertEqual(queue.jobs.first(where: { $0.id == newJobID })?.phase, .preparing)

        // Release reconcile(): the newly enqueued job was not in the pre-await snapshot, so it stays .preparing.
        transport2.releaseActiveTasks()
        await queue.reconcile()
        XCTAssertEqual(queue.jobs.first(where: { $0.id == newJobID })?.phase, .preparing)

        // Release image encoder so the job proceeds normally to Step 1.
        releaseEncoder?.resume(returning: Data([0xFF, 0xD8]))
        await waitForUploads(in: transport2, count: 1)
        XCTAssertEqual(queue.jobs.first(where: { $0.id == newJobID })?.phase, .submittingCheckin)
    }

    func testBackgroundCompletionHandlerWaitsForReconcileAndFailureNotification() async {
        let queue1 = makeQueue()
        _ = queue1.enqueueNew(sampleDraft(), beerName: "Porter", breweryName: "Brew",
                              username: "alice", photo: nil)
        await waitForUploads(count: 1)
        let step1Desc = transport.uploads[0].taskDescription

        appActive = false
        let transport2 = MockCheckinTransport()
        transport2.activeTaskList = []
        transport2.holdActiveTasks = true

        var releaseAuthStatus: CheckedContinuation<UNAuthorizationStatus, Never>?
        var authStatusRequested = false
        let queue2 = CheckinQueue(
            transport: transport2,
            storageDirectory: tempDir,
            backgroundTasks: bgTasks,
            tokenProvider: { "test-token" },
            notificationCenter: center,
            isAppActive: { false },
            notificationAuthStatus: {
                authStatusRequested = true
                return await withCheckedContinuation { releaseAuthStatus = $0 }
            },
            scheduleFailureNotification: { [weak self] id, beer in
                self?.scheduledNotifications.append((id, beer))
            },
            toastDuration: .milliseconds(50)
        )

        var completionCalled = false
        queue2.handleBackgroundSessionEvents(identifier: BackgroundURLSessionTransport.sessionIdentifier) {
            completionCalled = true
        }
        await waitUntil { transport2.isHoldingActiveTasks }

        // Step 1 fails in background (spawns async notificationAuthStatus check) and session finishes events.
        transport2.complete(taskDescription: step1Desc, error: URLError(.timedOut))
        transport2.finishBackgroundEvents()
        await waitUntil { authStatusRequested }

        // Completion handler MUST stay held while reconcile() and notification check are still running.
        XCTAssertFalse(completionCalled)

        // Release reconcile() first -> still held because notification check is pending.
        transport2.releaseActiveTasks()
        await queue2.reconcile()
        XCTAssertFalse(completionCalled)

        // Release notification auth check -> notification scheduled, then completion handler fires.
        releaseAuthStatus?.resume(returning: .authorized)
        await waitUntil { completionCalled }
        XCTAssertEqual(scheduledNotifications.count, 1)
        XCTAssertTrue(completionCalled)
    }

    func testOnCheckinSavedFiresOnlyAfterStep1SucceedsAndCancelStopsJob() async {
        let queue = makeQueue()
        let jobID = queue.enqueueNew(sampleDraft(bid: 777), beerName: "Pils", breweryName: "Brew",
                                     username: "alice", photo: nil)
        await waitForUploads(count: 1)
        XCTAssertTrue(savedBeerIDs.isEmpty, "Must not mark beer had before Step 1 succeeds")

        // Fail Step 1 -> still not saved
        transport.complete(taskDescription: transport.uploads[0].taskDescription, error: URLError(.notConnectedToInternet))
        XCTAssertTrue(savedBeerIDs.isEmpty)

        // Retry Step 1 and succeed -> now marks had
        queue.retry(jobID)
        XCTAssertEqual(transport.uploads.count, 2)
        transport.complete(
            taskDescription: transport.uploads[1].taskDescription,
            status: 200,
            json: #"{"meta":{"code":200},"response":{"result":"success","checkin_id":888}}"#
        )
        XCTAssertEqual(savedBeerIDs, [777])

        // Active job cancel removes job and cancels transport tasks
        let jobID2 = queue.enqueueNew(sampleDraft(bid: 888), beerName: "Stout", breweryName: "Brew",
                                      username: "alice", photo: nil)
        await waitForUploads(count: 3)
        queue.cancel(jobID2)
        await waitUntil { self.transport.cancelledJobIDs.contains(jobID2) }
        XCTAssertTrue(queue.jobs.isEmpty)
        XCTAssertTrue(transport.cancelledJobIDs.contains(jobID2))
    }

    func testInterruptedPreparingWithMissingPhotoWarnsUser() async throws {
        var releaseEncoder: CheckedContinuation<Data?, Never>?
        let transport1 = MockCheckinTransport()
        let queue1 = CheckinQueue(
            transport: transport1,
            storageDirectory: tempDir,
            backgroundTasks: bgTasks,
            imageEncoder: { _ in
                await withCheckedContinuation { releaseEncoder = $0 }
            },
            tokenProvider: { "test-token" },
            notificationCenter: center
        )
        let jobID = queue1.enqueueNew(sampleDraft(), beerName: "Porter", breweryName: "Brew",
                                      username: "alice", photo: sampleImage())
        await waitUntil { releaseEncoder != nil }
        XCTAssertEqual(queue1.jobs.first?.phase, .preparing)

        // Simulate app kill before photo.jpg was written; relaunch reconcile must mark photo lost.
        let transport2 = MockCheckinTransport()
        let queue2 = makeQueue(transport: transport2)
        queue2.start()
        await queue2.reconcile()

        XCTAssertEqual(queue2.jobs.first?.id, jobID)
        XCTAssertEqual(queue2.jobs.first?.hasPhoto, false)
        XCTAssertEqual(queue2.jobs.first?.phase, .failed(
            step: .checkin,
            message: "Check-in was interrupted and its photo couldn't be recovered. Retry will check in without the photo."
        ))
        releaseEncoder?.resume(returning: nil)
    }

    func testBackgroundTransportHasBoundedResourceTimeout() {
        XCTAssertGreaterThan(BackgroundURLSessionTransport.resourceTimeout, 0)
        XCTAssertLessThanOrEqual(BackgroundURLSessionTransport.resourceTimeout, 30 * 60)
    }

    func testSystemCancellationDuringReconcileMarksFailedInsteadOfHanging() async {
        let queue1 = makeQueue()
        let jobID = queue1.enqueueNew(sampleDraft(), beerName: "Lager", breweryName: "Brew",
                                      username: "alice", photo: sampleImage())
        await waitForUploads(count: 1)
        let step1Desc = transport.uploads[0].taskDescription

        // Simulate force-quit: iOS delivers NSURLErrorCancelled while reconcile() holds activeTasks().
        appActive = false
        let transport2 = MockCheckinTransport()
        transport2.activeTaskList = []
        transport2.holdActiveTasks = true
        let queue2 = makeQueue(transport: transport2)
        queue2.start()
        await waitUntil { transport2.isHoldingActiveTasks }

        transport2.complete(taskDescription: step1Desc, error: URLError(.cancelled))
        transport2.releaseActiveTasks()
        await queue2.reconcile()

        XCTAssertEqual(queue2.jobs.first?.id, jobID)
        XCTAssertEqual(queue2.jobs.first?.phase, .failed(
            step: .checkin,
            message: "Check-in was interrupted while sending. Check your feed before retrying."
        ))
        XCTAssertTrue(scheduledNotifications.isEmpty)
    }

    func testImageEncodeFailureDowngradesToNoPhotoSoRetrySucceeds() async {
        let queue = makeQueue(jpegBytes: nil)
        let jobID = queue.enqueueNew(sampleDraft(), beerName: "Pilsner", breweryName: "Brew",
                                     username: "alice", photo: sampleImage())
        await waitUntil { self.queueFailed(queue, jobID) }

        XCTAssertEqual(queue.jobs.first?.hasPhoto, false)
        XCTAssertEqual(queue.jobs.first?.phase, .failed(
            step: .checkin,
            message: "Couldn't prepare the photo for upload. Retry will check in without the photo."
        ))

        queue.retry(jobID)
        XCTAssertEqual(transport.uploads.count, 1)
        let body = String(data: transport.uploads[0].fileBytes ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("is_photo=false"))

        transport.complete(
            taskDescription: transport.uploads[0].taskDescription,
            status: 200,
            json: #"{"meta":{"code":200},"response":{"result":"success","checkin_id":901}}"#
        )
        XCTAssertTrue(queue.jobs.isEmpty)
    }
}
