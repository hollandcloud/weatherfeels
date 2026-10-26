import Foundation

/// The ads a companion server offers: ticker lines, local ad cards and a clip reel.
///
/// Decoded from `ads.json`, schema v1, as `server/README.md` documents it. Leniently: a field
/// the app does not know is ignored, a missing optional takes its default, an unrecognised
/// theme falls back to blue, and one malformed item is dropped rather than losing the whole
/// file. The manifest is something a person edits — through the admin page, or by hand on a
/// static host — and a typo in one card should cost that card, not the reel.
public struct AdsManifest: Sendable, Equatable {
    public var ticker: [TickerAd]
    public var cards: [AdCard]
    public var clips: [AdClip]

    public init(ticker: [TickerAd] = [], cards: [AdCard] = [], clips: [AdClip] = []) {
        self.ticker = ticker
        self.cards = cards
        self.clips = clips
    }

    public static let empty = AdsManifest()
}

public struct TickerAd: Sendable, Equatable {
    public var id: String
    public var text: String
}

/// A full-screen "local business" ad in WeatherStar style.
public struct AdCard: Sendable, Equatable, Identifiable {
    public enum Theme: String, Sendable, CaseIterable {
        case blue, red, green, gold, purple
    }

    public enum ImageMode: String, Sendable {
        /// The image beside the text.
        case beside
        /// The image fills the card and the text is left off.
        case full
    }

    public var id: String
    public var business: String
    public var headline: String?
    public var lines: [String]
    public var phone: String?
    public var footer: String?
    /// Already resolved against the server, and only ever on the server's own host.
    public var image: URL?
    public var imageMode: ImageMode
    public var theme: Theme
    /// How long the card holds, 4 to 30 seconds.
    public var seconds: Int

    public init(
        id: String, business: String, headline: String? = nil, lines: [String] = [],
        phone: String? = nil, footer: String? = nil, image: URL? = nil,
        imageMode: ImageMode = .beside, theme: Theme = .blue, seconds: Int = 10
    ) {
        self.id = id
        self.business = business
        self.headline = headline
        self.lines = lines
        self.phone = phone
        self.footer = footer
        self.image = image
        self.imageMode = imageMode
        self.theme = theme
        self.seconds = seconds
    }
}

/// A video in the clip reel.
public struct AdClip: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String?
    public var file: URL
    /// The longest the clip may run, when the manifest caps it.
    public var seconds: Int?
}

// MARK: - Decoding

extension AdsManifest {
    /// Decode a manifest, resolving its file paths against the server it came from.
    ///
    /// `base` is the server's address as the user typed it. Paths in the manifest are relative
    /// to the server root; an absolute URL is only accepted on the same host, so a manifest can
    /// never make the app fetch from somewhere the user did not point it at.
    public static func decode(_ data: Data, base: URL) throws -> AdsManifest {
        let raw = try JSONDecoder().decode(RawManifest.self, from: data)
        let root = Self.root(of: base)

        func resolve(_ path: String?) -> URL? {
            guard let path, !path.isEmpty else { return nil }
            if let absolute = URL(string: path), absolute.scheme != nil {
                return absolute.host?.lowercased() == root.host?.lowercased() ? absolute : nil
            }
            let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
            return URL(string: relative, relativeTo: root)?.absoluteURL
        }

        return AdsManifest(
            ticker: raw.ticker.items.compactMap { item in
                guard let id = item.id, let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty, item.enabled != false
                else { return nil }
                return TickerAd(id: id, text: text)
            },
            cards: raw.cards.items.compactMap { item in
                guard let id = item.id, let business = item.business, !business.isEmpty, item.enabled != false
                else { return nil }
                return AdCard(
                    id: id,
                    business: business,
                    headline: item.headline,
                    lines: Array((item.lines ?? []).prefix(4)),
                    phone: item.phone,
                    footer: item.footer,
                    image: resolve(item.image),
                    imageMode: item.imageMode.flatMap(AdCard.ImageMode.init(rawValue:)) ?? .beside,
                    theme: item.theme.flatMap(AdCard.Theme.init(rawValue:)) ?? .blue,
                    seconds: min(max(item.seconds ?? 10, 4), 30)
                )
            },
            clips: raw.clips.items.compactMap { item in
                guard let id = item.id, let file = resolve(item.file), item.enabled != false else { return nil }
                return AdClip(id: id, title: item.title, file: file, seconds: item.seconds)
            }
        )
    }

    /// The server's root as a directory URL.
    ///
    /// Relative resolution drops the last path component of a base that does not end in a
    /// slash: `ads/x.png` against `http://nas/ws4k` comes out as `http://nas/ads/x.png`. A
    /// server behind a path prefix would lose it, so the base is made a directory first.
    public static func root(of base: URL) -> URL {
        base.absoluteString.hasSuffix("/") ? base : URL(string: base.absoluteString + "/") ?? base
    }

    /// The manifest's own address on a server.
    public static func manifestURL(base: URL) -> URL? {
        URL(string: "ads.json", relativeTo: root(of: base))?.absoluteURL
    }

    private struct RawManifest: Decodable {
        var ticker: Lossy<RawTicker> = .init()
        var cards: Lossy<RawCard> = .init()
        var clips: Lossy<RawClip> = .init()

        enum CodingKeys: String, CodingKey { case ticker, cards, clips }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ticker = (try? container.decodeIfPresent(Lossy<RawTicker>.self, forKey: .ticker)) ?? .init()
            cards = (try? container.decodeIfPresent(Lossy<RawCard>.self, forKey: .cards)) ?? .init()
            clips = (try? container.decodeIfPresent(Lossy<RawClip>.self, forKey: .clips)) ?? .init()
        }
    }

    private struct RawTicker: Decodable {
        var id: String?
        var text: String?
        var enabled: Bool?
    }

    private struct RawCard: Decodable {
        var id: String?
        var business: String?
        var headline: String?
        var lines: [String]?
        var phone: String?
        var footer: String?
        var image: String?
        var imageMode: String?
        var theme: String?
        var seconds: Int?
        var enabled: Bool?
    }

    private struct RawClip: Decodable {
        var id: String?
        var title: String?
        var file: String?
        var seconds: Int?
        var enabled: Bool?
    }

    /// An array whose malformed elements are skipped instead of failing the array.
    private struct Lossy<Element: Decodable>: Decodable {
        var items: [Element] = []

        init() {}

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            while !container.isAtEnd {
                if let item = try? container.decode(Element.self) {
                    items.append(item)
                } else {
                    _ = try? container.decode(Skip.self)
                }
            }
        }

        /// Consumes one element of any shape.
        ///
        /// Reads nothing, so it succeeds on a string or a number as well as an object. The
        /// synthesised initialiser would ask for a keyed container, fail on anything else, and
        /// leave the array's cursor where it was — looping forever on a stray value.
        private struct Skip: Decodable {
            init(from decoder: Decoder) throws {}
        }
    }
}
