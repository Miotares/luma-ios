import SwiftUI

/// "Cover-Ecken" setting: rounded (default) or square covers. Some covers carry a frame or border
/// right at their edge, which rounded corners cut off.
enum CoverCorners {
    static let squareKey = "coverCornersSquare"
}

extension EnvironmentValues {
    /// Factor for every cover corner radius: 1 = rounded as designed, 0 = square. Views that draw
    /// their own shape around a cover (border, dimming overlay, shadow base) multiply by it, so
    /// the shape matches the cover inside. Round artist pictures are not covers and stay round.
    @Entry var coverCornerScale: CGFloat = 1
}

extension View {
    /// Feeds the setting to every cover below this view. Applied once per window root.
    func lumaCoverCornerSetting() -> some View { modifier(CoverCornerSetting()) }
}

private struct CoverCornerSetting: ViewModifier {
    @AppStorage(CoverCorners.squareKey) private var square = false

    func body(content: Content) -> some View {
        content.environment(\.coverCornerScale, square ? 0 : 1)
    }
}
