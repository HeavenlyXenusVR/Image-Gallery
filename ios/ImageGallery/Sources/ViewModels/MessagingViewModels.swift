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
            if !error.isCancellation { errorMessage = error.localizedDescription }
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
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    /// Background freshness poll — unlike `load()`, a failure here is not
    /// surfaced (a single dropped poll shouldn't paint a persistent error
    /// banner over an otherwise-working thread), and the result is merged
    /// rather than assigned outright so a poll that was in flight before a
    /// local `send()` completed can't clobber the just-sent message.
    func refreshSilently() async {
        guard let fetched = try? await api.directMessages(userId: userId) else { return }
        var byId = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for message in fetched { byId[message.id] = message }
        messages = byId.values.sorted { $0.id < $1.id }
    }

    @discardableResult
    func send(_ body: String) async -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        isSending = true
        defer { isSending = false }
        do {
            let message = try await api.sendDirectMessage(userId: userId, body: trimmed)
            messages.append(message)
            return true
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
            return false
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
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    /// See `DirectMessageThreadViewModel.refreshSilently` — same rationale.
    func refreshSilently() async {
        guard let fetched = try? await api.groupThreadMessages(threadId: threadId) else { return }
        var byId = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for message in fetched { byId[message.id] = message }
        messages = byId.values.sorted { $0.id < $1.id }
    }

    @discardableResult
    func send(_ body: String) async -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        isSending = true
        defer { isSending = false }
        do {
            let message = try await api.sendGroupThreadMessage(threadId: threadId, body: trimmed)
            messages.append(message)
            return true
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
            return false
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
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }
}
