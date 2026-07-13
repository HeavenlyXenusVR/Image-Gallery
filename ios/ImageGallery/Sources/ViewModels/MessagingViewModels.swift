import Combine
import Foundation

@MainActor
final class MessagesListViewModel: ObservableObject {
    @Published var directThreads: [MessageThread] = []
    @Published var groupThreads: [GroupThread] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let api = GalleryAPIClient.shared

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        async let directTask = api.messageThreads()
        async let groupTask = api.groupThreads()
        do {
            directThreads = try await directTask
        } catch {
            errorMessage = error.localizedDescription
        }
        groupThreads = (try? await groupTask) ?? []
    }
}

@MainActor
final class DirectMessageThreadViewModel: ObservableObject {
    @Published var messages: [DirectMessage] = []
    @Published var isLoading = false
    @Published var isSending = false
    @Published var errorMessage: String?

    let userId: Int
    private let api = GalleryAPIClient.shared

    init(userId: Int) {
        self.userId = userId
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            messages = try await api.directMessages(userId: userId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func send(_ body: String) async {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        do {
            let message = try await api.sendDirectMessage(userId: userId, body: trimmed)
            messages.append(message)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
final class GroupThreadViewModel: ObservableObject {
    @Published var messages: [ThreadMessage] = []
    @Published var isLoading = false
    @Published var isSending = false
    @Published var errorMessage: String?

    let threadId: Int
    private let api = GalleryAPIClient.shared

    init(threadId: Int) {
        self.threadId = threadId
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            messages = try await api.groupThreadMessages(threadId: threadId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func send(_ body: String) async {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        do {
            let message = try await api.sendGroupThreadMessage(threadId: threadId, body: trimmed)
            messages.append(message)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
final class NewGroupThreadViewModel: ObservableObject {
    @Published var name = ""
    @Published var query = ""
    @Published var searchResults: [GalleryUser] = []
    @Published var selectedMembers: [GalleryUser] = []
    @Published var isSearching = false
    @Published var isCreating = false
    @Published var errorMessage: String?
    @Published var createdThread: GroupThread?

    private let api = GalleryAPIClient.shared

    func search() async {
        guard !query.isEmpty else { searchResults = []; return }
        isSearching = true
        defer { isSearching = false }
        searchResults = (try? await api.searchUsers(query: query)) ?? []
    }

    func toggle(_ user: GalleryUser) {
        if let index = selectedMembers.firstIndex(where: { $0.id == user.id }) {
            selectedMembers.remove(at: index)
        } else {
            selectedMembers.append(user)
        }
    }

    func isSelected(_ user: GalleryUser) -> Bool {
        selectedMembers.contains { $0.id == user.id }
    }

    func create() async {
        guard !selectedMembers.isEmpty else {
            errorMessage = "Pick at least one other member."
            return
        }
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        do {
            createdThread = try await api.createGroupThread(memberIds: selectedMembers.map(\.id), name: name.isEmpty ? nil : name)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
