import CoreLocation
import Foundation
import Observation

/// A check-in saved for later while offline: at least what was searched for, or the beer, plus
/// when and roughly where. Whatever was filled in on the check-in screen comes along too.
struct PendingCheckin: Codable, Hashable, Identifiable {
    var id = UUID()
    /// The account it was saved under.
    var username: String
    var savedAt: Date
    /// What was typed into search, when no beer was picked.
    var query: String?
    var beer: BeerLite?
    var lat: Double?
    var lng: Double?
    /// Metres, from the location fix.
    var accuracy: Double?
    var venue: Venue?
    var rating: Double = 0
    var shout = ""
    var servingId: Int?
    var servingName: String?
    /// Whether a JPEG is kept for it (`PendingCheckins.photo(for:)`).
    var hasPhoto = false

    var location: CLLocation? {
        guard let lat, let lng else { return nil }
        return CLLocation(coordinate: .init(latitude: lat, longitude: lng), altitude: 0,
                          horizontalAccuracy: accuracy ?? 100, verticalAccuracy: -1, timestamp: savedAt)
    }

    /// The beer's name, or the search in quotes.
    var title: String {
        if let beer { return beer.name }
        return "“\(query ?? "")”"
    }

    mutating func setLocation(_ loc: CLLocation?) {
        lat = loc?.coordinate.latitude
        lng = loc?.coordinate.longitude
        accuracy = loc.map(\.horizontalAccuracy).flatMap { $0 >= 0 ? $0 : nil }
    }
}

/// Check-ins saved for later, newest first, kept on disk (photos as separate JPEGs) until
/// they're finished or removed. Signing out doesn't delete them: each belongs to an account, and
/// only the signed-in account's show.
@MainActor @Observable
final class PendingCheckins {
    static let shared = PendingCheckins()

    private var all: [PendingCheckin] = []
    @ObservationIgnored private let url: URL
    @ObservationIgnored private let photoDir: URL
    @ObservationIgnored private let currentUser: () -> String?

    init(directory: URL? = nil,
         currentUser: @escaping () -> String? = { UserDefaults.standard.string(forKey: "username") }) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = dir.appendingPathComponent("pending-checkins.json")
        photoDir = dir.appendingPathComponent("pending-photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: photoDir, withIntermediateDirectories: true)
        self.currentUser = currentUser
        if let d = try? Data(contentsOf: url), let items = try? JSONDecoder().decode([PendingCheckin].self, from: d) {
            all = items
        }
    }

    /// The signed-in account's saved check-ins, newest first.
    var items: [PendingCheckin] {
        guard let user = currentUser() else { return [] }
        return all.filter { $0.username == user }.sorted { $0.savedAt > $1.savedAt }
    }

    /// Saves a new check-in for the signed-in account (with `username` filled in). Returns it, or
    /// nil when nobody is signed in.
    @discardableResult
    func add(_ item: PendingCheckin, photo: Data? = nil) -> PendingCheckin? {
        guard let user = currentUser() else { return nil }
        var item = item
        item.username = user
        if let photo, (try? photo.write(to: photoURL(item.id), options: .atomic)) != nil {
            item.hasPhoto = true
        } else {
            item.hasPhoto = false
        }
        all.append(item)
        save()
        return item
    }

    func remove(_ id: PendingCheckin.ID) {
        all.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: photoURL(id))
        save()
    }

    func photo(for item: PendingCheckin) -> Data? {
        item.hasPhoto ? try? Data(contentsOf: photoURL(item.id)) : nil
    }

    private func photoURL(_ id: UUID) -> URL { photoDir.appendingPathComponent("\(id.uuidString).jpg") }

    private func save() {
        if let d = try? JSONEncoder().encode(all) { try? d.write(to: url, options: .atomic) }
    }
}
