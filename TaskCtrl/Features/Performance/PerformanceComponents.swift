import SwiftUI

/// One line in a chart or sparkline, read out of the history.
struct ChartSeries: Identifiable {
    let name: String
    let tint: Color
    /// Nil leaves a gap, e.g. while a sensor has no reading.
    let value: (HistoryPoint) -> Double?

    var id: String { name }
}

extension ChartSeries {
    /// The series as a line for `ScrollingChart`, scaled into `domain`.
    /// Samples without a reading are skipped, so the line bridges the gap.
    func line(over points: [HistoryPoint], domain: ClosedRange<Double>) -> ScrollingChart.Line {
        let span = max(domain.upperBound - domain.lowerBound, .leastNonzeroMagnitude)
        return .init(tint: tint, points: points.compactMap { point in
            value(point).map { .init(date: point.date, value: ($0 - domain.lowerBound) / span) }
        })
    }
}

/// Tiny line chart for the resource list and per-core tiles: lines only,
/// moving the same way as the big charts.
struct Sparkline: View {
    let points: [HistoryPoint]
    let series: [ChartSeries]
    let domain: ClosedRange<Double>

    var body: some View {
        ScrollingChart(lines: series.map { $0.line(over: points, domain: domain) }, style: .spark)
    }
}

/// Large framed chart with a caption above it.
struct SeriesChart: View {
    let title: String
    let points: [HistoryPoint]
    let series: [ChartSeries]
    var tint: Color = .green
    var domain: ClosedRange<Double> = 0...1
    var label: (Double) -> String = { $0.formatted(.percent.precision(.fractionLength(0))) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                if series.count > 1 {
                    ForEach(series) { line in
                        Text(line.name)
                            .font(.caption)
                            .foregroundStyle(line.tint)
                    }
                }
            }
            HStack(spacing: 6) {
                AxisLabels(
                    labels: [
                        label(domain.upperBound),
                        label((domain.lowerBound + domain.upperBound) / 2),
                        label(domain.lowerBound),
                    ],
                    tint: .secondary,
                    alignment: .trailing
                )
                ScrollingChart(lines: series.map { $0.line(over: points, domain: domain) }, tint: tint)
            }
        }
    }
}

/// Big number with a small caption above, for the headline figures.
struct StatValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Two-column list of static facts.
struct PropertyGrid: View {
    let properties: [(name: String, value: String)]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(properties, id: \.name) { property in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(property.name + ":")
                        .foregroundStyle(.secondary)
                        .frame(width: 150, alignment: .leading)
                    Text(property.value)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.callout.monospacedDigit())
            }
        }
    }
}

/// Shared frame of a detail page: title, headline value, a level bar, then content.
struct DetailPage<Content: View>: View {
    let title: String
    let subtitle: String
    let value: String
    /// Nil hides the bar for resources that have no natural 0...1 level.
    let fraction: Double?
    let tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                HStack(spacing: 16) {
                    if let fraction {
                        SegmentMeter(fraction: fraction, tint: tint, segments: 56, axis: .horizontal)
                            .frame(height: 18)
                    } else {
                        Spacer()
                    }
                    Text(value)
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(tint)
                        .contentTransition(.numericText())
                }
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                content
            }
            .padding(20)
        }
    }
}

extension TimeInterval {
    /// Up time as "0:01:27:52" (days:hours:minutes:seconds).
    var uptimeFormatted: String {
        let total = Int(max(self, 0))
        return String(
            format: "%d:%02d:%02d:%02d",
            total / 86_400, total / 3600 % 24, total / 60 % 60, total % 60
        )
    }
}

extension Array where Element == HistoryPoint {
    /// Top of a chart that fits the recent peak with headroom, never below `floor`.
    func ceiling(floor: Double, _ value: (HistoryPoint) -> Double?) -> Double {
        Swift.max(floor, (compactMap(value).max() ?? 0) * 1.2)
    }
}
