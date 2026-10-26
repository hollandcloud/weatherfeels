import Foundation

/// A weather alert serious enough to interrupt the rotation.
///
/// The WeatherStar ran its local forecast on a loop and broke into it when the National
/// Weather Service issued a warning for the area. This is that break: a full-screen bulletin
/// with the warning's own text, a chime, and then the Hazards display, ahead of everything
/// else, until the warning goes away.
public struct WeatherBulletin: Sendable, Identifiable, Equatable {
    /// The NWS alert identifier. An update to an alert arrives with a new one, and is shown.
    public var id: String
    /// "Tornado Warning".
    public var event: String
    /// The NWS's one-line summary: who issued it, for where, until when.
    public var headline: String
    /// The body of the warning — where the storm is, where it is heading, what it carries —
    /// followed by what to do.
    public var text: String
    public var expires: Date?

    public init(id: String, event: String, headline: String, text: String, expires: Date? = nil) {
        self.id = id
        self.event = event
        self.headline = headline
        self.text = text
        self.expires = expires
    }

    /// Whether an alert warrants interrupting the screen.
    ///
    /// Warnings — the NWS's word for a hazard that is happening or about to — and anything it
    /// grades Extreme. Watches, advisories and statements stay where they already appear, on
    /// the Hazards display and the red ticker: breaking into the picture for a Wind Advisory
    /// would teach people to ignore the bulletin before the day it matters. Cancellations are
    /// not news worth a chime either.
    public static func isWorthInterrupting(event: String, severity: String?, messageType: String?) -> Bool {
        if messageType?.lowercased() == "cancel" { return false }
        if severity?.lowercased() == "extreme" { return true }
        return event.range(of: "warning", options: .caseInsensitive) != nil
    }

    /// Bulletins not already shown, most severe first as the NWS ordered them.
    ///
    /// `shown` is remembered across launches, so reopening the app during a warning does not
    /// sound the chime again for the same one.
    public static func unseen(_ bulletins: [WeatherBulletin], shown: Set<String>) -> [WeatherBulletin] {
        bulletins.filter { !shown.contains($0.id) }
    }
}

extension WeatherBulletin {
    init?(alert: AlertFeature) {
        let properties = alert.properties
        guard Self.isWorthInterrupting(
            event: properties.event,
            severity: properties.severity,
            messageType: properties.messageType
        ) else { return nil }

        // The NWS hard-wraps alert text at about 70 columns; reflow it, keeping the breaks
        // between paragraphs, so it fills the screen's width instead of the teletype's.
        func reflow(_ raw: String?) -> String {
            (raw ?? "")
                .replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: "\n\n")
                .map { $0.split(whereSeparator: \.isNewline).joined(separator: " ") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }

        self.init(
            id: alert.id,
            event: properties.event,
            headline: properties.headline ?? properties.areaDesc ?? "",
            text: [reflow(properties.description), reflow(properties.instruction)]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n"),
            expires: properties.ends ?? properties.expires
        )
    }
}
