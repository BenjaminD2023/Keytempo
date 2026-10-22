import Foundation

/// Conservative macOS physical-key classification for the global estimate path.
/// An editable role is context evidence, never proof of a text insertion.
/// Shift/Option are intentionally not rejection flags: layouts, dead keys and
/// special-character input remain eligible for probable text activity.
public enum MetadataClassifier {
    private static let navigation: Set<Int64> = [53, 115, 119, 116, 121, 123, 124, 125, 126]
    private static let ambiguousAction: Set<Int64> = [36, 48, 76]
    private static let candidateKeys: Set<Int64> = [49, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
    private static let candidateSelection: Set<Int64> = [18,19,20,21,23,22,26,28,25,29,82,83,84,85,86,87,88,89,91,92,123,124,125,126,36,76]
    private static let printable: Set<Int64> = [0,1,2,3,4,5,6,7,8,9,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,37,38,39,40,41,42,43,44,45,46,47,49,50,65,67,69,75,78,81,82,83,84,85,86,87,88,89,91,92]

    public static func classify(key: Int64, command: Bool, control: Bool,
                                synthetic: Bool, editable: Bool, inputMethod: Bool,
                                valid: Bool, probableComposition: Bool = false) -> (InputCategory, Evidence) {
        if command || control { return (.command, .unknown) }
        if synthetic { return (.generated, .unknown) }
        guard valid && editable else { return (.unknown, .unknown) }
        // This flag is a bounded, context-filtered IME heuristic, not a marked
        // text or commit observation. It never establishes character coverage.
        if inputMethod && probableComposition && candidateSelection.contains(key) { return (.composition, .probable) }
        if key == 51 || key == 117 { return (.editing, .probable) }
        if navigation.contains(key) { return (inputMethod ? .unknown : .navigation, .unknown) }
        if ambiguousAction.contains(key) { return (.unknown, .unknown) }
        if inputMethod && candidateKeys.contains(key) { return (.unknown, .unknown) }
        return printable.contains(key) ? (.textEntry, .probable) : (.navigation, .unknown)
    }
}
