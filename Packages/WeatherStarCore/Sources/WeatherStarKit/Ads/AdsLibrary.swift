import CoreGraphics
import Foundation
import ImageIO
import Observation
import OSLog

/// The ads the companion server offers, fetched only when the user has asked for them.
///
/// Nothing here touches the network until a feature that needs the server is switched on and
/// the server's address is set. Ads are an extra the user opts into, on a server of their own;
/// an app that fetched `ads.json` in the background "just in case" would be contacting a server
/// the user had not yet chosen to use for this.
@MainActor
@Observable
public final class AdsLibrary {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    private static let logger = Logger(subsystem: "net.weatherstar.kit", category: "Ads")

    /// The last manifest fetched, or empty.
    public private(set) var manifest: AdsManifest = .empty
    /// Card images, fetched with the manifest so a card shows at once when its turn comes.
    public private(set) var cardImages: [String: CGImage] = [:]
    /// Why the last fetch failed, for Settings to show.
    public private(set) var lastError: String?

    @ObservationIgnored private let fetch: Fetch

    public init(fetch: Fetch? = nil) {
        self.fetch = fetch ?? { url in
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadRevalidatingCacheData
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            return data
        }
    }

    /// Whether anything the user has switched on needs the server.
    public static func needsServer(_ settings: AppSettings) -> Bool {
        settings.tickerAdsEnabled || settings.adCardsEnabled || settings.clipReelEnabled
    }

    /// Fetch the manifest, if the settings call for it; otherwise forget any old one.
    public func refresh(settings: AppSettings) async {
        guard Self.needsServer(settings), let base = settings.remoteMusicURL,
              let url = AdsManifest.manifestURL(base: base)
        else {
            manifest = .empty
            cardImages = [:]
            lastError = nil
            return
        }
        do {
            let data = try await fetch(url)
            let fetched = try AdsManifest.decode(data, base: base)
            manifest = fetched
            lastError = nil
            if settings.adCardsEnabled {
                await loadImages(for: fetched.cards)
            }
        } catch {
            Self.logger.warning("Ads manifest unavailable: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    private func loadImages(for cards: [AdCard]) async {
        var images: [String: CGImage] = [:]
        for card in cards {
            guard let url = card.image, let data = try? await fetch(url),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { continue }
            images[card.id] = image
        }
        cardImages = images
    }
}
