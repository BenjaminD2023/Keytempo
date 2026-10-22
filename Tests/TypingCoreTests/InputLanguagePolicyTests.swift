import Testing
@testable import TypingCore

struct InputLanguagePolicyTests {
    @Test func allAndEmptySelectionsAreDifferent() {
        let all = InputLanguagePolicy()
        let none = InputLanguagePolicy(selectedCodes: [])
        for code in ["en", "zh-Hans", "ja", "", "und"] {
            checkTrue(all.allows(languageCode: code))
            checkTrue(!none.allows(languageCode: code))
        }
    }

    @Test func declaredLanguageGroupsAndUnknownAreExplicit() {
        let selected = InputLanguagePolicy(selectedCodes: ["zh-Hans", "en-US"])
        for code in ["zh", "zh-Hant", "zh_CN", "en", "en-GB"] {
            checkTrue(selected.allows(languageCode: code))
        }
        for code in ["ja", "de", "und", "", "mul", "zxx", "invalid"] {
            checkTrue(!selected.allows(languageCode: code))
        }
        let unknown = InputLanguagePolicy(selectedCodes: ["und"])
        checkTrue(unknown.allows(languageCode: ""))
        checkTrue(!unknown.allows(languageCode: "en"))
    }
}
