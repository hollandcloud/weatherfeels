import Foundation
import Observation
import OSLog

/// How uploads are delivered to the configured location.
public enum UploadProtocol: String, Codable, Sendable, CaseIterable {
    /// `POST {base}/upload` as `multipart/form-data`. What the bundled companion
    /// server expects.
    case multipart
    /// `PUT {base}{uploadPath}/{filename}`. Works with WebDAV and most object stores.
    case webdavPut

    public var displayName: String {
        switch self {
        case .multipart: "Companion server (POST)"
        case .webdavPut: "WebDAV / PUT"
        }
    }
}

public enum TransferError: Error, LocalizedError, Sendable {
    case notConfigured
    case unreadableFile(String)
    case rejected(Int, String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Set a music server address in Settings before uploading."
        case let .unreadableFile(name):
            "Could not read \"\(name)\"."
        case let .rejected(code, message):
            "Server rejected the upload (HTTP \(code)): \(message)"
        case .cancelled:
            "Upload cancelled."
        }
    }
}

/// Progress for one file in a batch upload.
public struct UploadProgress: Sendable, Identifiable, Hashable {
    public enum State: Sendable, Hashable {
        case waiting
        case uploading(Double)
        case finished
        case failed(String)
    }

    public let id: String
    public let fileName: String
    public var state: State = .waiting

    public init(fileName: String) {
        id = fileName
        self.fileName = fileName
    }
}

/// Copies audio files into the app and pushes them to the configured music location.
///
/// Import and upload are separate steps on purpose: importing makes a file playable
/// on *this* device immediately, and uploading makes it reachable from the Apple TV.
@MainActor
@Observable
public final class MusicTransfer {
    private let logger = Logger(subsystem: "net.weatherstar.kit", category: "MusicTransfer")
    private let settings: AppSettings
    private let session: URLSession

    public private(set) var uploads: [UploadProgress] = []
    public private(set) var isBusy = false

    public init(settings: AppSettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    // MARK: - Local import

    /// Copy picked files into the app's music folder.
    ///
    /// `urls` may be security-scoped (from a document picker), so access is
    /// bracketed. Returns the tracks that were successfully imported.
    @discardableResult
    public func importFiles(_ urls: [URL]) throws -> [MusicTrack] {
        let destination = try MusicStorage.ensureDirectory()
        var imported: [MusicTrack] = []

        for url in urls where SupportedAudio.isSupported(url) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let target = uniqueDestination(for: url.lastPathComponent, in: destination)
            do {
                try FileManager.default.copyItem(at: url, to: target)
                imported.append(MusicTrack(url: target, source: .localFiles))
            } catch {
                logger.warning(
                    "Import failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription)"
                )
            }
        }

        return imported
    }

    /// Avoid clobbering an existing file by appending " (2)", " (3)", …
    private func uniqueDestination(for fileName: String, in directory: URL) -> URL {
        let candidate = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var counter = 2
        while true {
            let name = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            let next = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: next.path) { return next }
            counter += 1
        }
    }

    public func deleteLocalTrack(_ track: MusicTrack) throws {
        guard track.source == .localFiles else { return }
        try FileManager.default.removeItem(at: track.url)
    }

    // MARK: - Upload

    /// Upload files to the configured server so other devices — notably the Apple TV
    /// — can play them.
    public func upload(
        _ urls: [URL],
        using uploadProtocol: UploadProtocol = .multipart
    ) async throws {
        guard let base = settings.remoteMusicURL else { throw TransferError.notConfigured }

        let audioURLs = urls.filter(SupportedAudio.isSupported)
        guard !audioURLs.isEmpty else { return }

        uploads = audioURLs.map { UploadProgress(fileName: $0.lastPathComponent) }
        isBusy = true
        defer { isBusy = false }

        for (index, url) in audioURLs.enumerated() {
            uploads[index].state = .uploading(0)
            do {
                try await send(url, to: base, using: uploadProtocol)
                uploads[index].state = .finished
            } catch {
                uploads[index].state = .failed(error.localizedDescription)
                logger.warning(
                    "Upload failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription)"
                )
            }
        }
    }

    private func send(_ url: URL, to base: URL, using uploadProtocol: UploadProtocol) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw TransferError.unreadableFile(url.lastPathComponent)
        }

        let request: URLRequest = switch uploadProtocol {
        case .multipart: multipartRequest(base: base, fileName: url.lastPathComponent, data: data)
        case .webdavPut: putRequest(base: base, fileName: url.lastPathComponent)
        }

        let body: Data? = uploadProtocol == .webdavPut ? data : nil
        let (responseData, response) = body == nil
            ? try await session.data(for: request)
            : try await session.upload(for: request, from: body!)

        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: responseData, encoding: .utf8) ?? "no detail"
            throw TransferError.rejected(http.statusCode, message.prefix(200).description)
        }
    }

    /// `multipart/form-data` POST, matching the bundled companion server.
    private func multipartRequest(base: URL, fileName: String, data: Data) -> URLRequest {
        let boundary = "ws4k-\(UUID().uuidString)"
        var request = URLRequest(url: base.appending(path: "upload"))
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        applyAuthorization(to: &request)

        var body = Data()
        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"path\"\r\n\r\n")
        append("\(settings.uploadPath)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(Self.mimeType(for: fileName))\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

        request.httpBody = body
        return request
    }

    /// Plain `PUT` to a path, for WebDAV servers and object stores.
    private func putRequest(base: URL, fileName: String) -> URLRequest {
        let directory = settings.uploadPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var target = base
        if !directory.isEmpty { target = target.appending(path: directory) }
        target = target.appending(path: fileName)

        var request = URLRequest(url: target)
        request.httpMethod = "PUT"
        request.setValue(Self.mimeType(for: fileName), forHTTPHeaderField: "Content-Type")
        applyAuthorization(to: &request)
        return request
    }

    private func applyAuthorization(to request: inout URLRequest) {
        let token = settings.uploadToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private static func mimeType(for fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "mp3": "audio/mpeg"
        case "m4a", "mp4", "alac": "audio/mp4"
        case "aac": "audio/aac"
        case "wav": "audio/wav"
        case "aif", "aiff": "audio/aiff"
        case "flac": "audio/flac"
        case "caf": "audio/x-caf"
        default: "application/octet-stream"
        }
    }
}
