import Foundation
import CoreLocation

struct UserProfile: Identifiable, Hashable {
    let id: UUID
    var username: String
    var city: String
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
    var city: String
    var likes: Int
    var isArchived: Bool

    var dayKey: String {
        Self.dayFormatter.string(from: createdAt)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()
}
