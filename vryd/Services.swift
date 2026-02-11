import Foundation
import CoreLocation

protocol VrydBackend {
    func signUp(username: String, email: String, password: String) async throws -> UserProfile
    func signIn(email: String, password: String) async throws -> UserProfile
    func signInWithApple() async throws -> UserProfile
    func signInWithGoogle() async throws -> UserProfile
    func fetchMessages(in cell: GridCell) async throws -> [ChatMessage]
    func fetchProfileMessages(for userID: UUID) async throws -> [ChatMessage]
    func postMessage(_ text: String, in cell: GridCell, from user: UserProfile) async throws -> ChatMessage
    func like(messageID: UUID) async throws
    func delete(messageID: UUID, by userID: UUID) async throws
}

enum BackendError: LocalizedError {
    case unsupportedProvider
    case missingCredentials

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "This sign in provider is not configured yet."
        case .missingCredentials:
            return "Enter all fields to continue."
        }
    }
}

actor LiveVrydBackend: VrydBackend {
    private var users: [String: UserProfile] = [:]
    private var messages: [ChatMessage] = []

    func signUp(username: String, email: String, password: String) async throws -> UserProfile {
        guard !username.isEmpty, !email.isEmpty, !password.isEmpty else { throw BackendError.missingCredentials }
        let user = UserProfile(id: UUID(), username: username, email: email, city: "", provider: .email)
        users[email.lowercased()] = user
        return user
    }

    func signIn(email: String, password: String) async throws -> UserProfile {
        guard !email.isEmpty, !password.isEmpty else { throw BackendError.missingCredentials }
        if let user = users[email.lowercased()] { return user }
        let user = UserProfile(
            id: UUID(),
            username: email.components(separatedBy: "@").first ?? "vryd_user",
            email: email,
            city: "",
            provider: .email
        )
        users[email.lowercased()] = user
        return user
    }

    func signInWithApple() async throws -> UserProfile {
        throw BackendError.unsupportedProvider
    }

    func signInWithGoogle() async throws -> UserProfile {
        throw BackendError.unsupportedProvider
    }

    func fetchMessages(in cell: GridCell) async throws -> [ChatMessage] {
        messages
            .filter { $0.gridCellID == cell.id }
            .sorted { $0.createdAt > $1.createdAt }
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
            likes: 0
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
      email text unique not null,
      provider text not null,
      city text default ''
    );

    create table if not exists grid_messages (
      id uuid primary key default gen_random_uuid(),
      author_id uuid references profiles(id),
      author text not null,
      text text not null,
      grid_cell_id text not null,
      likes int default 0,
      created_at timestamptz default now()
    );

    create index if not exists idx_grid_messages_cell on grid_messages(grid_cell_id, created_at desc);
    """
}
