import AppKit

/// Explicit width avoids AppKit recomputing a smaller inactive-state cell.
/// Hybrid mode reserves the same space for both speed and idle count titles.
enum StatusItemPresentation {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    static func width(for title: String, mode: String) -> CGFloat {
        let candidates = mode == "hybrid" ? [title, "⌨ ≈999 WPM", "⌨ ≈999Qi Ⅱ"] : [title]
        return ceil(candidates.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max()! + 18)
    }
}

/// At most three numeric digits, using fixed Latin magnitude suffixes in every
/// UI language. Full integer counts remain available in the underlying metric.
func compactKeystrokeCount(_ count: Int) -> String {
    guard count >= 1000 else { return String(max(0, count)) }
    let suffixes = ["", "K", "M", "B", "T", "Qa", "Qi"]
    let divisors = [1, 1_000, 1_000_000, 1_000_000_000, 1_000_000_000_000,
                    1_000_000_000_000_000, 1_000_000_000_000_000_000]
    var magnitude = 0
    while magnitude < divisors.count - 1 && count >= divisors[magnitude + 1] { magnitude += 1 }
    func rounded(at magnitude: Int) -> (units: Int, scale: Int) {
        let divisor = divisors[magnitude]
        let whole = count / divisor
        let scale = whole < 10 ? 100 : whole < 100 ? 10 : 1
        let step = divisor / scale
        // Integer quotient/remainder avoids both multiplication overflow and
        // binary floating-point ties such as 9,995 incorrectly becoming 9.99K.
        let units = count / step + (count % step >= step / 2 ? 1 : 0)
        return (units, scale)
    }
    var value = rounded(at: magnitude)
    if value.units >= 1000 * value.scale && magnitude < suffixes.count - 1 {
        magnitude += 1
        value = rounded(at: magnitude)
    }
    var number = String(value.units / value.scale)
    let fraction = value.units % value.scale
    if fraction != 0 {
        var digits = (value.scale == 100 && fraction < 10 ? "0" : "") + String(fraction)
        while digits.last == "0" { digits.removeLast() }
        number += "." + digits
    }
    return number + suffixes[magnitude]
}

func runDisplayFormattingChecks() -> [String] {
    let examples: [(Int, String)] = [
        (Int.min, "0"), (-1, "0"), (0, "0"), (1, "1"), (999, "999"),
        (1000, "1K"), (1001, "1K"), (1234, "1.23K"), (9994, "9.99K"),
        (9995, "10K"), (12_345, "12.3K"), (99_949, "99.9K"),
        (99_950, "100K"), (123_456, "123K"), (999_499, "999K"),
        (999_500, "1M"), (1_000_000, "1M"), (1_234_567, "1.23M"),
        (999_500_000, "1B"), (1_000_000_000, "1B"),
        (1_000_000_000_000, "1T"), (1_000_000_000_000_000, "1Qa"),
        (1_000_000_000_000_000_000, "1Qi"), (Int.max, "9.22Qi")
    ]
    var failures: [String] = []
    for (count, expected) in examples {
        let actual = compactKeystrokeCount(count)
        if actual != expected { failures.append("FAIL: compact count \(count): expected \(expected), got \(actual)") }
        if actual.filter(\.isNumber).count > 3 { failures.append("FAIL: compact count exceeds three numeric digits: \(actual)") }
    }
    let idleWidth = StatusItemPresentation.width(for: "⌨ ≈506", mode: "hybrid")
    let typingWidth = StatusItemPresentation.width(for: "⌨ ≈85 WPM", mode: "hybrid")
    if idleWidth != typingWidth { failures.append("FAIL: hybrid idle title must retain speed-mode width") }
    for title in ["⌨ ≈506", "⌨ ≈999 WPM", "⌨ ≈9.22Qi Ⅱ", "⌨ — WPM", "⌨ Ⅱ"] {
        let measured = (title as NSString).size(withAttributes: [.font: StatusItemPresentation.font]).width
        if StatusItemPresentation.width(for: title, mode: "hybrid") < ceil(measured) + 16 {
            failures.append("FAIL: status item clips title: \(title)")
        }
    }
    return failures
}
