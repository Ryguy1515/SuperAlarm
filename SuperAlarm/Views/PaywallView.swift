import SwiftUI

/// The membership screen.
///
/// This build is not attached to a store account, so nothing here charges
/// anything and every feature is already available. The screen exists so the
/// tier structure is visible and so the app is complete rather than missing a
/// surface — and it always has a close button, which is the single most
/// complained-about omission in this category.
struct PaywallView: View {
    @EnvironmentObject private var store: AlarmStore
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Tier = .lifetime

    enum Tier: String, CaseIterable, Identifiable {
        case weekly, monthly, yearly, lifetime

        var id: String { rawValue }

        var title: String {
            switch self {
            case .weekly: return "Weekly"
            case .monthly: return "Monthly"
            case .yearly: return "Yearly"
            case .lifetime: return "Lifetime"
            }
        }

        var price: String {
            switch self {
            case .weekly: return "$4.99"
            case .monthly: return "$7.99"
            case .yearly: return "$29.99"
            case .lifetime: return "$34.99"
            }
        }

        var caption: String {
            switch self {
            case .weekly: return "Billed every week"
            case .monthly: return "Billed every month"
            case .yearly: return "About $2.50 a month"
            case .lifetime: return "One payment, kept forever"
            }
        }

        var badge: String? {
            switch self {
            case .yearly: return "Most popular"
            case .lifetime: return "Best value"
            default: return nil
            }
        }
    }

    var body: some View {
        ZStack {
            SABackground()

            ScrollView {
                VStack(spacing: 20) {
                    header
                    localBuildNotice
                    benefits
                    tiers
                    footer
                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, SAMetrics.screenPadding)
                .padding(.top, 6)
            }

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(SAColor.textSecondary)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(SAColor.surface))
                    }
                    .accessibilityLabel("Close")
                    Spacer()
                }
                .padding(.horizontal, SAMetrics.screenPadding)
                .padding(.top, 8)
                Spacer()
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "crown.fill")
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(SAColor.accent)
                .padding(.top, 40)

            Text("SuperAlarm Pro")
                .font(SAFont.display(32))
                .foregroundStyle(SAColor.textPrimary)

            Text("Every mission, every sound, no ads.")
                .font(SAFont.body(16))
                .foregroundStyle(SAColor.textSecondary)
        }
    }

    private var localBuildNotice: some View {
        SACard(background: SAColor.success.opacity(0.15)) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(SAColor.success)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Everything is already unlocked")
                        .font(SAFont.emphasis(16))
                        .foregroundStyle(SAColor.textPrimary)
                    Text("This is a locally built copy, so it is not connected to the App Store. Nothing on this screen charges anything — the tiers are shown for completeness.")
                        .font(SAFont.body(13))
                        .foregroundStyle(SAColor.textSecondary)
                }
            }
        }
    }

    private var benefits: some View {
        VStack(spacing: 10) {
            benefit("square.grid.2x2.fill", "All \(MissionType.selectable.count) missions", "Face ID and Math are free; the rest are Pro.")
            benefit("speaker.wave.3.fill", "\(SoundCatalog.all.count) alarm sounds", "Plus your own imported audio and randomised tones.")
            benefit("eye.fill", "Wake-up check", "The feature that stops you turning it off and rolling over.")
            benefit("chart.bar.fill", "Streaks and history", "See how hard you actually fought your alarm.")
            benefit("rectangle.on.rectangle.slash", "No ads", "Nothing to swipe past at six in the morning.")
        }
    }

    private func benefit(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(SAColor.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SAFont.emphasis(15))
                    .foregroundStyle(SAColor.textPrimary)
                Text(detail)
                    .font(SAFont.body(12))
                    .foregroundStyle(SAColor.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SAColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var tiers: some View {
        VStack(spacing: 10) {
            ForEach(Tier.allCases) { tier in
                Button {
                    HapticEngine.shared.selection()
                    selected = tier
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: selected == tier ? "circle.inset.filled" : "circle")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(selected == tier ? SAColor.accent : SAColor.textTertiary)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(tier.title)
                                    .font(SAFont.emphasis(17))
                                    .foregroundStyle(SAColor.textPrimary)
                                if let badge = tier.badge {
                                    Text(badge)
                                        .font(SAFont.caption(10))
                                        .foregroundStyle(SAColor.onAccent)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(SAColor.accent))
                                }
                            }
                            Text(tier.caption)
                                .font(SAFont.body(12))
                                .foregroundStyle(SAColor.textSecondary)
                        }

                        Spacer()

                        Text(tier.price)
                            .font(SAFont.headline(18))
                            .foregroundStyle(SAColor.textPrimary)
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(SAColor.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(selected == tier ? SAColor.accent : Color.clear, lineWidth: 2)
                            )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selected == tier ? [.isSelected] : [])
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button("Continue with everything unlocked") {
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())

            Text("No payment is taken. There is no store account attached to this build.")
                .font(SAFont.caption(11))
                .foregroundStyle(SAColor.textTertiary)
                .multilineTextAlignment(.center)
        }
    }
}
