import Foundation
import CoreLocation

import Supabase

actor SupabaseVrydBackend: VrydBackend {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func signInWithApple() async throws -> UserProfile {
        // Quick-start behavior: anonymous auth so app is immediately usable after adding URL/key.
        // You can replace this with full Apple ID token exchange later.
        _ = try await client.auth.signInAnonymously()

        guard let authUser = client.auth.currentUser else { throw BackendError.notFound }

        if let existing = try? await fetchProfile(id: authUser.id) {
            return existing
        }

        let inserted: ProfileRow = try await client
            .from("profiles")
            .insert(ProfileInsertRow(id: authUser.id.uuidString, email: authUser.email ?? "", provider: "apple"))
            .select()
            .single()
            .execute()
            .value

        return inserted.asUserProfile
    }

    func updateUsername(userID: UUID, username: String) async throws -> UserProfile {
        guard UsernameRules.isValid(username) else { throw BackendError.invalidUsername }
        guard try await isUsernameAvailable(username) else { throw BackendError.usernameTaken }

        do {
            let updated: ProfileRow = try await client
                .from("profiles")
                .update(["username": username])
                .eq("id", value: userID.uuidString)
                .select()
                .single()
                .execute()
                .value

            return updated.asUserProfile
        } catch {
            // Defensive guard: if another user claims the name between pre-check and update.
            if !(try await isUsernameAvailable(username)) {
                throw BackendError.usernameTaken
            }

            throw error
        }
    }

    func isUsernameAvailable(_ username: String) async throws -> Bool {
        guard UsernameRules.isValid(username) else { return false }

        let normalized = username.lowercased()
        let rows: [ProfileLookupRow] = try await client
            .from("profiles")
            .select("id, username")
            .ilike("username", pattern: normalized)
            .limit(1)
            .execute()
            .value

        return rows.isEmpty
    }

    func fetchMessages(in cell: GridCell, viewerID: UUID) async throws -> [ChatMessage] {
        let rows: [MessageRow] = try await client
            .from("messages")
            .select("id, author_id, text, grid_cell_id, parent_id, created_at, profiles(username)")
            .eq("grid_cell_id", value: cell.id)
            .order("created_at", ascending: false)
            .execute()
            .value

        return try await withThrowingTaskGroup(of: ChatMessage.self) { group in
            for row in rows {
                group.addTask {
                    let hasLiked = try await self.hasUserLiked(messageID: row.id, userID: viewerID)
                    let likeCount = try await self.likeCount(for: row.id)
                    return row.asChatMessage(userHasLiked: hasLiked, likeCount: likeCount)
                }
            }

            var messages: [ChatMessage] = []
            for try await message in group {
                messages.append(message)
            }
            return messages.sorted { $0.createdAt > $1.createdAt }
        }
    }

    func fetchProfileMessages(for userID: UUID) async throws -> [ChatMessage] {
        let rows: [MessageRow] = try await client
            .from("messages")
            .select("id, author_id, text, grid_cell_id, parent_id, created_at, profiles(username)")
            .eq("author_id", value: userID.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value

        return try await withThrowingTaskGroup(of: ChatMessage.self) { group in
            for row in rows {
                group.addTask {
                    let likeCount = try await self.likeCount(for: row.id)
                    return row.asChatMessage(userHasLiked: false, likeCount: likeCount)
                }
            }

            var messages: [ChatMessage] = []
            for try await message in group {
                messages.append(message)
            }
            return messages.sorted { $0.createdAt > $1.createdAt }
        }
    }

    func fetchDailyCellCounts(near coordinate: CLLocationCoordinate2D, radiusMeters: Double, date: Date) async throws -> [String: Int] {
        let dayKey = GridCell(coordinate: coordinate, date: date).dateKey
        let center = SpatialGrid.cellIndices(for: coordinate)
        let radiusCells = max(1, Int(ceil(radiusMeters / SpatialGrid.cellSizeMeters)))

        let rows: [MessageGridOnlyRow] = try await client
            .from("messages")
            .select("grid_cell_id")
            .like("grid_cell_id", pattern: "%_\(dayKey)")
            .execute()
            .value

        var result: [String: Int] = [:]

        for row in rows {
            let parts = row.gridCellID.split(separator: "_")
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
        let inserted: MessageRow = try await client
            .from("messages")
            .insert(MessageInsertRow(authorID: user.id.uuidString, text: text, gridCellID: cell.id, parentID: parentID?.uuidString))
            .select("id, author_id, text, grid_cell_id, parent_id, created_at, profiles(username)")
            .single()
            .execute()
            .value

        return inserted.asChatMessage(userHasLiked: false, likeCount: 0)
    }

    func like(messageID: UUID, by userID: UUID) async throws {
        _ = try await client
            .from("message_likes")
            .upsert(["message_id": messageID.uuidString, "user_id": userID.uuidString], onConflict: "message_id,user_id")
            .execute()
    }

    func delete(messageID: UUID, by userID: UUID) async throws {
        _ = try await client
            .from("messages")
            .delete()
            .eq("id", value: messageID.uuidString)
            .eq("author_id", value: userID.uuidString)
            .execute()
    }

    func deleteAccount(userID: UUID) async throws {
        _ = try await client
            .from("profiles")
            .delete()
            .eq("id", value: userID.uuidString)
            .execute()

        try await client.auth.signOut()
    }

    private func fetchProfile(id: UUID) async throws -> UserProfile {
        let profile: ProfileRow = try await client
            .from("profiles")
            .select()
            .eq("id", value: id.uuidString)
            .single()
            .execute()
            .value

        return profile.asUserProfile
    }


    private func likeCount(for messageID: UUID) async throws -> Int {
        let rows: [LikeRow] = try await client
            .from("message_likes")
            .select("message_id")
            .eq("message_id", value: messageID.uuidString)
            .execute()
            .value

        return rows.count
    }

    private func hasUserLiked(messageID: UUID, userID: UUID) async throws -> Bool {
        let rows: [LikeRow] = try await client
            .from("message_likes")
            .select("message_id")
            .eq("message_id", value: messageID.uuidString)
            .eq("user_id", value: userID.uuidString)
            .limit(1)
            .execute()
            .value

        return !rows.isEmpty
    }
}

private struct ProfileInsertRow: Encodable {
    let id: String
    let email: String
    let provider: String
}

private struct ProfileRow: Decodable {
    let id: UUID
    let username: String?
    let email: String
    let provider: String

    var asUserProfile: UserProfile {
        UserProfile(
            id: id,
            username: username ?? "",
            email: email,
            provider: AuthProvider(rawValue: provider) ?? .apple
        )
    }
}

private struct ProfileLookupRow: Decodable {
    let id: UUID
    let username: String?
}

private struct MessageInsertRow: Encodable {
    let authorID: String
    let text: String
    let gridCellID: String
    let parentID: String?

    enum CodingKeys: String, CodingKey {
        case authorID = "author_id"
        case text
        case gridCellID = "grid_cell_id"
        case parentID = "parent_id"
    }
}

private struct ProfileNameContainer: Decodable {
    let username: String?
}

private struct MessageRow: Decodable {
    let id: UUID
    let authorID: UUID
    let text: String
    let gridCellID: String
    let parentID: UUID?
    let createdAt: Date
    let profiles: ProfileNameContainer?

    enum CodingKeys: String, CodingKey {
        case id
        case authorID = "author_id"
        case text
        case gridCellID = "grid_cell_id"
        case parentID = "parent_id"
        case createdAt = "created_at"
        case profiles
    }

    func asChatMessage(userHasLiked: Bool, likeCount: Int) -> ChatMessage {
        let resolvedAuthor = profiles?.username ?? "unknown"
        return ChatMessage(
            id: id,
            authorID: authorID,
            author: resolvedAuthor,
            text: text,
            createdAt: createdAt,
            gridCellID: gridCellID,
            parentID: parentID,
            likeCount: likeCount,
            userHasLiked: userHasLiked
        )
    }
}

private struct MessageGridOnlyRow: Decodable {
    let gridCellID: String

    enum CodingKeys: String, CodingKey {
        case gridCellID = "grid_cell_id"
    }
}

private struct LikeRow: Decodable {
    let messageID: UUID

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
    }
}

enum BackendFactory {
    static func makeBackend() -> VrydBackend {
        guard SupabaseConfig.isConfigured, let url = SupabaseConfig.url else {
            print("⚠️ Supabase is not configured. Set SUPABASE_URL and SUPABASE_ANON_KEY in your scheme environment or Info.plist.")
            return LiveVrydBackend()
        }

        let client = SupabaseClient(supabaseURL: url, supabaseKey: SupabaseConfig.anonKey)
        return SupabaseVrydBackend(client: client)
    }
}
