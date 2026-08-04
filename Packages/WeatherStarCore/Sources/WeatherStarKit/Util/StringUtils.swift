import Foundation

extension String {
    /// Strip the qualifier airports carry in NWS station names, so
    /// "Chicago / West Chicago" becomes "West Chicago". Ported from `utils/string.mjs`.
    public var locationCleanup: String {
        let patterns = [
            #"^[ A-Za-z]+ / "#,   // "Chicago / West Chicago"
            #"^[ A-Za-z]+/"#,     // "Chicago/Waukegan"
            #"^[ A-Za-z]+, "#,    // "Chicago, Chicago O'hare"
        ]
        return patterns.reduce(self) { value, pattern in
            value.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression]
            )
        }
    }

    /// Truncate to `limit` characters without splitting grapheme clusters.
    public func truncated(to limit: Int) -> String {
        count <= limit ? self : String(prefix(limit))
    }

    /// Pad/truncate to an exact width, as the fixed-cell displays expect.
    public func padded(to width: Int, alignment: TextAlignmentMode = .leading) -> String {
        let trimmed = truncated(to: width)
        let padding = String(repeating: " ", count: max(0, width - trimmed.count))
        switch alignment {
        case .leading: return trimmed + padding
        case .trailing: return padding + trimmed
        }
    }

    public enum TextAlignmentMode: Sendable {
        case leading
        case trailing
    }
}

/// The degree sign the displays append to temperatures.
public let degreeSign = "\u{00B0}"

public enum ConditionText {
    /// Abbreviate a condition string that will not fit the Current Conditions
    /// field. Order matters — ported verbatim from `currentweather.mjs`.
    public static func shorten(_ condition: String) -> String {
        var result = condition
        let replacements: [(String, String)] = [
            ("Light", "L"),
            ("Heavy", "H"),
            ("Partly", "P"),
            ("Mostly", "M"),
            ("Few", "F"),
            ("Thunderstorm", "T'storm"),
            (" in ", ""),
            ("Vicinity", ""),
            (" and ", " "),
            ("Freezing Rain", "Frz Rn"),
            ("Freezing", "Frz"),
            ("Unknown Precip", ""),
            ("L Snow Fog", "L Snw/Fog"),
            (" with ", "/"),
        ]
        for (find, replace) in replacements {
            result = result.replacingOccurrences(of: find, with: replace)
        }
        return result
    }
}
