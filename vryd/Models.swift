import Foundation
import CoreLocation

enum AuthProvider: String, Codable, CaseIterable, Identifiable {
    case email
    case apple
    case google

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .email: return "Email"
        case .apple: return "Apple"
        case .google: return "Google"
        }
    }
}

struct UserProfile: Identifiable, Hashable {
    let id: UUID
    var username: String
    var email: String
    var city: String
    var provider: AuthProvider
}

struct GridCell: Identifiable {
    let id: String
    let center: CLLocationCoordinate2D
    let dateKey: String

    init(center: CLLocationCoordinate2D, date: Date = .now) {
        self.center = center
        self.dateKey = GridCell.dayFormatter.string(from: date)
        self.id = "\(GridCell.cellKey(for: center))_\(dateKey)"
    }

    static func cellKey(for coordinate: CLLocationCoordinate2D) -> String {
        let latStep = metersToLatitudeDegrees(100)
        let lonStep = metersToLongitudeDegrees(100, at: coordinate.latitude)
        let latIndex = Int(floor(coordinate.latitude / latStep))
        let lonIndex = Int(floor(coordinate.longitude / lonStep))
        return "\(latIndex):\(lonIndex)"
    }

    static func corners(for coordinate: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        let latStep = metersToLatitudeDegrees(100)
        let lonStep = metersToLongitudeDegrees(100, at: coordinate.latitude)
        let startLat = floor(coordinate.latitude / latStep) * latStep
        let startLon = floor(coordinate.longitude / lonStep) * lonStep
        return [
            CLLocationCoordinate2D(latitude: startLat, longitude: startLon),
            CLLocationCoordinate2D(latitude: startLat + latStep, longitude: startLon),
            CLLocationCoordinate2D(latitude: startLat + latStep, longitude: startLon + lonStep),
            CLLocationCoordinate2D(latitude: startLat, longitude: startLon + lonStep)
        ]
    }

    static func metersToLatitudeDegrees(_ meters: Double) -> Double {
        meters / 111_111.0
    }

    static func metersToLongitudeDegrees(_ meters: Double, at latitude: Double) -> Double {
        let adjusted = max(cos(latitude * .pi / 180.0), 0.1)
        return meters / (111_111.0 * adjusted)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

struct ChatMessage: Identifiable, Hashable {
    let id: UUID
    let authorID: UUID
    let author: String
    let text: String
    let createdAt: Date
    let gridCellID: String
    var likes: Int
}

struct ProfileRecord: Codable {
    let id: UUID
    let username: String
    let email: String
    let provider: String
    let city: String
}

struct GridMessageRecord: Codable {
    let id: UUID
    let authorID: UUID
    let author: String
    let text: String
    let gridCellID: String
    let likes: Int
    let createdAt: Date
}
