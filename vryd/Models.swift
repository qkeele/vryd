import Foundation
import CoreLocation

enum AuthProvider: String, Codable, CaseIterable, Identifiable {
    case apple

    var id: String { rawValue }
}

struct UserProfile: Identifiable, Hashable {
    let id: UUID
    var username: String
    var email: String
    var provider: AuthProvider

    var hasValidUsername: Bool {
        UsernameRules.isValid(username)
    }
}

enum UsernameRules {
    static let minLength = 3
    static let maxLength = 20

    static func isValid(_ username: String) -> Bool {
        guard username.count >= minLength, username.count <= maxLength else { return false }
        guard username.range(of: "^[A-Za-z0-9._]+$", options: .regularExpression) != nil else { return false }
        guard !username.hasPrefix("."), !username.hasSuffix("."), !username.contains("..") else { return false }
        return true
    }

    static var helperText: String {
        "3–20 chars. Use letters, numbers, periods, and underscores. No leading/trailing periods, no consecutive periods."
    }
}

struct GridCell: Identifiable, Hashable {
    let id: String
    let dateKey: String

    init(coordinate: CLLocationCoordinate2D, date: Date = .now) {
        self.dateKey = GridCell.dayFormatter.string(from: date)
        self.id = "\(SpatialGrid.cellID(for: coordinate))_\(dateKey)"
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

enum SpatialGrid {
    /// Stable computed grid. For production this should be replaced by H3 index at ~100m resolution.
    static let cellSizeMeters: Double = 100

    static func cellID(for coordinate: CLLocationCoordinate2D) -> String {
        let meters = mercatorMeters(for: coordinate)
        let xIndex = Int(floor(meters.x / cellSizeMeters))
        let yIndex = Int(floor(meters.y / cellSizeMeters))
        return "\(xIndex):\(yIndex)"
    }

    static func cellIndices(for coordinate: CLLocationCoordinate2D) -> (x: Int, y: Int) {
        let meters = mercatorMeters(for: coordinate)
        return (Int(floor(meters.x / cellSizeMeters)), Int(floor(meters.y / cellSizeMeters)))
    }

    static func corners(forX x: Int, y: Int) -> [CLLocationCoordinate2D] {
        let minX = Double(x) * cellSizeMeters
        let minY = Double(y) * cellSizeMeters
        let maxX = minX + cellSizeMeters
        let maxY = minY + cellSizeMeters

        return [
            coordinate(forMercatorX: minX, y: minY),
            coordinate(forMercatorX: maxX, y: minY),
            coordinate(forMercatorX: maxX, y: maxY),
            coordinate(forMercatorX: minX, y: maxY)
        ]
    }

    private static let originShift = 20_037_508.342789244

    private static func mercatorMeters(for coordinate: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        let x = coordinate.longitude * originShift / 180.0
        let lat = min(max(coordinate.latitude, -85.05112878), 85.05112878)
        let y = log(tan((90 + lat) * .pi / 360.0)) / (.pi / 180.0)
        return (x, y * originShift / 180.0)
    }

    private static func coordinate(forMercatorX x: Double, y: Double) -> CLLocationCoordinate2D {
        let lon = (x / originShift) * 180.0
        var lat = (y / originShift) * 180.0
        lat = 180.0 / .pi * (2.0 * atan(exp(lat * .pi / 180.0)) - .pi / 2.0)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

struct ChatMessage: Identifiable, Hashable {
    let id: UUID
    let authorID: UUID
    let author: String
    let text: String
    let createdAt: Date
    let gridCellID: String
    let parentID: UUID?
    var likeCount: Int
    var userHasLiked: Bool
}
