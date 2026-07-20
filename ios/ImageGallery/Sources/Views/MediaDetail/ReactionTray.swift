import SwiftUI

struct ReactionTray: View {
    static let emojis = ["👍", "❤️", "😂", "😮", "😢", "🔥"]

    let reactions: ReactionsSummary
    let onReact: (String) -> Void

    @State private var bounceEmoji: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.emojis, id: \.self) { emoji in
                    let count = reactions.counts?[emoji] ?? 0
                    let active = reactions.myReaction == emoji
                    Button {
                        bounce(emoji)
                        onReact(emoji)
                    } label: {
                        Text(count > 0 ? "\(emoji) \(count)" : emoji)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(active ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                            .scaleEffect(bounceEmoji == emoji ? 1.3 : 1.0)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // A quick spring "pop" on tap — cheap delight the web app's plain hover
    // states have no equivalent for.
    private func bounce(_ emoji: String) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.35)) {
            bounceEmoji = emoji
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                if bounceEmoji == emoji { bounceEmoji = nil }
            }
        }
    }
}
