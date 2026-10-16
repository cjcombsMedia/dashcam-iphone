import SwiftUI

/// Lets one button switch between button styles at runtime.
///
/// SwiftUI's `.buttonStyle` takes a concrete type, so a button can't choose
/// between `.bordered` and `.borderedProminent` from a condition without a
/// type-erasing wrapper. The verdict buttons need exactly that: the chosen
/// verdict is filled, the other two stay outlined.
struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let makeBody: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        makeBody = { configuration in
            AnyView(Button(configuration).buttonStyle(style))
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        makeBody(configuration)
    }
}
