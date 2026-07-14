import SwiftUI

struct MessageBubble: View {
    let body_: String
    let senderLabel: String?
    let isMine: Bool
    var createdAt: String? = nil

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
            HStack {
                if isMine { Spacer(minLength: 40) }
                VStack(alignment: .leading, spacing: 2) {
                    if let senderLabel, !isMine {
                        Text(senderLabel).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(body_)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isMine ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.15))
                .foregroundStyle(isMine ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                if !isMine { Spacer(minLength: 40) }
            }
            if let createdAt, !createdAt.isEmpty {
                Text(DateFormatting.chatTimestamp(createdAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, isMine ? 0 : 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
    }
}

struct MessageComposer: View {
    @Binding var text: String
    var isSending: Bool
    var onSend: () -> Void

    var body: some View {
        HStack {
            TextField("Message", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            Button {
                onSend()
            } label: {
                if isSending {
                    ProgressView()
                } else {
                    Image(systemName: "paperplane.fill")
                }
            }
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || isSending)
            .accessibilityLabel("Send message")
        }
        .padding()
    }
}
