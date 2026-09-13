// VisionClaw - Theme.swift
// One place for colour, spacing and the controls that repeat across screens.
//
// Before this, every screen invented its own: .white.opacity(0.12) here, a 14pt corner there, a
// 38pt tap target somewhere else. That is what made the app read as unfinished even where the
// behaviour was right — nothing lined up with anything, and the same control looked different
// depending on which screen you found it on.
//
// Colours come from the system's semantic set rather than fixed hex values, so light and dark mode
// both work without a second palette. The accent is the violet from the app icon, so the app and
// its icon look like the same product.

import SwiftUI

extension Color {
    /// The violet from the app icon.
    static let brand = Color(red: 0.42, green: 0.22, blue: 0.72)

    /// Cards, bubbles, chips: one step up from the page.
    static let appSurface = Color(uiColor: .secondarySystemBackground)
    /// A control sitting on top of a surface, which needs to be distinguishable from it.
    static let appSurfaceRaised = Color(uiColor: .tertiarySystemBackground)
    static let appBackground = Color(uiColor: .systemBackground)
    /// The page behind grouped content, so cards have something to sit on.
    static let appGrouped = Color(uiColor: .systemGroupedBackground)
}

enum Metrics {
    /// A 4pt scale. Every gap in the app is one of these, which is most of what makes a layout look
    /// deliberate rather than assembled.
    static let tight: CGFloat = 6
    static let small: CGFloat = 10
    static let medium: CGFloat = 16
    static let large: CGFloat = 24

    /// Apple's minimum is 44pt. Controls that are used in motion — walking, in a conversation —
    /// get more than the minimum.
    static let tapTarget: CGFloat = 48
    static let radius: CGFloat = 16
    static let radiusLarge: CGFloat = 22
}

// MARK: - Reusable pieces

/// A circular icon button of a consistent size. Used for everything in the composer and for the
/// round controls on the translator.
struct IconButton: View {
    let systemName: String
    var tint: Color = .secondary
    var background: Color = .appSurface
    var size: CGFloat = Metrics.tapTarget
    var isBusy = false
    var accessibilityLabel: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(background)
                if isBusy {
                    ProgressView().controlSize(.small).tint(tint)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: size, height: size)
            .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// The full-width action at the bottom of a screen: start, stop, download.
struct PrimaryButton: View {
    let title: String
    var systemName: String?
    var tint: Color = .brand
    var isBusy = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.small) {
                if isBusy {
                    ProgressView().tint(.white)
                } else if let systemName {
                    Image(systemName: systemName).font(.headline)
                }
                Text(title).font(.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Metrics.medium)
            .background(tint.opacity(isEnabled ? 1 : 0.4),
                        in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// A settings row with an icon in a coloured tile, the way iOS's own Settings looks. The colour
/// carries as much information as the label when scanning a long list.
struct SettingsRow<Trailing: View>: View {
    let icon: String
    let tint: Color
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Metrics.small) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 29, height: 29)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Metrics.small)
            trailing
        }
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(icon: String, tint: Color, title: String, subtitle: String? = nil) {
        self.init(icon: icon, tint: tint, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A short status line: a coloured dot and a sentence. Used wherever the app has to say what it is
/// currently doing, so "listening", "paused" and "failed" all look like the same kind of statement.
struct StatusLine: View {
    enum Kind { case good, busy, warning, idle }

    let kind: Kind
    let text: String

    var body: some View {
        HStack(spacing: Metrics.tight) {
            switch kind {
            case .busy:
                ProgressView().controlSize(.mini)
            default:
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(text)
                .font(.footnote)
                .foregroundStyle(kind == .warning ? Color.orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var color: Color {
        switch kind {
        case .good: return .green
        case .warning: return .orange
        case .idle, .busy: return .secondary
        }
    }
}

/// Скорость диктора, 0.5x…2x, прямо под рукой во время разговора.
///
/// Живёт в общем файле, потому что нужен и переводчику, и гиду, и нет причин, чтобы в двух местах
/// он выглядел и вёл себя по-разному. Значение общее: выставленное в переводчике действует и в
/// эфире.
struct SpeechRateSlider: View {
    @ObservedObject private var synth = SpeechSynthesizer.shared

    var body: some View {
        HStack(spacing: Metrics.small) {
            Image(systemName: "tortoise.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Slider(value: $synth.rateMultiplier, in: 0.5...2.0, step: 0.1)
                .tint(.brand)
            Image(systemName: "hare.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(String(format: "%.1fx", synth.rateMultiplier))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Скорость речи")
        .accessibilityValue(String(format: "%.1f", synth.rateMultiplier))
    }
}
