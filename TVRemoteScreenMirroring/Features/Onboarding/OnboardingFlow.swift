import SwiftUI

/// First run: three short intro pages, then connecting a TV and the free compatibility check.
struct OnboardingFlow: View {
    @Environment(AppModel.self) private var model
    @State private var path: [Step] = []

    enum Step: Hashable { case discovery, compatibility }

    var body: some View {
        NavigationStack(path: $path) {
            IntroPager(mode: .firstRun) {
                model.analytics.log(.onboardingStarted)
                path.append(.discovery)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .discovery:
                    DiscoveryView(isOnboarding: true) { if path.last != .compatibility { path.append(.compatibility) } }
                case .compatibility:
                    CompatibilityView { finish() }
                }
            }
        }
    }

    private func finish() {
        let deviceID = model.connection.state.deviceID
        model.settings.onboardingCompleted = true
        model.selectedTab = .remote
        model.analytics.log(.onboardingCompleted(task: "remote"))
        // Plans are offered once after the first check; dismissible and never blocking.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            model.paywall.offerAfterCompatibilityCheck(deviceID: deviceID)
        }
    }
}

// MARK: - Intro pager

/// Three intro pages (design 01–03): kit illustration, centered title and text, page dots,
/// Continue / Connect my TV and a short honest note under the button.
struct IntroPager: View {
    enum Mode { case firstRun, replay }

    let mode: Mode
    var onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0

    static let pageCount = 3

    var body: some View {
        GeometryReader { proxy in
            let layout = IntroLayout(size: proxy.size, largeText: dynamicTypeSize.isAccessibilitySize)
            TabView(selection: $page) {
                ForEach(0..<Self.pageCount, id: \.self) { index in
                    IntroPage(index: index, layout: layout)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .safeAreaInset(edge: .top, spacing: 0) { topBar }
            .safeAreaInset(edge: .bottom, spacing: 0) { controls }
        }
        .background(Color.appBackground.ignoresSafeArea())
    }

    private var isLastPage: Bool { page == Self.pageCount - 1 }

    private var topBar: some View {
        HStack {
            Spacer()
            if !isLastPage || mode == .replay {
                Button(mode == .replay ? L10n.tr("common.close") : L10n.tr("v2.action.skip")) {
                    if mode == .replay { dismiss() } else { onFinish() }
                }
                .font(.appBodyEmphasis)
                .foregroundStyle(Color.appAccent)
                .frame(minWidth: HitTarget.minimum, minHeight: HitTarget.minimum)
                .accessibilityIdentifier("onboarding.skip")
            }
        }
        .padding(.horizontal, Spacing.screen)
        .frame(height: HitTarget.minimum)
    }

    private var controls: some View {
        VStack(spacing: Spacing.m) {
            PageIndicator(count: Self.pageCount, current: page)
            Button {
                if isLastPage {
                    if mode == .replay { dismiss() } else { onFinish() }
                } else {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { page += 1 }
                }
            } label: {
                if isLastPage && mode == .firstRun {
                    HStack(spacing: Spacing.xs) {
                        Text(L10n.tr("v2.onboarding.cast.cta"))
                        AppIconView("icon-chevron-right", size: 18, relativeTo: .headline)
                    }
                } else {
                    Text(primaryTitle)
                }
            }
            .buttonStyle(.primary)
            .accessibilityIdentifier(isLastPage ? "onboarding.connect" : "onboarding.next")
            if mode == .firstRun {
                // Same height on every page so the button doesn't jump while paging.
                Text(note ?? L10n.tr("v2.onboarding.remote.note"))
                    .font(.appFootnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(note == nil ? 0 : 1)
                    .accessibilityHidden(note == nil)
            }
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.top, Spacing.s)
        .padding(.bottom, Spacing.s)
        .background(Color.appBackground.ignoresSafeArea(edges: .bottom))
    }

    private var note: String? {
        switch page {
        case 0: L10n.tr("v2.onboarding.remote.note")
        case Self.pageCount - 1: L10n.tr("v2.onboarding.cast.note")
        default: nil
        }
    }

    private var primaryTitle: String {
        guard isLastPage else { return L10n.tr("v2.action.continue") }
        return mode == .replay ? L10n.tr("common.done") : L10n.tr("v2.onboarding.cast.cta")
    }
}

/// Illustration height for a given screen: smaller on short screens and huge text (the art
/// shrinks first; the text never does).
struct IntroLayout: Equatable {
    let size: CGSize
    let largeText: Bool

    /// Share of the height given to the illustration.
    var illustrationHeight: CGFloat {
        let share: CGFloat = largeText ? 0.26 : (isShort ? 0.4 : 0.5)
        return (size.height * share).rounded()
    }

    /// iPhone SE-class height (usable area ≈ 647 pt).
    var isShort: Bool { size.height < 700 }
}

private struct IntroPage: View {
    let index: Int
    let layout: IntroLayout

    private var art: ArtAsset {
        switch index {
        case 0: .onboardingRemote
        case 1: .onboardingApps
        default: .onboardingCast
        }
    }

    private var keys: (title: String, body: String) {
        switch index {
        case 0: ("v2.onboarding.remote.title", "v2.onboarding.remote.body")
        case 1: ("v2.onboarding.apps.title", "v2.onboarding.apps.body")
        default: ("v2.onboarding.cast.title", "v2.onboarding.cast.body")
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.m) {
                OnboardingArt(art: art)
                    .frame(maxHeight: layout.illustrationHeight)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Spacing.s)
                VStack(spacing: Spacing.s) {
                    Text(L10n.tr(keys.title))
                        .font(.appHeroTitle)
                        .foregroundStyle(Color.appTextPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(L10n.tr(keys.body))
                        .font(.appBody)
                        .foregroundStyle(Color.appTextSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Spacing.screen)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, Spacing.m)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// Left-aligned wrapping row.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

private struct PageIndicator: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.appAccent : Color.appTextSecondary.opacity(0.35))
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("onboarding.step", current + 1, count))
    }
}

// MARK: - Replay from Help

struct IntroReplayView: View {
    var body: some View {
        IntroPager(mode: .replay) {}
    }
}
