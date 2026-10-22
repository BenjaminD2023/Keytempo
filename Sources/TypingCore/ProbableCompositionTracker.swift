import Foundation

/// Metadata-only decisions for the global estimate path. Ignoring an accepted
/// space suppresses its count without sending an interruption to the timing core.
public enum ProbableInputDecision: Equatable, Sendable {
    case classified(InputCategory, Evidence)
    case ignoredSpace
}

/// A short-lived IME hypothesis, never proof of composition or submitted text.
/// Stores no characters or key sequence: only a flag, timestamp and context ID.
public struct ProbableCompositionTracker: Sendable {
    public private(set) var isActive = false
    private var lastTime: Double?
    private var contextVersion: UInt64?
    private let maximumGap: Double
    private static let letters: Set<Int64> = [0,1,2,3,4,5,6,7,8,9,11,12,13,14,15,16,17,31,32,34,35,37,38,40,45,46]
    private static let arrows: Set<Int64> = [123,124,125,126]
    private static let candidatePaging: Set<Int64> = [24,27,33,30]

    public init(maximumGap: Double = 3) {
        self.maximumGap = maximumGap.isFinite ? max(0.25, min(6, maximumGap)) : 3
    }

    public mutating func reset() {
        isActive = false
        lastTime = nil
        contextVersion = nil
    }

    public mutating func classify(key: Int64, time: Double, contextVersion: UInt64,
                                  command: Bool = false, control: Bool = false,
                                  shift: Bool = false, option: Bool = false,
                                  synthetic: Bool = false, repeated: Bool = false,
                                  editable: Bool, inputMethod: Bool, valid: Bool) -> ProbableInputDecision {
        let validTime = time.isFinite && time >= 0
        if repeated {
            reset()
            return .classified(.unknown, .unknown)
        }
        guard valid && editable && validTime && !command && !control && !synthetic else {
            reset()
            let result = MetadataClassifier.classify(key: key, command: command, control: control,
                                                     synthetic: synthetic, editable: editable,
                                                     inputMethod: inputMethod, valid: valid && validTime)
            return .classified(result.0, result.1)
        }

        if self.contextVersion != contextVersion || (lastTime.map { time <= $0 || time - $0 > maximumGap } ?? false) {
            reset()
        }
        // A user-requested exclusion applies to both ordinary spaces and IME
        // confirmation spaces. It does not claim that a space submitted text.
        if key == 49 {
            reset()
            return .ignoredSpace
        }

        let plain = !shift && !option
        let composition = inputMethod && plain && isActive
        // Chinese candidate rows can be paged with =, -, [ and ]. Preserve
        // only an existing valid IME hypothesis; otherwise these remain text.
        if composition && Self.candidatePaging.contains(key) {
            lastTime = time
            return .classified(.composition, .probable)
        }
        let result = MetadataClassifier.classify(key: key, command: false, control: false,
                                                 synthetic: false, editable: true,
                                                 inputMethod: inputMethod && plain, valid: true,
                                                 probableComposition: composition)
        if inputMethod && plain && result.0 == .textEntry && Self.letters.contains(key) {
            isActive = true
            lastTime = time
            self.contextVersion = contextVersion
        } else if composition && (result.0 == .editing || (result.0 == .composition && Self.arrows.contains(key))) {
            lastTime = time
        } else {
            // A selection digit or Return can finish a candidate. Unknown
            // commands, special-character paths and non-IME input also reset.
            reset()
        }
        return .classified(result.0, result.1)
    }
}
