import SwiftUI

extension View {
    /// The rounded fill that groups a module, like a Control Center tile.
    ///
    /// The system fill rather than glass: the popover is already glass, and
    /// glass cannot sample glass. The fill adapts to Reduce Transparency and
    /// Increase Contrast on its own.
    func tile(padding: CGFloat = 12) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
    }
}

/// An SF Symbol on a translucent wash of its own colour: the tinted-glass
/// look for the tile icons. A neutral wash when off.
struct TintedSymbol: View {
    let name: String
    let colour: Color
    var isOn = true
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: name)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(isOn ? colour : .primary)
            .frame(width: size, height: size)
            .background(isOn ? colour.opacity(0.22) : Color.primary.opacity(0.1), in: .circle)
    }
}

/// Pulls a dragged value onto `centre` when it comes within `within`, so the
/// neutral point is easy to hit. The haptic tap is added where it is used,
/// with `.sensoryFeedback`.
func snapping(_ value: Binding<Double>, to centre: Double, within: Double) -> Binding<Double> {
    Binding(
        get: { value.wrappedValue },
        set: { new in value.wrappedValue = abs(new - centre) < within ? centre : new }
    )
}
