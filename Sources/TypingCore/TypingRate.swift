/// A display estimate based on accepted operations, not committed words or characters.
/// Composition and editing have the same scope as the underlying process KPM.
public enum PrimaryTypingUnit: String, Sendable {
    case wpm = "WPM", cpm = "CPM", unknown = "—"
}

public enum TypingRate {
    public static func estimatedWPM(fromKPM kpm: Double?) -> Double? {
        guard let kpm, kpm.isFinite, kpm >= 0 else { return nil }
        return kpm / 5
    }

    /// Unit preference follows input-source language, never an analysis of content.
    public static func primaryUnit(forLanguage code: String) -> PrimaryTypingUnit {
        let language = InputLanguagePolicy.normalize(code)
        if language == "und" { return .unknown }
        return ["zh", "ja", "ko", "th", "lo", "km", "my"].contains(language) ? .cpm : .wpm
    }
}
