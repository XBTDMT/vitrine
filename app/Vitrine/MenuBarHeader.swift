import SwiftUI
import VitrineUI

/// The custom-view parts of the menu (design: menubar.html r3-a): the state sentence with its dot, the needs-you
/// banners with their fix, and the empty-recents note. Native rows (recents, commands) are plain NSMenuItems; these
/// are views because a menu item cannot wrap text or hold a button. roadmap: S-10 (H-2)
struct MenuBarHeader: View {
    var state: MenuBarState
    var onFix: (MenuBarState.Fix) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 9) {
                Circle().fill(dotColor).frame(width: 8, height: 8).padding(.top, 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.headline).font(.system(size: Metric.value("fs-body"), weight: .semibold))
                    Text(state.subline).font(.system(size: Metric.value("fs-sub")))
                        .foregroundStyle(Color.token("t2")).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            ForEach(Array(state.problems.enumerated()), id: \.offset) { _, problem in
                MenuBarBanner(problem: problem) { onFix(problem.fix) }
                    .padding(.top, 2).padding(.bottom, 5)
            }
        }
        .foregroundStyle(Color.token("t1"))
        .padding(.horizontal, 5)
        .frame(width: MenuBarMetrics.width, alignment: .leading)
    }

    private var dotColor: Color {
        switch state.dot {
        case .ok: Color.token("ok")
        case .needs: Color.token("needs")
        case .unknown: Color.token("fill2")
        }
    }
}

/// `.banner.needs.inset`: needs-soft ground, a hairline inside, radius r-card; the fix is the primary small button.
struct MenuBarBanner: View {
    var problem: MenuBarState.Problem
    var action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13)).foregroundStyle(Color.token("needs")).padding(.top, 1)
            VStack(alignment: .leading, spacing: 0) {
                Text(problem.title).font(.system(size: Metric.value("fs-callout"), weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(problem.detail).font(.system(size: Metric.value("fs-control")))
                    .foregroundStyle(Color.token("t2")).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1).padding(.bottom, 7)
                Button(problem.fixTitle, action: action)
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 9)
        .background(RoundedRectangle(cornerRadius: Metric.value("r-card")).fill(Color.token("needs-soft")))
        .overlay(RoundedRectangle(cornerRadius: Metric.value("r-card")).strokeBorder(Color.token("sep"), lineWidth: 0.5))
    }
}

/// The first-run note under "Recent Previews", in t2 at the sub size, wrapped to the menu's width.
struct MenuBarNote: View {
    var text: String

    var body: some View {
        Text(text).font(.system(size: Metric.value("fs-sub"))).foregroundStyle(Color.token("t2"))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 8)
            .frame(width: MenuBarMetrics.width, alignment: .leading)
    }
}

enum MenuBarMetrics {
    /// `--v-w-menu`: the menu is 340 pt wide (design note "width 340 kept").
    static var width: CGFloat { Metric.value("w-menu") }
    /// Row thumbnails are 32 × 24 with radius 6 (design `.th`).
    static let thumbnail = CGSize(width: 32, height: 24)
}
