import Foundation
import CoreLocation

protocol VrydBackend {
    func signInWithApple() async throws -> UserProfile
    func isUsernameAvailable(_ username: String) async throws -> Bool
    func updateUsername(userID: UUID, username: String) async throws -> UserProfile
    func fetchMessages(in cell: GridCell, viewerID: UUID) async throws -> [ChatMessage]
    func fetchProfileMessages(for userID: UUID) async throws -> [ChatMessage]
    func fetchDailyCellCounts(near coordinate: CLLocationCoordinate2D, radiusMeters: Double, date: Date) async throws -> [String: Int]
    func postMessage(_ text: String, in cell: GridCell, from user: UserProfile, parentID: UUID?) async throws -> ChatMessage
    func like(messageID: UUID, by userID: UUID) async throws
    func delete(messageID: UUID, by userID: UUID) async throws
    func deleteAccount(userID: UUID) async throws
}

enum BackendError: LocalizedError {
    case invalidUsername
    case usernameTaken
    case notFound
    case serverUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidUsername: return "Username does not match the allowed format."
        case .usernameTaken: return "That username is already taken."
        case .notFound: return "Record not found."
        case .serverUnavailable: return "Server error. Please try again."
        }
    }
}

actor UnavailableVrydBackend: VrydBackend {
    func signInWithApple() async throws -> UserProfile { throw BackendError.serverUnavailable }
    func isUsernameAvailable(_ username: String) async throws -> Bool { throw BackendError.serverUnavailable }
    func updateUsername(userID: UUID, username: String) async throws -> UserProfile { throw BackendError.serverUnavailable }
    func fetchMessages(in cell: GridCell, viewerID: UUID) async throws -> [ChatMessage] { throw BackendError.serverUnavailable }
    func fetchProfileMessages(for userID: UUID) async throws -> [ChatMessage] { throw BackendError.serverUnavailable }
    func fetchDailyCellCounts(near coordinate: CLLocationCoordinate2D, radiusMeters: Double, date: Date) async throws -> [String : Int] { throw BackendError.serverUnavailable }
    func postMessage(_ text: String, in cell: GridCell, from user: UserProfile, parentID: UUID?) async throws -> ChatMessage { throw BackendError.serverUnavailable }
    func like(messageID: UUID, by userID: UUID) async throws { throw BackendError.serverUnavailable }
    func delete(messageID: UUID, by userID: UUID) async throws { throw BackendError.serverUnavailable }
    func deleteAccount(userID: UUID) async throws { throw BackendError.serverUnavailable }
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
        guard try await isUsernameAvailable(username) else { throw BackendError.usernameTaken }
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

    func isUsernameAvailable(_ username: String) async throws -> Bool {
        let normalized = username.lowercased()
        return !users.values.contains(where: { $0.username.lowercased() == normalized })
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


    func fetchDailyCellCounts(near coordinate: CLLocationCoordinate2D, radiusMeters: Double, date: Date) async throws -> [String: Int] {
        let dayKey = GridCell(coordinate: coordinate, date: date).dateKey
        let center = SpatialGrid.cellIndices(for: coordinate)
        let radiusCells = max(1, Int(ceil(radiusMeters / SpatialGrid.cellSizeMeters)))
        var result: [String: Int] = [:]

        for message in messages {
            let parts = message.gridCellID.split(separator: "_")
            guard parts.count == 2,
                  String(parts[1]) == dayKey,
                  let indices = SpatialGrid.parseCellID(String(parts[0])) else {
                continue
            }

            let dx = abs(indices.x - center.x)
            let dy = abs(indices.y - center.y)
            guard dx <= radiusCells, dy <= radiusCells else { continue }
            let key = SpatialGrid.cellID(x: indices.x, y: indices.y)
            result[key, default: 0] += 1
        }

        return result
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
