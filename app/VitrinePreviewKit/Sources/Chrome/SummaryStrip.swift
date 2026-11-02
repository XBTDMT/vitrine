import AppKit
import CryptoKit
import SwiftUI
import VitrineDocument
import VitrineSupport
import VitrineUI

/// A-9's on-device summary (ai r3-b section 2; G-28): offered, never made unasked — "Summarize · On this Mac. Nothing
/// leaves it." — then "Summarizing on this Mac…", then a small box with the summary and "Made on this Mac · may contain
/// mistakes", cached by the text's hash. Drawn only where Apple's model is ready (asked of VitrineHelper); elsewhere
/// nothing at all, so the preview looks exactly as it does without it. roadmap: S-21 (A-9)
@MainActor
final class SummaryModel: ObservableObject {
    enum State: Equatable { case offered, working, ready(String, cached: Bool), failed(String) }
    @Published var state: State
    let text: String
    let cache: OnDeviceSummaryCache

    init(text: String, cache: OnDeviceSummaryCache) {
        self.text = text
        self.cache = cache
        state = cache.read(text).map { .ready($0, cached: true) } ?? .offered
    }

    func summarize() {
        state = .working
        Task { @MainActor in
            let result = await HelperClient.summarize(text)
            if let summary = result.summary, !summary.isEmpty {
                cache.write(summary, for: text)
                state = .ready(summary, cached: false)
            } else {
                state = .failed(result.error ?? String(localized: "No summary came back.", bundle: .previewKit,
                                                        comment: "Summary strip: the on-device model returned nothing."))
            }
        }
    }

    /// The kinds a summary is offered for: text a person reads.
    static func offers(_ kind: FileKind) -> Bool {
        switch kind {
        case .markdown, .plainText: return true
        case .code(let language): return language.hasSuffix("-session") || language == "ipynb" || language == "marimo" || language == "jsonl"
        default: return false
        }
    }

    /// Settings › Privacy › On-device summaries: whether the offer is drawn at all (on unless turned off).
    static let settingKey = "summaries.offer"
}

/// Summaries kept on this Mac, keyed by the SHA-256 of the text, in the process's caches folder.
struct OnDeviceSummaryCache: Sendable {
    let directory: URL

    static var standard: OnDeviceSummaryCache {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return OnDeviceSummaryCache(directory: base.appendingPathComponent("Summaries", isDirectory: true))
    }

    private func file(for text: String) -> URL {
        let key = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".txt")
    }

    func read(_ text: String) -> String? { try? String(contentsOf: file(for: text), encoding: .utf8) }

    func write(_ summary: String, for text: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? summary.write(to: file(for: text), atomically: true, encoding: .utf8)
    }
}

struct SummaryStripView: View {
    @ObservedObject var model: SummaryModel

    var body: some View {
        Group {
            switch model.state {
            case .offered:
                HStack(spacing: 10) {
                    Button { model.summarize() } label: {
                        Label { Text("Summarize", bundle: .previewKit, comment: "Summary strip button: asks Apple's on-device model for a short summary.") }
                            icon: { Image(systemName: "text.badge.star") }
                    }
                    .controlSize(.small)
                    Text("On this Mac. Nothing leaves it.", bundle: .previewKit, comment: "Summary strip, beside the Summarize button.")
                        .font(.system(size: Metric.value("fs-sub"))).foregroundStyle(Color.token("t2"))
                    Spacer(minLength: 0)
                }
            case .working:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Summarizing on this Mac…", bundle: .previewKit, comment: "Summary strip while the on-device model works; the preview stays usable.")
                        .font(.system(size: Metric.value("fs-sub"))).foregroundStyle(Color.token("t2"))
                    Spacer(minLength: 0)
                }
            case .ready(let summary, let cached):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Summary", bundle: .previewKit, comment: "Summary strip heading over the on-device summary.")
                        .font(.system(size: Metric.value("fs-sub"), weight: .semibold)).foregroundStyle(Color.token("t2"))
                    Text(summary).font(.system(size: Metric.value("fs-body"))).foregroundStyle(Color.token("t1"))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text(cached ? String(localized: "Made on this Mac · may contain mistakes · cached", bundle: .previewKit,
                                         comment: "Summary strip foot when the summary came from this Mac's cache.")
                                : String(localized: "Made on this Mac · may contain mistakes", bundle: .previewKit,
                                         comment: "Summary strip foot under a fresh on-device summary."))
                        .font(.system(size: Metric.value("fs-caption"))).foregroundStyle(Color.token("t3"))
                }
                .padding(10)
                .background(Color.token("fill"), in: RoundedRectangle(cornerRadius: Metric.value("r-row")))
            case .failed(let reason):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Color.token("needs-text"))
                    Text(reason).font(.system(size: Metric.value("fs-sub"))).foregroundStyle(Color.token("t2"))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(String(localized: "Try Again", bundle: .previewKit, comment: "Summary strip button after a failed summary.")) { model.summarize() }
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("On-device summary", bundle: .previewKit, comment: "Accessibility label of the summary strip."))
    }
}
