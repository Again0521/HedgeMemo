import SwiftUI

/// Shared motion and feedback rules for non-material controls.  Material,
/// window chrome and layout remain owned by their existing hosts; this file
/// only makes interaction feel immediate, interruptible and accessibility-safe.
enum AppleInteractionMotion {
    static func settle(
        reduceMotion: Bool,
        response: Double = 0.32,
        dampingFraction: Double = 1
    ) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .interactiveSpring(
                response: response,
                dampingFraction: dampingFraction,
                blendDuration: 0.08
            )
    }

    /// A release after direct manipulation may carry a restrained amount of
    /// overshoot. Programmatic state changes use `settle` instead.
    static func momentum(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .interactiveSpring(response: 0.3, dampingFraction: 0.82, blendDuration: 0.1)
    }

    static func dismissal(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : settle(reduceMotion: false, response: 0.24)
    }
}

/// Press feedback starts on mouse-down and animates from the current
/// presentation value. It intentionally draws no fill, border or material, so
/// existing visual styling and native control hierarchy are preserved.
struct ApplePressButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.96
    var pressedOpacity: Double = 0.78

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : pressedScale)
            .opacity(
                isEnabled
                    ? (configuration.isPressed ? pressedOpacity : 1)
                    : 0.45
            )
            .animation(
                AppleInteractionMotion.settle(
                    reduceMotion: reduceMotion,
                    response: 0.18,
                    dampingFraction: 1
                ),
                value: configuration.isPressed
            )
    }
}

/// Direct-manipulation feedback for gesture-owned components that cannot be a
/// Button (for example, a reorderable grid tile).
private struct AppleDirectManipulationFeedback: ViewModifier {
    let isPressed: Bool
    let scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion || !isPressed ? 1 : scale)
            .opacity(isPressed ? 0.9 : 1)
            .animation(
                AppleInteractionMotion.settle(
                    reduceMotion: reduceMotion,
                    response: 0.18,
                    dampingFraction: 1
                ),
                value: isPressed
            )
    }
}

extension View {
    func appleDirectManipulationFeedback(
        isPressed: Bool,
        scale: CGFloat = 0.98
    ) -> some View {
        modifier(AppleDirectManipulationFeedback(isPressed: isPressed, scale: scale))
    }
}
