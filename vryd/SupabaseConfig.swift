import Foundation

enum SupabaseConfig {
    private static let placeholderURLString = "PASTE_SUPABASE_URL_HERE"
    private static let placeholderAnonKey = "PASTE_SUPABASE_ANON_KEY_HERE"

    private static var plist: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    private static func firstNonEmpty(_ values: [String?]) -> String {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            ?? ""
    }

    static var urlString: String {
        firstNonEmpty([
            ProcessInfo.processInfo.environment["SUPABASE_URL"],
            ProcessInfo.processInfo.environment["NEXT_PUBLIC_SUPABASE_URL"],
            plist["SUPABASE_URL"] as? String,
            plist["NEXT_PUBLIC_SUPABASE_URL"] as? String
        ])
    }

    static var anonKey: String {
        firstNonEmpty([
            ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"],
            ProcessInfo.processInfo.environment["SUPABASE_KEY"],
            ProcessInfo.processInfo.environment["NEXT_PUBLIC_SUPABASE_ANON_KEY"],
            plist["SUPABASE_ANON_KEY"] as? String,
            plist["SUPABASE_KEY"] as? String,
            plist["NEXT_PUBLIC_SUPABASE_ANON_KEY"] as? String
        ])
    }

    static var url: URL? {
        URL(string: urlString)
    }

    static var isConfigured: Bool {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = anonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty,
              trimmedURL != placeholderURLString,
              !trimmedKey.isEmpty,
              trimmedKey != placeholderAnonKey,
              let url,
              url.scheme?.isEmpty == false else {
            return false
        }

        return true
    }
}
