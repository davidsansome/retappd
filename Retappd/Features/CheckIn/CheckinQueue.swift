import Foundation
import Observation
import UIKit
import UserNotifications

// MARK: - Models

struct NewCheckinDraft: Codable, Equatable, Sendable {
    var beerBid: Int
    var foursquareId: String?
    var lat: Double?
    var lng: Double?
    var rating: Double
    var shout: String
    var containerId: Int?
    var taggedUserIds: [Int]
    var purchaseFoursquareId: String?
    var flavorIds: [Int]
}

struct EditCheckinDraft: Codable, Equatable {
    var checkinId: Int
    var beerBid: Int?
    var venueFoursquareId: String?
    var venueLat: Double?
    var venueLng: Double?
    var rating: Double
    var shout: String
    var containerId: Int?
    var servingTypeName: String?
    var purchaseFoursquareId: String?
    var shop: Venue?
    var originalComment: String?
    var originalServingType: String?
}

struct PendingCheckin: Codable, Identifiable, Equatable {
    enum Kind: Codable, Equatable {
        case new(NewCheckinDraft)
        case edit(EditCheckinDraft)
    }

    enum FailedStep: Codable, Equatable {
        case checkin
        case photoUpload(checkinId: Int, uploadURL: URL, destinationURL: URL)
        case photoComplete(checkinId: Int, destinationURL: URL)
    }

    enum Phase: Codable, Equatable {
        case preparing
        case submittingCheckin
        case uploadingPhoto(checkinId: Int, uploadURL: URL, destinationURL: URL)
        case completingPhoto(checkinId: Int, destinationURL: URL)
        case failed(step: FailedStep, message: String)
    }

    var id: UUID
    var username: String
    var createdAt: Date
    var beerBid: Int
    var beerName: String
    var breweryName: String
    var hasPhoto: Bool
    var kind: Kind
    var phase: Phase

    var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// True once Step 1 has succeeded on Untappd and only the photo upload/completion remains.
    var checkinAlreadySaved: Bool {
        switch phase {
        case .uploadingPhoto, .completingPhoto:
            return true
        case .failed(let step, _):
            switch step {
            case .checkin: return false
            case .photoUpload, .photoComplete: return true
            }
        case .preparing, .submittingCheckin:
            return false
        }
    }

    var isEdit: Bool {
        if case .edit = kind { return true }
        return false
    }
}

struct CheckinCompletedToast: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

enum CheckinStepTag: String {
    case step1
    case step2
    case step2refresh
    case step3
}

// MARK: - Transport & Background Task Abstractions

struct ActiveBackgroundTask: Equatable, Sendable {
    var taskDescription: String?
}

@MainActor
protocol CheckinBackgroundTransportDelegate: AnyObject {
    func transportDidComplete(
        taskDescription: String?,
        response: HTTPURLResponse?,
        data: Data,
        error: Error?
    )
    func transportDidFinishBackgroundEvents()
}

protocol CheckinBackgroundTransport: AnyObject {
    var delegate: CheckinBackgroundTransportDelegate? { get set }
    func startUpload(request: URLRequest, fromFile fileURL: URL, taskDescription: String)
    func activeTasks() async -> [ActiveBackgroundTask]
    func cancelTasks(matching jobID: UUID) async
    func cancelAllTasks() async
}

protocol BackgroundTaskBeginner {
    @MainActor
    func beginBackgroundTask(name: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier
    @MainActor
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier)
}

struct SystemBackgroundTaskBeginner: BackgroundTaskBeginner {
    @MainActor
    func beginBackgroundTask(name: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expirationHandler)
    }

    @MainActor
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
}

// MARK: - Production Background URLSession Transport

/// Wraps a background `URLSession` so check-in POSTs and S3 photo PUTs continue out-of-process
/// even if the user locks their phone or the OS suspends/terminates Retappd.
final class BackgroundURLSessionTransport: NSObject, CheckinBackgroundTransport, URLSessionDataDelegate, @unchecked Sendable {
    static let sessionIdentifier = "com.davidsansome.retappd.checkin-upload"

    weak var delegate: CheckinBackgroundTransportDelegate?

    private let delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.davidsansome.retappd.checkin-upload.delegate"
        q.maxConcurrentOperationCount = 1
        return q
    }()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        return URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }()

    /// Accessed exclusively on `delegateQueue`.
    private var responseBuffers: [Int: Data] = [:]

    func ensureSessionStarted() {
        _ = session
    }

    func startUpload(request: URLRequest, fromFile fileURL: URL, taskDescription: String) {
        var req = request
        // Background URLSession requires httpBody to be nil when uploading from a file.
        req.httpBody = nil
        let task = session.uploadTask(with: req, fromFile: fileURL)
        task.taskDescription = taskDescription
        task.resume()
    }

    func activeTasks() async -> [ActiveBackgroundTask] {
        let tasks = await session.allTasks
        return tasks.filter { $0.state == .running || $0.state == .suspended }
            .map { ActiveBackgroundTask(taskDescription: $0.taskDescription) }
    }

    func cancelTasks(matching jobID: UUID) async {
        let prefix = "\(jobID.uuidString)|"
        let tasks = await session.allTasks
        for task in tasks where task.taskDescription?.hasPrefix(prefix) == true {
            task.cancel()
        }
    }

    func cancelAllTasks() async {
        let tasks = await session.allTasks
        for task in tasks { task.cancel() }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseBuffers[dataTask.taskIdentifier, default: Data()].append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let data = responseBuffers.removeValue(forKey: task.taskIdentifier) ?? Data()
        let description = task.taskDescription
        let httpResponse = task.response as? HTTPURLResponse
        // Dispatch via main queue (FIFO) so chained next-step tasks are created and resumed
        // strictly before `urlSessionDidFinishEvents` invokes the system completion handler.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.delegate?.transportDidComplete(
                    taskDescription: description,
                    response: httpResponse,
                    data: data,
                    error: error
                )
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.delegate?.transportDidFinishBackgroundEvents()
            }
        }
    }
}

// MARK: - Request Builder Helper

extension APIRequest {
    static func editCheckin(draft: EditCheckinDraft, isPhoto: Bool) -> APIRequest {
        let tz = TimeZone.current
        var form = [
            "rating": draft.rating > 0 ? String(format: "%.2f", draft.rating) : "0",
            "shout": draft.shout,
            "checkin_tags": "",
            "flavor_profiles": "",
            "is_photo": isPhoto ? "true" : "false",
            "photo_file_ext": "jpg",
            "gmt_offset": gmtOffsetString(for: tz),
            "timezone": tz.identifier,
            "purchase_foursquare_id": draft.purchaseFoursquareId ?? "",
        ]
        if let bid = draft.beerBid { form["bid"] = "\(bid)" }
        if let containerId = draft.containerId { form["container_id"] = "\(containerId)" }
        if let f = draft.venueFoursquareId { form["foursquare_id"] = f }
        if let lat = draft.venueLat, let lng = draft.venueLng {
            form["geolat"] = String(format: "%.6f", lat)
            form["geolng"] = String(format: "%.6f", lng)
        }
        return APIRequest(method: .post, path: "/v4/checkin/edit/\(draft.checkinId)", form: form)
    }
}

// MARK: - CheckinQueue

/// Durable background outbox for check-ins and photo uploads.
///
/// Persists pending jobs and upload files under `Application Support/PendingCheckins/` with
/// `completeUntilFirstUserAuthentication` protection and drives all network steps through a
/// background `URLSession` so check-ins finish even when the user immediately locks their phone.
@Observable @MainActor
final class CheckinQueue: CheckinBackgroundTransportDelegate {
    static let shared = CheckinQueue()

    private(set) var jobs: [PendingCheckin] = []
    private(set) var completedToast: CheckinCompletedToast?

    @ObservationIgnored private let transport: CheckinBackgroundTransport
    @ObservationIgnored private let storageDirectory: URL
    @ObservationIgnored private let backgroundTasks: BackgroundTaskBeginner
    @ObservationIgnored private let imageEncoder: @Sendable (UIImage) async -> Data?
    @ObservationIgnored private let tokenProvider: () -> String?
    @ObservationIgnored private let onUnauthorized: () -> Void
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private let isAppActive: () -> Bool
    @ObservationIgnored private let notificationAuthStatus: () async -> UNAuthorizationStatus
    @ObservationIgnored private let scheduleFailureNotification: (UUID, String) -> Void
    @ObservationIgnored private let onSuccessHaptic: () -> Void
    @ObservationIgnored private let toastDuration: Duration

    @ObservationIgnored private var started = false
    @ObservationIgnored private var backgroundCompletionHandler: (() -> Void)?
    @ObservationIgnored private var toastClearTask: Task<Void, Never>?
    /// Original `Checkin` objects kept in memory for in-session edits so `.checkinEdited` can
    /// update feeds and detail views in place without losing unedited fields.
    @ObservationIgnored private var editingCheckins: [UUID: Checkin] = [:]
    /// Tracks jobs that have already refreshed an expired S3 presigned URL once to prevent loops.
    @ObservationIgnored private var refreshedUploadURLJobIDs: Set<UUID> = []

    init(
        transport: CheckinBackgroundTransport = BackgroundURLSessionTransport(),
        storageDirectory: URL = CheckinQueue.defaultStorageDirectory(),
        backgroundTasks: BackgroundTaskBeginner = SystemBackgroundTaskBeginner(),
        imageEncoder: @escaping @Sendable (UIImage) async -> Data? = { image in
            await Task.detached(priority: .userInitiated) { CheckinPhoto.jpeg(image) }.value
        },
        tokenProvider: @escaping () -> String? = { UntappdAPI.shared.token ?? Keychain.read("access_token") },
        onUnauthorized: @escaping () -> Void = { UntappdAPI.shared.onUnauthorized?() },
        notificationCenter: NotificationCenter = .default,
        isAppActive: @escaping () -> Bool = { UIApplication.shared.applicationState == .active },
        notificationAuthStatus: @escaping () async -> UNAuthorizationStatus = {
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        },
        scheduleFailureNotification: @escaping (UUID, String) -> Void = CheckinQueue.defaultScheduleFailureNotification,
        onSuccessHaptic: @escaping () -> Void = { UINotificationFeedbackGenerator().notificationOccurred(.success) },
        toastDuration: Duration = .seconds(2)
    ) {
        self.transport = transport
        self.storageDirectory = storageDirectory
        self.backgroundTasks = backgroundTasks
        self.imageEncoder = imageEncoder
        self.tokenProvider = tokenProvider
        self.onUnauthorized = onUnauthorized
        self.notificationCenter = notificationCenter
        self.isAppActive = isAppActive
        self.notificationAuthStatus = notificationAuthStatus
        self.scheduleFailureNotification = scheduleFailureNotification
        self.onSuccessHaptic = onSuccessHaptic
        self.toastDuration = toastDuration
        self.transport.delegate = self
    }

    nonisolated static func defaultStorageDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("PendingCheckins", isDirectory: true)
    }

    nonisolated static func defaultScheduleFailureNotification(jobID: UUID, beerName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Check-in failed"
        content.body = "\(beerName) couldn't be saved. Open Retappd to retry."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "checkin-failed-\(jobID.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Lifecycle & Background Events

    /// Loads persisted jobs, reconnects the background URLSession, and reconciles orphaned jobs.
    func start() {
        guard !started else { return }
        started = true
        (transport as? BackgroundURLSessionTransport)?.ensureSessionStarted()
        loadJobsFromDisk()
        Task { await reconcile() }
    }

    func handleBackgroundSessionEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundURLSessionTransport.sessionIdentifier else {
            completionHandler()
            return
        }
        backgroundCompletionHandler = completionHandler
        start()
    }

    /// Reconciles persisted jobs against currently active background URLSession tasks.
    func reconcile() async {
        let active = await transport.activeTasks()
        let activeJobIDs = Set(active.compactMap { Self.parseTaskDescription($0.taskDescription)?.0 })

        var changed = false
        for i in jobs.indices {
            let job = jobs[i]
            if job.isFailed || activeJobIDs.contains(job.id) { continue }

            switch job.phase {
            case .preparing:
                if job.hasPhoto && !FileManager.default.fileExists(atPath: photoFileURL(for: job.id).path) {
                    jobs[i].hasPhoto = false
                }
                jobs[i].phase = .failed(
                    step: .checkin,
                    message: "Check-in was interrupted before it could be sent. Tap Retry to try again."
                )
                changed = true

            case .submittingCheckin:
                // Ambiguous whether Untappd received Step 1: surface as failed instead of double-posting.
                jobs[i].phase = .failed(
                    step: .checkin,
                    message: "Check-in was interrupted while sending. Check your feed before retrying."
                )
                changed = true

            case .uploadingPhoto(let checkinId, let uploadURL, let destinationURL):
                startStep2(jobID: job.id, checkinId: checkinId, uploadURL: uploadURL, destinationURL: destinationURL)

            case .completingPhoto(let checkinId, let destinationURL):
                startStep3(jobID: job.id, checkinId: checkinId, destinationURL: destinationURL)

            case .failed:
                break
            }
        }
        if changed { persistJobs() }
    }

    // MARK: Enqueue

    @discardableResult
    func enqueueNew(
        _ draft: NewCheckinDraft,
        beerName: String,
        breweryName: String,
        username: String,
        photo: UIImage?
    ) -> UUID {
        let job = PendingCheckin(
            id: UUID(),
            username: username,
            createdAt: Date(),
            beerBid: draft.beerBid,
            beerName: beerName,
            breweryName: breweryName,
            hasPhoto: photo != nil,
            kind: .new(draft),
            phase: .preparing
        )
        jobs.append(job)
        persistJobs()
        Task { await prepareAndStartStep1(jobID: job.id, photo: photo) }
        return job.id
    }

    @discardableResult
    func enqueueEdit(
        _ original: Checkin,
        rating: Double,
        shout: String,
        serving: ServingType?,
        shop: Venue?,
        username: String,
        photo: UIImage?
    ) -> UUID {
        let trimmed = shout.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = EditCheckinDraft(
            checkinId: original.id,
            beerBid: original.beerLite?.bid,
            venueFoursquareId: original.venue?.foursquareId,
            venueLat: original.venue?.lat,
            venueLng: original.venue?.lng,
            rating: rating,
            shout: trimmed,
            containerId: serving?.id,
            servingTypeName: serving?.name,
            purchaseFoursquareId: shop?.foursquareId,
            shop: shop,
            originalComment: original.comment,
            originalServingType: original.servingType
        )
        let job = PendingCheckin(
            id: UUID(),
            username: username,
            createdAt: Date(),
            beerBid: original.beerLite?.bid ?? 0,
            beerName: original.beer?.name ?? "Check-in",
            breweryName: original.brewery?.name ?? "",
            hasPhoto: photo != nil,
            kind: .edit(draft),
            phase: .preparing
        )
        editingCheckins[job.id] = original
        jobs.append(job)
        persistJobs()
        Task { await prepareAndStartStep1(jobID: job.id, photo: photo) }
        return job.id
    }

    // MARK: Retry / Discard / Sign-out

    func retry(_ id: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }),
              case .failed(let step, _) = jobs[idx].phase else { return }
        refreshedUploadURLJobIDs.remove(id)

        withBackgroundTask("com.davidsansome.retappd.checkin.retry") {
            switch step {
            case .checkin:
                startStep1(jobID: id)
            case .photoUpload(let checkinId, let uploadURL, let destinationURL):
                // Idempotent: NEVER re-posts Step 1.
                startStep2(jobID: id, checkinId: checkinId, uploadURL: uploadURL, destinationURL: destinationURL)
            case .photoComplete(let checkinId, let destinationURL):
                // Idempotent: NEVER re-posts Step 1 or re-PUTs Step 2.
                startStep3(jobID: id, checkinId: checkinId, destinationURL: destinationURL)
            }
        }
    }

    func discard(_ id: UUID) {
        jobs.removeAll { $0.id == id }
        editingCheckins.removeValue(forKey: id)
        refreshedUploadURLJobIDs.remove(id)
        persistJobs()
        removeJobDirectory(id)
        Task { await transport.cancelTasks(matching: id) }
    }

    func cancelAllForSignOut() {
        jobs.removeAll()
        editingCheckins.removeAll()
        refreshedUploadURLJobIDs.removeAll()
        toastClearTask?.cancel()
        toastClearTask = nil
        completedToast = nil
        try? FileManager.default.removeItem(at: storageDirectory)
        Task { await transport.cancelAllTasks() }
    }

    // MARK: Step Execution

    private func prepareAndStartStep1(jobID: UUID, photo: UIImage?) async {
        await withBackgroundTaskAsync("com.davidsansome.retappd.checkin.enqueue") {
            if let photo {
                guard let jpeg = await imageEncoder(photo) else {
                    markFailed(jobID: jobID, step: .checkin, message: "Couldn't prepare the photo for upload.")
                    return
                }
                guard jobs.contains(where: { $0.id == jobID }) else { return }
                do {
                    try ensureJobDirectory(jobID)
                    try writeProtected(jpeg, to: photoFileURL(for: jobID))
                } catch {
                    markFailed(jobID: jobID, step: .checkin, message: "Couldn't save the photo for upload.")
                    return
                }
            }
            guard jobs.contains(where: { $0.id == jobID }) else { return }
            startStep1(jobID: jobID)
        }
    }

    private func startStep1(jobID: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let job = jobs[idx]

        let apiRequest: APIRequest
        switch job.kind {
        case .new(let draft):
            apiRequest = .checkin(
                beer: draft.beerBid,
                foursquareId: draft.foursquareId,
                lat: draft.lat,
                lng: draft.lng,
                rating: draft.rating,
                shout: draft.shout,
                containerId: draft.containerId,
                taggedUserIds: draft.taggedUserIds,
                purchaseFoursquareId: draft.purchaseFoursquareId,
                flavorIds: draft.flavorIds,
                isPhoto: job.hasPhoto
            )
        case .edit(let draft):
            apiRequest = .editCheckin(draft: draft, isPhoto: job.hasPhoto)
        }

        let (urlRequest, bodyData) = buildAPIUploadRequest(apiRequest)
        let bodyURL = step1FormURL(for: jobID)
        do {
            try ensureJobDirectory(jobID)
            try writeProtected(bodyData, to: bodyURL)
        } catch {
            markFailed(jobID: jobID, step: .checkin, message: "Couldn't save check-in request to disk.")
            return
        }

        jobs[idx].phase = .submittingCheckin
        persistJobs()
        transport.startUpload(request: urlRequest, fromFile: bodyURL, taskDescription: Self.taskDescription(jobID, .step1))
    }

    private func startStep2(jobID: UUID, checkinId: Int, uploadURL: URL, destinationURL: URL) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let photoURL = photoFileURL(for: jobID)
        guard FileManager.default.fileExists(atPath: photoURL.path) else {
            markFailed(
                jobID: jobID,
                step: .photoUpload(checkinId: checkinId, uploadURL: uploadURL, destinationURL: destinationURL),
                message: "The photo file is no longer available."
            )
            return
        }

        var req = URLRequest(url: uploadURL)
        req.httpMethod = "PUT"
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.httpBody = nil

        jobs[idx].phase = .uploadingPhoto(checkinId: checkinId, uploadURL: uploadURL, destinationURL: destinationURL)
        persistJobs()
        transport.startUpload(request: req, fromFile: photoURL, taskDescription: Self.taskDescription(jobID, .step2))
    }

    private func startStep2Refresh(jobID: UUID, checkinId: Int, fallbackUploadURL: URL, fallbackDestinationURL: URL) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        let refreshDraft: EditCheckinDraft
        switch job.kind {
        case .edit(let draft):
            refreshDraft = draft
        case .new(let draft):
            refreshDraft = EditCheckinDraft(
                checkinId: checkinId,
                beerBid: draft.beerBid,
                venueFoursquareId: draft.foursquareId,
                venueLat: draft.lat,
                venueLng: draft.lng,
                rating: draft.rating,
                shout: draft.shout,
                containerId: draft.containerId,
                servingTypeName: nil,
                purchaseFoursquareId: draft.purchaseFoursquareId,
                shop: nil,
                originalComment: nil,
                originalServingType: nil
            )
        }

        let apiRequest = APIRequest.editCheckin(draft: refreshDraft, isPhoto: true)
        let (urlRequest, bodyData) = buildAPIUploadRequest(apiRequest)
        let bodyURL = step2RefreshFormURL(for: jobID)
        do {
            try ensureJobDirectory(jobID)
            try writeProtected(bodyData, to: bodyURL)
        } catch {
            markFailed(
                jobID: jobID,
                step: .photoUpload(checkinId: checkinId, uploadURL: fallbackUploadURL, destinationURL: fallbackDestinationURL),
                message: "Couldn't refresh the photo upload link."
            )
            return
        }

        refreshedUploadURLJobIDs.insert(jobID)
        transport.startUpload(request: urlRequest, fromFile: bodyURL, taskDescription: Self.taskDescription(jobID, .step2refresh))
    }

    private func startStep3(jobID: UUID, checkinId: Int, destinationURL: URL) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let apiRequest = APIRequest.photoUploadComplete(checkinId: checkinId, destination: destinationURL)
        let (urlRequest, bodyData) = buildAPIUploadRequest(apiRequest)
        let bodyURL = step3FormURL(for: jobID)
        do {
            try ensureJobDirectory(jobID)
            try writeProtected(bodyData, to: bodyURL)
        } catch {
            markFailed(
                jobID: jobID,
                step: .photoComplete(checkinId: checkinId, destinationURL: destinationURL),
                message: "Couldn't save photo completion request to disk."
            )
            return
        }

        jobs[idx].phase = .completingPhoto(checkinId: checkinId, destinationURL: destinationURL)
        persistJobs()
        transport.startUpload(request: urlRequest, fromFile: bodyURL, taskDescription: Self.taskDescription(jobID, .step3))
    }

    // MARK: CheckinBackgroundTransportDelegate

    func transportDidComplete(
        taskDescription: String?,
        response: HTTPURLResponse?,
        data: Data,
        error: Error?
    ) {
        guard let (jobID, stepTag) = Self.parseTaskDescription(taskDescription),
              let job = jobs.first(where: { $0.id == jobID }) else { return }

        withBackgroundTask("com.davidsansome.retappd.checkin.transition") {
            switch stepTag {
            case .step1:
                handleStep1Completion(job: job, response: response, data: data, error: error)
            case .step2:
                handleStep2Completion(job: job, response: response, error: error)
            case .step2refresh:
                handleStep2RefreshCompletion(job: job, response: response, data: data, error: error)
            case .step3:
                handleStep3Completion(job: job, response: response, data: data, error: error)
            }
        }
    }

    func transportDidFinishBackgroundEvents() {
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        handler?()
    }

    // MARK: Step Completion Handlers

    private func handleStep1Completion(job: PendingCheckin, response: HTTPURLResponse?, data: Data, error: Error?) {
        if let error {
            if error.isCancellation { return }
            markFailed(jobID: job.id, step: .checkin, message: error.localizedDescription)
            return
        }

        let decoded: CheckinAddResponse
        do {
            try validateAPIResponse(data: data, response: response)
            decoded = try UntappdAPI.decode(CheckinAddResponse.self, from: data)
        } catch {
            markFailed(jobID: job.id, step: .checkin, message: error.localizedDescription)
            return
        }

        guard job.hasPhoto else {
            finishJob(job, photoDestinationURL: nil)
            return
        }

        let checkinId: Int?
        switch job.kind {
        case .new: checkinId = decoded.checkinId
        case .edit(let draft): checkinId = decoded.checkinId ?? draft.checkinId
        }

        guard let checkinId, let uploadURL = decoded.photoUploadURL, let destinationURL = decoded.photoDestinationURL else {
            markFailed(jobID: job.id, step: .checkin, message: APIError.decoding.localizedDescription)
            return
        }

        startStep2(jobID: job.id, checkinId: checkinId, uploadURL: uploadURL, destinationURL: destinationURL)
    }

    private func handleStep2Completion(job: PendingCheckin, response: HTTPURLResponse?, error: Error?) {
        guard case .uploadingPhoto(let checkinId, let uploadURL, let destinationURL) = job.phase else { return }
        let failedStep = PendingCheckin.FailedStep.photoUpload(
            checkinId: checkinId,
            uploadURL: uploadURL,
            destinationURL: destinationURL
        )

        if let error {
            if error.isCancellation { return }
            markFailed(jobID: job.id, step: failedStep, message: error.localizedDescription)
            return
        }

        let status = response?.statusCode ?? 0
        if status == 403 && !refreshedUploadURLJobIDs.contains(job.id) {
            // Presigned S3 upload URLs expire after ~120s; request a fresh URL via editCheckin.
            startStep2Refresh(
                jobID: job.id,
                checkinId: checkinId,
                fallbackUploadURL: uploadURL,
                fallbackDestinationURL: destinationURL
            )
            return
        }

        guard (200..<300).contains(status) else {
            markFailed(jobID: job.id, step: failedStep, message: APIError.http(status).localizedDescription)
            return
        }

        startStep3(jobID: job.id, checkinId: checkinId, destinationURL: destinationURL)
    }

    private func handleStep2RefreshCompletion(job: PendingCheckin, response: HTTPURLResponse?, data: Data, error: Error?) {
        guard case .uploadingPhoto(let checkinId, let oldUploadURL, let oldDestinationURL) = job.phase else { return }
        let failedStep = PendingCheckin.FailedStep.photoUpload(
            checkinId: checkinId,
            uploadURL: oldUploadURL,
            destinationURL: oldDestinationURL
        )

        if let error {
            if error.isCancellation { return }
            markFailed(jobID: job.id, step: failedStep, message: error.localizedDescription)
            return
        }

        do {
            try validateAPIResponse(data: data, response: response)
            let decoded = try UntappdAPI.decode(CheckinAddResponse.self, from: data)
            guard let freshUploadURL = decoded.photoUploadURL,
                  let freshDestinationURL = decoded.photoDestinationURL else {
                throw APIError.decoding
            }
            startStep2(jobID: job.id, checkinId: checkinId, uploadURL: freshUploadURL, destinationURL: freshDestinationURL)
        } catch {
            markFailed(jobID: job.id, step: failedStep, message: error.localizedDescription)
        }
    }

    private func handleStep3Completion(job: PendingCheckin, response: HTTPURLResponse?, data: Data, error: Error?) {
        guard case .completingPhoto(let checkinId, let destinationURL) = job.phase else { return }
        let failedStep = PendingCheckin.FailedStep.photoComplete(checkinId: checkinId, destinationURL: destinationURL)

        if let error {
            if error.isCancellation { return }
            markFailed(jobID: job.id, step: failedStep, message: error.localizedDescription)
            return
        }

        do {
            try validateAPIResponse(data: data, response: response)
        } catch {
            markFailed(jobID: job.id, step: failedStep, message: error.localizedDescription)
            return
        }

        finishJob(job, photoDestinationURL: destinationURL)
    }

    // MARK: Completion & Failure

    private func finishJob(_ job: PendingCheckin, photoDestinationURL: URL?) {
        jobs.removeAll { $0.id == job.id }
        refreshedUploadURLJobIDs.remove(job.id)
        persistJobs()
        removeJobDirectory(job.id)

        switch job.kind {
        case .new:
            notificationCenter.post(name: .didCheckIn, object: nil)
            showToast("Checked in \(job.beerName)")
        case .edit(let draft):
            if var updated = editingCheckins.removeValue(forKey: job.id) {
                updated.rating = draft.rating > 0 ? draft.rating : nil
                updated.comment = draft.shout.isEmpty ? draft.originalComment : draft.shout
                updated.servingType = draft.servingTypeName ?? draft.originalServingType
                updated.retailVenue = draft.shop
                updated.retailVenueKnown = true
                if job.hasPhoto, let d = photoDestinationURL {
                    updated.photo = Checkin.Photo(small: d, medium: d, large: d)
                }
                notificationCenter.post(name: .checkinEdited, object: updated)
            } else {
                // App was killed and relaunched before edit finished: trigger a feed/profile refresh.
                notificationCenter.post(name: .didCheckIn, object: nil)
            }
            showToast("Updated \(job.beerName)")
        }

        if isAppActive() {
            onSuccessHaptic()
        }
    }

    private func markFailed(jobID: UUID, step: PendingCheckin.FailedStep, message: String) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[idx].phase = .failed(step: step, message: message)
        let beerName = jobs[idx].beerName
        persistJobs()

        if !isAppActive() {
            Task { [weak self] in
                guard let self else { return }
                let status = await self.notificationAuthStatus()
                if status == .authorized {
                    self.scheduleFailureNotification(jobID, beerName)
                }
            }
        }
    }

    private func showToast(_ message: String) {
        let toast = CheckinCompletedToast(message: message)
        completedToast = toast
        toastClearTask?.cancel()
        let duration = toastDuration
        toastClearTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            if self?.completedToast?.id == toast.id {
                self?.completedToast = nil
            }
        }
    }

    // MARK: Request & Response Helpers

    private func buildAPIUploadRequest(_ r: APIRequest) -> (URLRequest, Data) {
        var req = UntappdAPI.shared.urlRequest(r)
        if req.value(forHTTPHeaderField: "Authorization") == nil, let token = tokenProvider() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let body = req.httpBody ?? Data()
        req.httpBody = nil
        return (req, body)
    }

    private struct Ignored: Decodable {}

    private func validateAPIResponse(data: Data, response: HTTPURLResponse?) throws {
        let status = response?.statusCode ?? 0
        let envelope = try? JSONDecoder().decode(Envelope<Ignored>.self, from: data)
        let meta = envelope?.meta
        if tokenProvider() != nil, status == 401 || meta?.code == 401 || meta?.errorType == "invalid_auth" {
            onUnauthorized()
            throw APIError.unauthorized
        }
        if let meta, meta.code != 200 {
            throw APIError.server(code: meta.code, detail: meta.errorDetail)
        }
        guard (200..<300).contains(status) else { throw APIError.http(status) }
    }

    // MARK: Background Task Helper

    private func withBackgroundTask(_ name: String, _ work: () -> Void) {
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = backgroundTasks.beginBackgroundTask(name: name) { [weak self] in
            let id = taskID
            taskID = .invalid
            Task { @MainActor [weak self] in
                self?.backgroundTasks.endBackgroundTask(id)
            }
        }
        defer {
            if taskID != .invalid {
                backgroundTasks.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
        work()
    }

    private func withBackgroundTaskAsync(_ name: String, _ work: () async -> Void) async {
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = backgroundTasks.beginBackgroundTask(name: name) { [weak self] in
            let id = taskID
            taskID = .invalid
            Task { @MainActor [weak self] in
                self?.backgroundTasks.endBackgroundTask(id)
            }
        }
        defer {
            if taskID != .invalid {
                backgroundTasks.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
        await work()
    }

    // MARK: Task Description

    static func taskDescription(_ jobID: UUID, _ step: CheckinStepTag) -> String {
        "\(jobID.uuidString)|\(step.rawValue)"
    }

    static func parseTaskDescription(_ description: String?) -> (UUID, CheckinStepTag)? {
        guard let description else { return nil }
        let parts = description.split(separator: "|", maxSplits: 1)
        guard parts.count == 2,
              let id = UUID(uuidString: String(parts[0])),
              let tag = CheckinStepTag(rawValue: String(parts[1])) else { return nil }
        return (id, tag)
    }

    // MARK: Disk Persistence

    private var jobsFileURL: URL { storageDirectory.appendingPathComponent("jobs.json") }
    private func jobDirectory(_ id: UUID) -> URL { storageDirectory.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func photoFileURL(for id: UUID) -> URL { jobDirectory(id).appendingPathComponent("photo.jpg") }
    private func step1FormURL(for id: UUID) -> URL { jobDirectory(id).appendingPathComponent("step1.form") }
    private func step2RefreshFormURL(for id: UUID) -> URL { jobDirectory(id).appendingPathComponent("step2refresh.form") }
    private func step3FormURL(for id: UUID) -> URL { jobDirectory(id).appendingPathComponent("step3.form") }

    private func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private func ensureJobDirectory(_ id: UUID) throws {
        try ensureDirectory(storageDirectory)
        try ensureDirectory(jobDirectory(id))
    }

    private func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private func loadJobsFromDisk() {
        guard let data = try? Data(contentsOf: jobsFileURL),
              let decoded = try? JSONDecoder().decode([PendingCheckin].self, from: data) else {
            return
        }
        jobs = decoded
    }

    private func persistJobs() {
        do {
            try ensureDirectory(storageDirectory)
            let data = try JSONEncoder().encode(jobs)
            try writeProtected(data, to: jobsFileURL)
        } catch {
            // Disk write errors shouldn't crash the app; in-memory queue stays usable.
        }
    }

    private func removeJobDirectory(_ id: UUID) {
        try? FileManager.default.removeItem(at: jobDirectory(id))
    }
}
