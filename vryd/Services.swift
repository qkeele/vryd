import Foundation

protocol VrydBackend {
    func signInWithApple() async throws -> UserProfile
    func updateUsername(userID: UUID, username: String) async throws -> UserProfile
    func fetchMessages(in cell: GridCell, viewerID: UUID) async throws -> [ChatMessage]
    func fetchProfileMessages(for userID: UUID) async throws -> [ChatMessage]
    func postMessage(_ text: String, in cell: GridCell, from user: UserProfile, parentID: UUID?) async throws -> ChatMessage
    func like(messageID: UUID, by userID: UUID) async throws
    func delete(messageID: UUID, by userID: UUID) async throws
    func deleteAccount(userID: UUID) async throws
}

enum BackendError: LocalizedError {
    case invalidUsername
    case notFound

    var errorDescription: String? {
        switch self {
        case .invalidUsername: return "Username does not match the allowed format."
        case .notFound: return "Record not found."
        }
    }
}

actor LiveVrydBackend: VrydBackend {
    private struct StoredMessage {
        let id: UUID
        let authorID: UUID
        let author: String
        let text: String
        let createdAt: Date
        let gridCellID: String
        let parentID: UUID?
        var likedBy: Set<UUID>
    }

    private var users: [UUID: UserProfile] = [:]
    private var messages: [StoredMessage] = []

    func signInWithApple() async throws -> UserProfile {
        let id = UUID()
        let user = UserProfile(
            id: id,
            username: "",
            email: "apple_\(id.uuidString.prefix(6))@privaterelay.appleid.com",
            provider: .apple
        )
        users[id] = user
        return user
    }

    func updateUsername(userID: UUID, username: String) async throws -> UserProfile {
        guard UsernameRules.isValid(username) else { throw BackendError.invalidUsername }
        guard var user = users[userID] else { throw BackendError.notFound }
        user.username = username
        users[userID] = user

        for idx in messages.indices where messages[idx].authorID == userID {
            messages[idx] = StoredMessage(
                id: messages[idx].id,
                authorID: messages[idx].authorID,
                author: username,
                text: messages[idx].text,
                createdAt: messages[idx].createdAt,
                gridCellID: messages[idx].gridCellID,
                parentID: messages[idx].parentID,
                likedBy: messages[idx].likedBy
            )
        }

        return user
    }

    func fetchMessages(in cell: GridCell, viewerID: UUID) async throws -> [ChatMessage] {
        messages
            .filter { $0.gridCellID == cell.id }
            .sorted { $0.createdAt > $1.createdAt }
            .map { record in
                ChatMessage(
                    id: record.id,
                    authorID: record.authorID,
                    author: record.author,
                    text: record.text,
                    createdAt: record.createdAt,
                    gridCellID: record.gridCellID,
                    parentID: record.parentID,
                    likeCount: record.likedBy.count,
                    userHasLiked: record.likedBy.contains(viewerID)
                )
            }
    }

    func fetchProfileMessages(for userID: UUID) async throws -> [ChatMessage] {
        messages
            .filter { $0.authorID == userID }
            .sorted { $0.createdAt > $1.createdAt }
            .map { record in
                ChatMessage(
                    id: record.id,
                    authorID: record.authorID,
                    author: record.author,
                    text: record.text,
                    createdAt: record.createdAt,
                    gridCellID: record.gridCellID,
                    parentID: record.parentID,
                    likeCount: record.likedBy.count,
                    userHasLiked: record.likedBy.contains(userID)
                )
            }
    }

    func postMessage(_ text: String, in cell: GridCell, from user: UserProfile, parentID: UUID?) async throws -> ChatMessage {
        let message = StoredMessage(
            id: UUID(),
            authorID: user.id,
            author: user.username,
            text: text,
            createdAt: .now,
            gridCellID: cell.id,
            parentID: parentID,
            likedBy: []
        )
        messages.append(message)
        return ChatMessage(
            id: message.id,
            authorID: message.authorID,
            author: message.author,
            text: message.text,
            createdAt: message.createdAt,
            gridCellID: message.gridCellID,
            parentID: message.parentID,
            likeCount: 0,
            userHasLiked: false
        )
    }

    func like(messageID: UUID, by userID: UUID) async throws {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { throw BackendError.notFound }
        guard !messages[index].likedBy.contains(userID) else { return }
        messages[index].likedBy.insert(userID)
    }

    func delete(messageID: UUID, by userID: UUID) async throws {
        guard let target = messages.first(where: { $0.id == messageID }) else { return }
        guard target.authorID == userID else { return }
        messages.removeAll { $0.id == messageID || $0.parentID == messageID }
    }

    func deleteAccount(userID: UUID) async throws {
        users.removeValue(forKey: userID)
        messages.removeAll { $0.authorID == userID }
        for idx in messages.indices {
            messages[idx].likedBy.remove(userID)
        }
    }
}
