import SwiftUI

struct ReactionTray: View {
    static let emojis = ["👍", "❤️", "😂", "😮", "😢", "🔥"]

    let reactions: ReactionsSummary
    let onReact: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.emojis, id: \.self) { emoji in
                    let count = reactions.counts?[emoji] ?? 0
                    let active = reactions.myReaction == emoji
                    Button {
                        onReact(emoji)
                    } label: {
                        Text(count > 0 ? "\(emoji) \(count)" : emoji)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(active ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
