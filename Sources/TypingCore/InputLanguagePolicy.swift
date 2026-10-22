import Foundation

/// Selects an input source's declared primary language, never the text it emits.
/// nil means every source; an explicit empty set means monitor no languages.
public struct InputLanguagePolicy: Equatable, Sendable {
    public let selectedCodes: Set<String>?

    public init(selectedCodes: Set<String>? = nil) {
        self.selectedCodes = selectedCodes.map { Set($0.map(Self.normalize)) }
    }

    public static func normalize(_ code: String) -> String {
        let base = code.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", omittingEmptySubsequences: false).first.map(String.init)?.lowercased() ?? ""
        guard (2...3).contains(base.count), base.allSatisfy({ $0.isASCII && $0.isLetter }),
              !["und", "mul", "zxx"].contains(base) else { return "und" }
        return base
    }

    public func allows(languageCode: String) -> Bool {
        selectedCodes?.contains(Self.normalize(languageCode)) ?? true
    }
}
