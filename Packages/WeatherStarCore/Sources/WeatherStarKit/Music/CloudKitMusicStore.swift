#if WS4K_CLOUDKIT
import CloudKit
import Foundation
import OSLog

/// Syncs custom music through the user's **private** CloudKit database.
///
/// Private-database storage counts against each user's own iCloud quota rather than
/// the developer's, so this scales to any number of users at no cost and without a
/// server. It is also the only sync mechanism tvOS supports — there are no ubiquity
/// containers or document pickers there.
///
/// Compiled only when the `WS4K_CLOUDKIT` flag is set, because it needs a paid
/// developer account and an iCloud container entitlement. See README.md.
public actor CloudKitMusicStore {
    public static let shared = CloudKitMusicStore()

    private let logger = Logger(subsystem: "net.weatherstar.kit", category: "CloudKitMusic")

    private static let recordType = "MusicTrack"
    private enum Field {
        static let title = "title"
        static let fileName = "fileName"
        static let audio = "audio"
    }

    private let container: CKContainer
    private var database: CKDatabase { container.privateCloudDatabase }

    /// Downloaded assets are cached so the Apple TV does not refetch on every launch.
    private let cacheDirectory: URL

    public init(containerIdentifier: String? = nil) {
        // Read the container from the app's entitlements-backed Info.plist key when
        // present, so forks can point at their own container without code changes.
        let identifier = containerIdentifier
            ?? Bundle.main.object(forInfoDictionaryKey: "WS4KCloudKitContainer") as? String

        container = identifier.map { CKContainer(identifier: $0) } ?? .default()

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = caches.appendingPathComponent("CloudKitMusic", isDirectory: true)
    }

    public enum CloudError: Error, LocalizedError {
        case notSignedIn
        case assetMissing(String)

        public var errorDescription: String? {
            switch self {
            case .notSignedIn:
                "Sign in to iCloud to sync your music."
            case let .assetMissing(name):
                "The iCloud copy of \"\(name)\" is unavailable."
            }
        }
    }

    /// Whether the user has an iCloud account available.
    public func isAvailable() async -> Bool {
        do {
            return try await container.accountStatus() == .available
        } catch {
            return false
        }
    }

    // MARK: - Reading

    /// All synced tracks, with their audio cached to disk for playback.
    public func tracks() async throws -> [MusicTrack] {
        guard await isAvailable() else { throw CloudError.notSignedIn }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: Field.fileName, ascending: true)]

        var results: [MusicTrack] = []
        var cursor: CKQueryOperation.Cursor?

        repeat {
            let response = try await {
                if let cursor {
                    return try await database.records(continuingMatchFrom: cursor)
                }
                return try await database.records(matching: query)
            }()

            for (_, result) in response.matchResults {
                guard let record = try? result.get() else { continue }
                if let track = try? cacheTrack(from: record) {
                    results.append(track)
                }
            }
            cursor = response.queryCursor
        } while cursor != nil

        return results
    }

    /// Move a record's asset into the local cache and describe it as a track.
    private func cacheTrack(from record: CKRecord) throws -> MusicTrack {
        let fileName = record[Field.fileName] as? String ?? record.recordID.recordName
        guard let asset = record[Field.audio] as? CKAsset, let source = asset.fileURL else {
            throw CloudError.assetMissing(fileName)
        }

        let destination = cacheDirectory.appendingPathComponent(fileName)
        // CloudKit hands back a temporary URL, so copy it somewhere durable — but
        // only when the cached copy is missing or stale.
        let needsCopy = !FileManager.default.fileExists(atPath: destination.path)
            || (try? Data(contentsOf: source).count) != (try? Data(contentsOf: destination).count)

        if needsCopy {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
        }

        return MusicTrack(
            id: record.recordID.recordName,
            title: record[Field.title] as? String ?? MusicTrack.displayTitle(from: destination),
            url: destination,
            source: .iCloud
        )
    }

    // MARK: - Writing

    /// Upload a local audio file to iCloud so the user's other devices can play it.
    public func upload(_ url: URL) async throws {
        guard await isAvailable() else { throw CloudError.notSignedIn }

        let record = CKRecord(recordType: Self.recordType)
        record[Field.fileName] = url.lastPathComponent as CKRecordValue
        record[Field.title] = MusicTrack.displayTitle(from: url) as CKRecordValue
        record[Field.audio] = CKAsset(fileURL: url)

        _ = try await database.save(record)
        logger.info("Uploaded \(url.lastPathComponent, privacy: .public) to iCloud")
    }

    public func delete(trackID: String) async throws {
        _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: trackID))
    }

    /// Remove the on-disk cache; the records themselves stay in iCloud.
    public func clearCache() throws {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }
}
#endif
