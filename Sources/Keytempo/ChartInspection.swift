import AppKit
import Charts
import SwiftUI

private typealias ChartInspectionState<Value> = SwiftUI.State<Value>

/// Rates keep their measured precision when inspecting a chart, independently
/// of the rounded values used in summary labels.
func chartExactValue(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    return value.formatted(.number.locale(AppLanguage.currentLocale).precision(.fractionLength(2)))
}

struct DateChartInspectionPoint: Identifiable {
    let id: String
    let date: Date
    let endDate: Date?
    let title: String
    let details: [String]

    init(id: String, date: Date, endDate: Date? = nil, title: String, details: [String]) {
        self.id = id
        self.date = date
        self.endDate = endDate
        self.title = title
        self.details = details
    }
}

struct CategoryChartInspectionPoint: Identifiable {
    let id: String
    let category: String
    let title: String
    let details: [String]
}

extension View {
    func inspectDateChart(_ points: [DateChartInspectionPoint]) -> some View {
        modifier(ChartInspectionModifier(points: points.map {
            ChartInspectionPoint(id: $0.id, position: .date($0.date, end: $0.endDate), title: $0.title, details: $0.details)
        }))
    }

    func inspectCategoryChart(_ points: [CategoryChartInspectionPoint]) -> some View {
        modifier(ChartInspectionModifier(points: points.map {
            ChartInspectionPoint(id: $0.id, position: .category($0.category), title: $0.title, details: $0.details)
        }))
    }
}

private struct ChartInspectionPoint: Identifiable {
    enum Position {
        case date(Date, end: Date?)
        case category(String)
    }

    let id: String
    let position: Position
    let title: String
    let details: [String]

    func xPosition(in proxy: ChartProxy) -> CGFloat? {
        switch position {
        case let .date(start, end):
            let center = end.map { start.addingTimeInterval($0.timeIntervalSince(start) / 2) } ?? start
            return proxy.position(forX: center)
        case let .category(value):
            return proxy.position(forX: value)
        }
    }
}

/// Uses chart coordinates rather than view-width estimates, so categorical
/// bars and date buckets remain accurate after resizing or axis changes.
private struct ChartInspectionModifier: ViewModifier {
    let points: [ChartInspectionPoint]
    @ChartInspectionState private var selectedID: String?
    @ChartInspectionState private var panelHeight: CGFloat = 100

    private var selectedPoint: ChartInspectionPoint? { points.first { $0.id == selectedID } }

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            GeometryReader { geometry in
                let plot = geometry[proxy.plotAreaFrame]
                let panelWidth = max(1, min(280, geometry.size.width - 28))
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case let .active(location):
                                guard plot.contains(location) else {
                                    selectedID = nil
                                    return
                                }
                                selectedID = point(at: location.x - plot.minX, in: proxy)?.id
                            case .ended:
                                selectedID = nil
                            }
                        }
                    if let point = selectedPoint, let position = point.xPosition(in: proxy) {
                        let x = plot.minX + position
                        Path { path in
                            path.move(to: CGPoint(x: x, y: plot.minY))
                            path.addLine(to: CGPoint(x: x, y: plot.maxY))
                        }
                        .stroke(Color.secondary.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .allowsHitTesting(false)
                        inspectionPanel(point)
                            .frame(width: panelWidth, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                            .background {
                                GeometryReader { panel in
                                    Color.clear.preference(key: ChartInspectionHeightKey.self, value: panel.size.height)
                                }
                            }
                            .position(
                                x: min(max(x, (panelWidth + 20) / 2 + 4), geometry.size.width - (panelWidth + 20) / 2 - 4),
                                y: max(panelHeight / 2 + 4, min(plot.minY + panelHeight / 2 + 6, geometry.size.height - panelHeight / 2 - 4))
                            )
                            .allowsHitTesting(false)
                    }
                }
                .onPreferenceChange(ChartInspectionHeightKey.self) { panelHeight = $0 }
                .accessibilityHidden(true)
            }
        }
        .onChange(of: points.map(\.id)) { ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
        }
    }

    private func inspectionPanel(_ point: ChartInspectionPoint) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(point.title).font(.caption.weight(.semibold))
            ForEach(Array(point.details.enumerated()), id: \.offset) { _, detail in
                Text(detail).font(.caption).monospacedDigit()
            }
        }
        .foregroundStyle(.primary)
    }

    private func point(at x: CGFloat, in proxy: ChartProxy) -> ChartInspectionPoint? {
        if let category = proxy.value(atX: x, as: String.self),
           let match = points.first(where: {
               if case let .category(value) = $0.position { return value == category }
               return false
           }) {
            return match
        }
        guard let date = proxy.value(atX: x, as: Date.self) else { return nil }
        let datePoints = points.compactMap { point -> (point: ChartInspectionPoint, start: Date, end: Date?)? in
            guard case let .date(start, end) = point.position else { return nil }
            return (point, start, end)
        }
        // Recorded intervals have real boundaries. Hovering an unrecorded hour
        // must not silently select a neighboring hour and imply activity there.
        if datePoints.contains(where: { $0.end != nil }) {
            return datePoints.first { sample in
                guard let end = sample.end else { return false }
                return date >= sample.start && date < end
            }?.point
        }
        return datePoints.min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }?.point
    }
}

private struct ChartInspectionHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 100
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
