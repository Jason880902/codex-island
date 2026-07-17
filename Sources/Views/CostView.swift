import SwiftUI

/// Cost data row. Mirrors `UsageView`'s data-row shape so swipe transitions
/// between them don't reflow the panel. Chrome (provider titles, footer
/// chip + page dots + sync status) lives in `PanelHeader` / `PanelFooter`.
///
/// Branches on the slot pair from `ProviderVisibilityStore`:
///   - both slots filled: two `CostBlock`s with a hairline divider (default).
///   - one slot filled:   the live block on its native side (centered tiles,
///               since its half doubled), hairline, then a per-model dollar
///               breakdown filling the freed half.
///   - both slots empty: a centered `BothHiddenPlaceholder`.
struct CostView: View {
    @ObservedObject private var store = CostStore.shared
    @ObservedObject private var visibility = ProviderVisibilityStore.shared
    @ObservedObject private var stylePref = CostStylePref.shared

    var body: some View {
        let left = visibility.leftProvider
        let right = visibility.rightProvider

        HStack(spacing: 0) {
            switch (left, right) {
            case let (left?, right?):
                costBlock(for: left, centerWhenSingle: false)
                hairline
                costBlock(for: right, centerWhenSingle: false)
            case let (left?, nil):
                costBlock(for: left, centerWhenSingle: true)
                hairline
                breakdown(for: left)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.horizontal, 12)
                    .transition(breakdownTransition)
            case let (nil, right?):
                breakdown(for: right)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.horizontal, 12)
                    .transition(breakdownTransition)
                hairline
                costBlock(for: right, centerWhenSingle: true)
            case (nil, nil):
                BothHiddenPlaceholder()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    /// One provider's Today + month pair. Color, cost, and loading all
    /// resolve through the provider, so the two slots are interchangeable.
    private func costBlock(
        for provider: AlertEngine.Provider,
        centerWhenSingle: Bool
    ) -> some View {
        CostBlock(color: provider.brandColor, cost: store.cost(for: provider),
                  loading: store.isLoading(provider), provider: provider,
                  centerWhenSingle: centerWhenSingle)
    }

    /// Cost-page breakdown swaps metric to follow the visible tile: when
    /// the user has cycled to TOKENS (`stylePref.style == .tokens`), show
    /// per-model token volume; otherwise show per-model dollars. Both
    /// branches return the SAME view type and same row layout, so the
    /// metric swap re-uses the existing identity-based crossfade
    /// SwiftUI gives us inside `withAnimation` blocks (no explicit
    /// `.transition` needed here — only the (both-on)→(single) swap
    /// uses `breakdownTransition` to morph between completely different
    /// view trees).
    private func breakdown(for provider: AlertEngine.Provider) -> some View {
        let metric: PerModelBreakdown.Metric =
            stylePref.style == .tokens ? .tokens : .dollars
        return PerModelBreakdown(provider: provider, metric: metric)
            .id(metric)
            .transition(.chartSwap.animation(.chartSwap))
    }

    /// Mirror of `UsageView.breakdownTransition` — kept inline (not extracted
    /// to a shared helper) because it's two views and the transition's
    /// emotional purpose is "this half has been repurposed for the
    /// breakdown", which is a per-page editorial choice.
    private var breakdownTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.97))
    }

    private var hairline: some View {
        Rectangle()
            .fill(LinearGradient(
                colors: [.clear, .white.opacity(0.06), .clear],
                startPoint: .top, endPoint: .bottom
            ))
            .frame(width: 1)
            .padding(.vertical, 8)
    }
}
