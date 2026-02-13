import Foundation

enum SupabaseConfig {
    private static let placeholderURLString = "PASTE_SUPABASE_URL_HERE"
    private static let placeholderAnonKey = "PASTE_SUPABASE_ANON_KEY_HERE"

    private static var plist: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    static var urlString: String {
        ProcessInfo.processInfo.environment["SUPABASE_URL"]
            ?? plist["SUPABASE_URL"] as? String
            ?? ""
    }

    static var anonKey: String {
        ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"]
            ?? plist["SUPABASE_ANON_KEY"] as? String
            ?? ""
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
