import SwiftUI

enum Theme {
    // Colors
    static let primaryColor = Color("AccentColor")
    static let userBubbleColor = Color.blue
    static let assistantBubbleColor = Color.secondary.opacity(0.15)
    static let commandBubbleColor = Color.secondary.opacity(0.1)
    static let systemMessageColor = Color.secondary.opacity(0.3)
    static let destructiveColor = Color.red
    static let safeColor = Color.green

    // Fonts
    static let messageFont = Font.body
    static let commandFont = Font.system(.callout, design: .monospaced)
    static let captionFont = Font.caption
    static let titleFont = Font.headline

    // Spacing
    static let bubblePadding: CGFloat = 12
    static let bubbleCornerRadius: CGFloat = 16
    static let messageSpacing: CGFloat = 8
    static let screenPadding: CGFloat = 16
}
