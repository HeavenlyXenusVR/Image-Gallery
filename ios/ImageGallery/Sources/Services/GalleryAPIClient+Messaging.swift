import Foundation

private struct MessageThreadsResponse: Decodable { var threads: [MessageThread] }
private struct DirectMessagesResponse: Decodable { var messages: [DirectMessage] }
private struct DirectMessageResponse: Decodable { var message: DirectMessage }
private struct GroupThreadsResponse: Decodable { var threads: [GroupThread] }
private struct GroupThreadResponse: Decodable { var thread: GroupThread }
private struct ThreadMessagesResponse: Decodable { var messages: [ThreadMessage] }
private struct ThreadMessageResponse: Decodable { var message: ThreadMessage }

extension GalleryAPIClient {
    struct DirectMessageBody: Encodable { var body: String }
    struct ThreadCreateBody: Encodable { var memberIds: [Int]; var name: String? }
    struct ThreadMessageBody: Encodable { var body: String }

    // MARK: 1:1 direct messages

    func messageThreads() async throws -> [MessageThread] {
        let response: MessageThreadsResponse = try await requestJSON("/api/messages/threads")
        return response.threads
    }

    func directMessages(userId: Int, limit: Int = 80) async throws -> [DirectMessage] {
        let response: DirectMessagesResponse = try await requestJSON("/api/messages/\(userId)", query: ["limit": String(limit)])
        return response.messages
    }

    func sendDirectMessage(userId: Int, body: String) async throws -> DirectMessage {
        let response: DirectMessageResponse = try await requestJSON("/api/messages/\(userId)", body: DirectMessageBody(body: body))
        return response.message
    }

    // MARK: Group threads

    func groupThreads() async throws -> [GroupThread] {
        let response: GroupThreadsResponse = try await requestJSON("/api/threads")
        return response.threads
    }

    func createGroupThread(memberIds: [Int], name: String?) async throws -> GroupThread {
        let response: GroupThreadResponse = try await requestJSON("/api/threads", body: ThreadCreateBody(memberIds: memberIds, name: name))
        return response.thread
    }

    func groupThreadMessages(threadId: Int) async throws -> [ThreadMessage] {
        let response: ThreadMessagesResponse = try await requestJSON("/api/threads/\(threadId)/messages")
        return response.messages
    }

    func sendGroupThreadMessage(threadId: Int, body: String) async throws -> ThreadMessage {
        let response: ThreadMessageResponse = try await requestJSON("/api/threads/\(threadId)/messages", body: ThreadMessageBody(body: body))
        return response.message
    }
}
