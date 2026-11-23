import SwiftUI

enum Dashboard {
    static let panelFill = Color(white: 0.085)
    static let readoutFont = Font.system(.title3, design: .monospaced).weight(.bold)
    static let captionFont = Font.system(.caption, design: .monospaced)
}

/// Dark framed container every dashboard block sits in.
struct Panel<Content: View>: View {
    var tint: Color = .white
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Dashboard.panelFill, in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(tint.opacity(0.28), lineWidth: 1)
            }
    }
}

/// Title on the left, live readout on the right, in the instrument typeface.
struct PanelHeader: View {
    let title: String
    var value: String = ""
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
            Spacer(minLength: 8)
            Text(value)
        }
        .font(Dashboard.readoutFont)
        .foregroundStyle(tint)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// Small bottom-row block: icon, title, one headline number, a line of detail and a meter.
struct StatTile: View {
    let title: String
    let symbol: String
    let value: String
    let detail: String
    let fraction: Double
    let tint: Color

    var body: some View {
        Panel(tint: tint) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol)
                        .foregroundStyle(tint)
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(value)
                        .font(.system(.body, design: .monospaced).weight(.bold))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                SegmentMeter(fraction: fraction, tint: tint, segments: 22, axis: .horizontal)
                    .frame(height: 14)
            }
        }
    }
}
