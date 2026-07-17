import SwiftUI

/// Provider titles row — the left slot's provider on the left, the right
/// slot's on the right, with a notch-width spacer in the middle that hides
/// the title content behind the physical notch. Lives outside `PagedContent`
/// so it stays fixed while the data area swipes between usage/cost/overview
/// screens. A cleared slot renders an empty half so the spacer and the
/// surviving title never reflow.
///
/// Plan tags ("INTERMEDIATE" / "PLUS") are sourced from `UsageStore` since
/// the subscription tier is a property of the account, not the current page.
struct PanelHeader: View {
    let notch: NotchInfo
    @ObservedObject private var slots = ProviderVisibilityStore.shared
    @ObservedObject private var usageStore = UsageStore.shared

    var body: some View {
        HStack(spacing: 0) {
            slotTitle(.left, alignment: .leading)
            Color.clear.frame(width: notch.width)
            slotTitle(.right, alignment: .trailing)
        }
        .frame(height: 22)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, min(14, max(0, notch.height - 22 - 4)))
    }

    /// One half of the header. A provider assigned to a slot is always
    /// shown — "hidden" no longer exists at this level, only empty slots.
    @ViewBuilder
    private func slotTitle(
        _ slot: ProviderVisibilityStore.Slot,
        alignment: HorizontalAlignment
    ) -> some View {
        if let provider = slots.provider(in: slot) {
            providerTitle(name: provider.displayName,
                          tag: usageStore.usage[provider]?.plan?.uppercased(),
                          color: provider.brandColor, alignment: alignment) {
                // Codex-only rate-limit reset credits, pinned to the Codex
                // title so the badge unambiguously belongs to Codex — its old
                // footer-center spot read as panel-global. Account-level like
                // the plan tag, so it rides along on every screen. Follows
                // Codex to whichever slot it occupies.
                if provider == .codex {
                    CodexResetStatus()
                } else {
                    EmptyView()
                }
            }
        } else {
            Color.clear.frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func providerTitle<Accessory: View>(
        name: String,
        tag: String?,
        color: Color,
        alignment: HorizontalAlignment,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        // Push past where the overlay logo lands: 9 leading + 20 logo + 8 gap.
        let logoOffset: CGFloat = 9 + 20 + 8

        let content = HStack(spacing: 8) {
            Text(name)
                .font(Typography.providerTitle)
                .foregroundStyle(.white)
            if let tag {
                Text(tag)
                    .font(Typography.chip)
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.white.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                            )
                    )
            }
        }

        if alignment == .leading {
            // Mirror of the trailing branch: accessory sits between the
            // title and the center spacer, adjacent to its provider.
            HStack(spacing: 10) {
                content.padding(.leading, logoOffset)
                accessory()
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                accessory()
                content.padding(.trailing, logoOffset)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
