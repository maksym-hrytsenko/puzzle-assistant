import SwiftUI

enum Theme {
    static let accent = Color(red: 0.36, green: 0.33, blue: 0.95)
    static let accentGradient = LinearGradient(colors: [Color(red: 0.42, green: 0.36, blue: 0.98),
                                                        Color(red: 0.73, green: 0.32, blue: 0.93)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
    static let good = Color(red: 0.18, green: 0.78, blue: 0.45)
    static let maybe = Color(red: 1.0, green: 0.72, blue: 0.16)
    static let weak = Color(red: 1.0, green: 0.36, blue: 0.36)
    static let neutral = Color.white
    static let cornerRadius: CGFloat = 20

    /// Colour for a probability of a place.
    static func color(probability: Double) -> Color {
        probability >= 0.6 ? good : (probability >= 0.25 ? maybe : weak)
    }

    /// Distinct colours for candidate places 1, 2, 3, 4.
    static let candidateColors: [Color] = [Color(red: 0.18, green: 0.78, blue: 0.45), Color(red: 0.25, green: 0.55, blue: 1.0),
                                           Color(red: 1.0, green: 0.62, blue: 0.1), Color(red: 0.93, green: 0.3, blue: 0.75)]
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

/// Large gradient call-to-action button.
struct PrimaryButtonStyle: ButtonStyle {
    var enabled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(enabled ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.gray.opacity(0.4)),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// Big tappable tile with an icon, title and subtitle.
struct ActionTile: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    var tint: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .card()
    }
}

/// Pill-shaped label, e.g. "72 %".
struct Pill: View {
    let text: String
    var color: Color = Theme.accent

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color, in: Capsule())
    }
}

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}
