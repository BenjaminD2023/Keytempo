import Foundation

/// A presentation scale shared by icon geometry, motion and previews. It never
/// changes the measured WPM. One-percent raster precision bounds the tiny icon
/// cache; motion uses the full continuous fraction.
struct MenuIconSpeedRange: Equatable, Sendable {
    static let `default` = MenuIconSpeedRange(lowWPM: 20, highWPM: 120)!
    let lowWPM: Double
    let highWPM: Double

    init?(lowWPM: Double, highWPM: Double) {
        guard lowWPM.isFinite, highWPM.isFinite, lowWPM >= 0,
              highWPM <= 1_000, highWPM >= lowWPM + 1 else { return nil }
        self.lowWPM = lowWPM
        self.highWPM = highWPM
    }

    func fraction(wpm: Double?) -> Double? {
        guard let wpm, wpm.isFinite, wpm > 0 else { return nil }
        return min(1, max(0, (wpm - lowWPM) / (highWPM - lowWPM)))
    }

    func percentage(wpm: Double?) -> Int? {
        fraction(wpm: wpm).map { Int(($0 * 100).rounded()) }
    }

    var previewSamples: [Double] { [lowWPM, (lowWPM + highWPM) / 2, highWPM] }

    /// A finite five-second sweep followed by one second at full intensity.
    func previewWPM(elapsed: TimeInterval) -> Double {
        let fraction = elapsed.isFinite ? min(1, max(0, elapsed / 5)) : 0
        return lowWPM + (highWPM - lowWPM) * fraction
    }
}
