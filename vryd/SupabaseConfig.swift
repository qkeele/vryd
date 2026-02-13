import Foundation

enum SupabaseConfig {
    // Fallbacks for local development; prefer env vars or Info.plist keys.
    private static let fallbackURLString = "PASTE_SUPABASE_URL_HERE"
    private static let fallbackAnonKey = "PASTE_SUPABASE_ANON_KEY_HERE"

    private static var plist: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    static var urlString: String {
        ProcessInfo.processInfo.environment["SUPABASE_URL"]
            ?? plist["SUPABASE_URL"] as? String
            ?? fallbackURLString
    }

    static var anonKey: String {
        ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"]
            ?? plist["SUPABASE_ANON_KEY"] as? String
            ?? fallbackAnonKey
    }

    static var url: URL? {
        URL(string: urlString)
    }

    static var isConfigured: Bool {
        guard let url, url.scheme?.isEmpty == false else { return false }
        return !anonKey.isEmpty && anonKey != fallbackAnonKey
    }
}
