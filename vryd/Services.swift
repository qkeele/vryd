import Foundation
import CoreLocation

protocol VrydBackend {
    func signUp(username: String, email: String, password: String) async throws -> UserProfile
    func signIn(email: String, password: String) async throws -> UserProfile
    func fetchLiveMessages(in cell: GridCell) async throws -> [ChatMessage]
    func fetchArchivedMessages(in cell: GridCell) async throws -> [String: [ChatMessage]]
    func fetchProfileMessages(for userID: UUID) async throws -> [ChatMessage]
    func postMessage(_ text: String, in cell: GridCell, from user: UserProfile) async throws -> ChatMessage
    func like(messageID: UUID) async throws
    func delete(messageID: UUID, by userID: UUID) async throws
}

actor MockVrydBackend: VrydBackend {
    private var users: [String: UserProfile] = [:]
    private var messages: [ChatMessage] = [
        ChatMessage(
            id: UUID(),
            authorID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            author: "street_owl",
            text: "Farmer's market sets up around 8am here.",
            createdAt: .now.addingTimeInterval(-1200),
            gridCellID: "0:0_\(dayKey())",
            city: "San Francisco",
            likes: 7,
            isArchived: false
        ),
        ChatMessage(
            id: UUID(),
            authorID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            author: "street_owl",
            text: "Yesterday someone was filming a music video by the corner.",
            createdAt: .now.addingTimeInterval(-86_400),
            gridCellID: "0:0_\(previousDayKey())",
            city: "San Francisco",
            likes: 0,
            isArchived: true
        )
    ]

    func signUp(username: String, email: String, password: String) async throws -> UserProfile {
        let profile = UserProfile(id: UUID(), username: username, city: "Unknown")
        users[email.lowercased()] = profile
        return profile
    }

    func signIn(email: String, password: String) async throws -> UserProfile {
        if let existing = users[email.lowercased()] {
            return existing
        }
        let generated = UserProfile(id: UUID(), username: email.components(separatedBy: "@").first ?? "vryd_user", city: "Unknown")
        users[email.lowercased()] = generated
        return generated
    }

    func fetchLiveMessages(in cell: GridCell) async throws -> [ChatMessage] {
        messages
            .filter { $0.gridCellID == cell.id && !$0.isArchived }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func fetchArchivedMessages(in cell: GridCell) async throws -> [String: [ChatMessage]] {
        let archived = messages.filter { $0.gridCellID.contains(GridCell.cellKey(for: cell.center)) && $0.isArchived }
        return Dictionary(grouping: archived, by: { $0.dayKey })
    }

    func fetchProfileMessages(for userID: UUID) async throws -> [ChatMessage] {
        messages
            .filter { $0.authorID == userID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func postMessage(_ text: String, in cell: GridCell, from user: UserProfile) async throws -> ChatMessage {
        let message = ChatMessage(
            id: UUID(),
            authorID: user.id,
            author: user.username,
            text: text,
            createdAt: .now,
            gridCellID: cell.id,
            city: user.city,
            likes: 0,
            isArchived: false
        )
        messages.append(message)
        return message
    }

    func like(messageID: UUID) async throws {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index].likes += 1
    }

    func delete(messageID: UUID, by userID: UUID) async throws {
        messages.removeAll { $0.id == messageID && $0.authorID == userID }
    }

    private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func dayKey() -> String {
        dayFormatter().string(from: .now)
    }

    private static func previousDayKey() -> String {
        dayFormatter().string(from: .now.addingTimeInterval(-86_400))
    }
}

struct SupabaseConfig {
    let projectURL: URL
    let anonKey: String

    static func fromEnvironment() -> SupabaseConfig? {
        guard
            let urlString = ProcessInfo.processInfo.environment["SUPABASE_URL"],
            let url = URL(string: urlString),
            let anon = ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"]
        else {
            return nil
        }
        return SupabaseConfig(projectURL: url, anonKey: anon)
    }
}

struct SupabaseSetupGuide {
    static let sql = """
    create table if not exists profiles (
      id uuid primary key,
      username text not null,
      city text default ''
    );

    create table if not exists grid_messages (
      id uuid primary key default gen_random_uuid(),
      author_id uuid references profiles(id),
      author text not null,
      text text not null,
      city text default '',
      grid_cell_id text not null,
      likes int default 0,
      created_at timestamptz default now(),
      is_archived boolean default false
    );
    """
}
