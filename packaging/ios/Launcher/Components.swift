import SwiftUI
import UIKit

/// A labelled text field in the launcher's look.
struct Field: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var secure = false
    var keyboard: UIKeyboardType = .URL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.mono(9)).foregroundStyle(Theme.textMuted)
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                        .keyboardType(keyboard)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(Theme.sans(14))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        }
    }
}

/// The accent button, with the design's lit top edge, as Play has.
struct PrimaryButton: View {
    let title: String
    var icon: String?
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 14, weight: .bold))
                }
                Text(title).font(Theme.pixel(18))
            }
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(enabled ? Theme.accent : Theme.surfaceDisabled)
            .overlay(alignment: .top) { (enabled ? Theme.accentEdge : Color.clear).frame(height: 1) }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(PressStyle())
    }
}

struct SecondaryButton: View {
    let title: String
    var icon: String?
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                }
                Text(title).font(Theme.sans(14, .semiBold))
            }
            .foregroundStyle(Theme.accentText)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        }
        .buttonStyle(PressStyle())
    }
}

/// Buttons sink a little under a finger, as the game's do when pressed.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A section's heading, in the pixel face, with an optional action at its end.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            Text(title).font(Theme.pixel(20)).foregroundStyle(Theme.text)
            Spacer()
            trailing()
        }
        .padding(.top, 8)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// A page's own heading under the header bar.
struct PageTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.pixel(30)).foregroundStyle(Theme.text)
            if let subtitle {
                Text(subtitle).font(Theme.sans(12)).foregroundStyle(Theme.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An empty list's word, in a sunken box.
struct EmptyNote: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(Theme.textFaint)
            Text(text).font(Theme.sans(13)).foregroundStyle(Theme.textMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }
}

extension View {
    /// The launcher's card: a raised surface with a hairline border.
    func card(radius: CGFloat = 12) -> some View {
        background(Theme.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.border))
    }

    /// A page's width and margins, as the home screen has them.
    func pageColumn(maxWidth: CGFloat = 520) -> some View {
        padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - The splash

/// The title screen's splash text: one line of `splashes.txt` from the player's own game files, yellow,
/// tilted 20 degrees and pulsing once a second, as `Title::draw` draws it (and its special dates).
struct Splash: View {
    let text: String

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = 1.8 - abs(sin(t * 2 * .pi)) * 0.1
            Text(text)
                .font(Theme.pixel(11, .medium))
                .foregroundStyle(Theme.splash)
                .shadow(color: Theme.splashShadow, radius: 0, x: 1, y: 1)
                .fixedSize()
                .scaleEffect(pulse / 1.8)
                .rotationEffect(.degrees(-20))
        }
        .accessibilityLabel(text)
    }

    /// A splash for today: the game's special dates first, then a random line of the game files' list (the
    /// hidden one left out, as `choose_splash` does); nil without game files.
    static func pick(now: Date = Date()) -> String? {
        let day = Calendar.current.dateComponents([.month, .day], from: now)
        switch (day.month ?? 0, day.day ?? 0) {
        case (12, 24): return "Merry X-mas!"
        case (1, 1): return "Happy new year!"
        case (10, 31): return "OOoooOOOoooo! Spooky!"
        default: break
        }
        let file = GameFolder.resources.appendingPathComponent("assets/minecraft/texts/splashes.txt")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && javaHash($0) != 125_780_783 }
        return lines.randomElement()
    }

    /// `String.hashCode`, for the one splash vanilla never shows.
    private static func javaHash(_ text: String) -> Int32 {
        text.utf16.reduce(Int32(0)) { $0 &* 31 &+ Int32($1) }
    }
}
