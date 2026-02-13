import Foundation

enum SupabaseConfig {
    // Paste your values here.
    static let urlString = "PASTE_SUPABASE_URL_HERE"
    static let anonKey = "PASTE_SUPABASE_ANON_KEY_HERE"

    static var url: URL? {
        URL(string: urlString)
    }

    static var isConfigured: Bool {
        guard let url, url.scheme?.isEmpty == false else { return false }
        return !anonKey.isEmpty && anonKey != "PASTE_SUPABASE_ANON_KEY_HERE"
    }
}
