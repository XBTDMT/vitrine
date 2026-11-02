import SwiftUI
import VitrineUI

// The Diagnostics window's building blocks, drawn from the unified design system (design/mockups/unified/
// diagnostics.html and system.html; S-10). Every colour is a `--v-*` token, every size a Metric token.

extension Font {
    /// A type token from the design system: `.v("body")` is `--v-fs-body`, 13 pt.
    static func v(_ token: String, _ weight: Font.Weight = .regular) -> Font {
        .system(size: Metric.value("fs-" + token), weight: weight)
    }
}

/// `.btn` with `.pri` and `.sm`: 22 / 20 pt high, 12.5 / 11.5 pt medium, radius 6; primary is `--v-accent` with
/// `--v-on-accent` text, plain is `--v-ctl` with the control shadow.
struct VitrineButtonStyle: ButtonStyle {
    var primary = false
    var small = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.v(small ? "sub" : "callout", .medium))
            .labelStyle(VitrineButtonLabelStyle())
            .lineLimit(1)
            .padding(.horizontal, small ? 8 : 10)
            .frame(height: Metric.value(small ? "h-ctl-sm" : "h-ctl"))
            .foregroundStyle(primary ? Color.token("on-accent") : Color.token("t1"))
            .background {
                RoundedRectangle(cornerRadius: Metric.value("r-ctl"), style: .continuous)
                    .fill(primary ? Color.token("accent") : Color.token("ctl"))
                    .shadow(color: primary ? .clear : .black.opacity(0.06), radius: 0.75, y: 1)
                    .overlay {
                        if !primary {
                            RoundedRectangle(cornerRadius: Metric.value("r-ctl"), style: .continuous)
                                .strokeBorder(Color.token("hair"), lineWidth: 0.5)
                        }
                    }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(Rectangle())
    }
}

/// Icon 13 pt then title, 5 pt apart (`.btn .ic`).
struct VitrineButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 11, weight: .medium))
            configuration.title
        }
    }
}

extension ButtonStyle where Self == VitrineButtonStyle {
    static var vitrine: VitrineButtonStyle { VitrineButtonStyle() }
    static var vitrineSmall: VitrineButtonStyle { VitrineButtonStyle(small: true) }
    static var vitrinePrimarySmall: VitrineButtonStyle { VitrineButtonStyle(primary: true, small: true) }
    static var vitrinePrimary: VitrineButtonStyle { VitrineButtonStyle(primary: true) }
}

/// `.dot` (7 pt, `.lg` 8 pt) in a token colour.
struct Dot: View {
    var token: String
    var opacity: Double = 1
    var large = true
    var body: some View {
        Circle().fill(Color.token(token).opacity(opacity)).frame(width: large ? 8 : 7, height: large ? 8 : 7)
    }
}

/// `.licon`: a 24 pt tile in a kind colour with a white 14 pt symbol.
struct KindTile: View {
    var token: String
    var symbol: String
    var body: some View {
        RoundedRectangle(cornerRadius: Metric.value("r-ctl"), style: .continuous)
            .fill(Color.token(token))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.value("r-ctl"), style: .continuous).strokeBorder(Color.token("hair"), lineWidth: 0.5)
            }
            .overlay {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.token("on-accent"))
            }
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
    }
}

/// `.gh`: a group heading in 11.5 pt semibold `--v-t2`, with an optional dot and right-hand part.
struct GroupHeading<Trailing: View>: View {
    /// A literal heading, extracted for translation (S-12).
    var title: LocalizedStringKey
    var dot: Dot?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            if let dot { dot }
            Text(title).font(.v("sub", .semibold)).foregroundStyle(Color.token("t2"))
            Spacer(minLength: 8)
            trailing().font(.v("sub")).foregroundStyle(Color.token("t2"))
        }
        .padding(.horizontal, 2)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .accessibilityAddTraits(.isHeader)
    }
}

extension GroupHeading where Trailing == EmptyView {
    init(title: LocalizedStringKey, dot: Dot? = nil) { self.init(title: title, dot: dot, trailing: { EmptyView() }) }
}

/// `.grp`: the card that holds rows (`--v-card`, radius 10, hairline edge).
struct RowGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0, content: content)
            .background(Color.token("card"), in: RoundedRectangle(cornerRadius: Metric.value("r-card"), style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.value("r-card"), style: .continuous).strokeBorder(Color.token("hair"), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: Metric.value("r-card"), style: .continuous))
    }
}

/// `.grow`: one row, 36 pt minimum, 7 / 12 pt padding; `.prob` tints it `--v-needs-soft`, `.sel` `--v-sel`.
struct PaneRow<Leading: View, Controls: View>: View {
    var title: String
    var subtitle: String
    var subtitleToken = "t2"
    /// Lines the subtitle may use; paths get two so that copies in similar folders stay apart.
    var subtitleLines = 1
    var problem = false
    var selected = false
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        HStack(spacing: 10) {
            leading()
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.v("body", .medium)).foregroundStyle(Color.token("t1")).lineLimit(1)
                Text(subtitle).font(.v("sub")).foregroundStyle(Color.token(subtitleToken)).lineLimit(subtitleLines).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: subtitleLines > 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8, content: controls).fixedSize()
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
        .frame(minHeight: Metric.value("h-row-set"))
        .background(selected ? Color.token("sel") : problem ? Color.token("needs-soft") : .clear)
        .accessibilityElement(children: .combine)
    }
}

/// `.card`: `--v-card`, radius 12, hairline edge, 14 / 16 pt padding.
struct Card<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding(.vertical, 14).padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.token("card"), in: RoundedRectangle(cornerRadius: Metric.value("r-panel"), style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.value("r-panel"), style: .continuous).strokeBorder(Color.token("hair"), lineWidth: 0.5)
            }
    }
}

/// The coverage bar: 14 pt, radius 7, 2 pt gaps. Vitrine `--v-series-1`, other apps `--v-needs`, macOS
/// `--v-kind-other` at .55, and not asked in the `.x` stripes.
struct CoverageBar: View {
    /// `label` is what VoiceOver reads for the segment ("Vitrine 12"), already localized.
    struct Segment: Identifiable { let id: String; let label: String; let count: Int; let style: Style }
    enum Style { case vitrine, other, macOS, unknown }
    var segments: [Segment]

    var body: some View {
        GeometryReader { geo in
            let shown = segments.filter { $0.count > 0 }
            let total = max(1, shown.reduce(0) { $0 + $1.count })
            let gaps = CGFloat(max(0, shown.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(shown) { s in
                    fill(s.style).frame(width: max(0, (geo.size.width - gaps) * CGFloat(s.count) / CGFloat(total)))
                }
            }
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(segments.filter { $0.count > 0 }.map(\.label).formatted(.list(type: .and, width: .narrow)))
    }

    @ViewBuilder private func fill(_ style: Style) -> some View {
        switch style {
        case .vitrine: Rectangle().fill(Color.token("series-1"))
        case .other: Rectangle().fill(Color.token("needs"))
        case .macOS: Rectangle().fill(Color.token("kind-other").opacity(0.55))
        case .unknown: Stripes().fill(Color.token("fill2"))
        }
    }
}

/// `repeating-linear-gradient(135deg, fill2 0 4px, transparent 4px 8px)`.
struct Stripes: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Layout can measure a shape with an unbounded proposal; draw nothing rather than loop forever.
        guard rect.width.isFinite, rect.height.isFinite, rect.width < 100_000, rect.height < 100_000 else { return p }
        // At 135° a 4 px band repeating every 8 px measures 4√2 and 8√2 along a horizontal line.
        let period = 8 * 2.squareRoot(), band = 4 * 2.squareRoot(), h = rect.height
        var x = rect.minX - h
        while x < rect.maxX + h {
            p.move(to: CGPoint(x: x, y: rect.maxY)); p.addLine(to: CGPoint(x: x + h, y: rect.minY))
            p.addLine(to: CGPoint(x: x + h + band, y: rect.minY)); p.addLine(to: CGPoint(x: x + band, y: rect.maxY)); p.closeSubpath()
            x += period
        }
        return p
    }
}

/// `.legend`: 9 pt swatches, radius 3, 11.5 pt `--v-t2`, 16 pt apart.
struct LegendItem: View {
    var label: String
    var style: CoverageBar.Style
    var body: some View {
        HStack(spacing: 6) {
            Group {
                switch style {
                case .vitrine: RoundedRectangle(cornerRadius: 3).fill(Color.token("series-1"))
                case .other: RoundedRectangle(cornerRadius: 3).fill(Color.token("needs"))
                case .macOS: RoundedRectangle(cornerRadius: 3).fill(Color.token("kind-other").opacity(0.55))
                case .unknown: Stripes().fill(Color.token("fill2")).clipShape(RoundedRectangle(cornerRadius: 3))
                        .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(Color.token("fill2"), lineWidth: 0.5) }
                }
            }
            .frame(width: 9, height: 9)
            Text(label).font(.v("sub")).foregroundStyle(Color.token("t2"))
        }
    }
}

/// `.toast`: `--v-pop` on the menu material, radius 12, the pop shadow; a check and an optional Undo.
struct ToastView: View {
    let toast: DiagnosticsStore.Toast
    var undo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.ok ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(Color.token(toast.ok ? "ok-text" : "needs-text"))
            Text(toast.message).font(.v("callout")).foregroundStyle(Color.token("t1")).lineLimit(2)
            if toast.undo != nil {
                Button(action: undo) {
                    HStack(spacing: 5) {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                        Text(verbatim: "⌘Z").font(.v("caption")).foregroundStyle(Color.token("t2"))
                    }
                }
                .buttonStyle(.vitrineSmall)
                .keyboardShortcut("z", modifiers: .command)
            }
        }
        .padding(.vertical, 8).padding(.leading, 14).padding(.trailing, toast.undo == nil ? 14 : 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metric.value("r-panel"), style: .continuous))
        .background(Color.token("pop"), in: RoundedRectangle(cornerRadius: Metric.value("r-panel"), style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Metric.value("r-panel"), style: .continuous).strokeBorder(Color.token("hair"), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.2), radius: 17, y: 12)
        .accessibilityElement(children: .contain)
    }
}
