import SwiftUI
import MapKit
import CoreLocation
import Combine

@MainActor
/// Central app state and async workflows for auth, location, and messaging.
final class AppViewModel: ObservableObject {
    enum Screen {
        case main
    }

    enum AuthFlowStep: Equatable {
        case signIn
        case usernameSetup
    }

    enum UsernameAvailability: Equatable {
        case idle
        case checking
        case available
        case unavailable
    }

    enum LocationGateState {
        case idle
        case denied
        case ready
    }

    enum TopLevelSortOption: String, CaseIterable, Identifiable {
        case likes
        case newest
        case oldest

        var id: String { rawValue }

        var title: String {
            switch self {
            case .likes:
                return "Top"
            case .newest:
                return "Newest"
            case .oldest:
                return "Oldest"
            }
        }
    }

    @Published var screen: Screen = .main
    @Published var statusMessage = ""
    @Published var usernameDraft = ""
    @Published var authFlowStep: AuthFlowStep = .signIn
    @Published var usernameAvailability: UsernameAvailability = .idle
    @Published var authBusy = false
    @Published var showingAuthFlow = false
    @Published var currentCoordinate: CLLocationCoordinate2D?
    @Published var locationState: LocationGateState = .idle
    @Published var gridMessages: [ChatMessage] = []
    @Published var profileMessages: [ChatMessage] = []
    @Published var draftMessage = ""
    @Published var replyTo: ChatMessage?
    @Published var topLevelSort: TopLevelSortOption = .likes
    @Published var heatmapCounts: [String: Int] = [:]

    let backend: VrydBackend
    let locationManager = LocationManager()
    private(set) var activeUser: UserProfile?
    private var lastLoadedCellID: String?
    private var usernameCheckTask: Task<Void, Never>?

    var displayUsername: String {
        let trimmed = activeUser?.username.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "@new_user" : "@\(trimmed)"
    }

    var needsUsername: Bool {
        guard let activeUser else { return false }
        return !activeUser.hasValidUsername
    }

    @discardableResult
    func enforceUsernameSetupIfNeeded() -> Bool {
        guard needsUsername else { return false }
        authFlowStep = .usernameSetup
        showingAuthFlow = true
        statusMessage = "Pick a username to continue."
        return true
    }

    init(backend: VrydBackend) {
        self.backend = backend
        locationManager.onLocation = { [weak self] coordinate in
            Task { @MainActor in
                guard let self else { return }
                let cellID = SpatialGrid.cellID(for: coordinate)
                let shouldReloadForCell = self.lastLoadedCellID != cellID

                self.currentCoordinate = coordinate
                self.locationState = .ready
                self.screen = .main

                guard shouldReloadForCell else { return }
                self.lastLoadedCellID = cellID
                await self.refreshGridData()
                await self.refreshHeatmapData()
            }
        }
        locationManager.onDenied = { [weak self] in
            Task { @MainActor in
                self?.locationState = .denied
                self?.statusMessage = "Location is off. Enable it in Settings to use grid features."
            }
        }
    }

    var activeCell: GridCell? {
        guard let coordinate = currentCoordinate else { return nil }
        return GridCell(coordinate: coordinate)
    }

    var topLevelMessages: [ChatMessage] {
        gridMessages.filter { $0.parentID == nil }
    }

    var sortedTopLevelMessages: [ChatMessage] {
        switch topLevelSort {
        case .likes:
            return topLevelMessages.sorted {
                if $0.score == $1.score {
                    return $0.createdAt > $1.createdAt
                }
                return $0.score > $1.score
            }
        case .newest:
            return topLevelMessages.sorted { $0.createdAt > $1.createdAt }
        case .oldest:
            return topLevelMessages.sorted { $0.createdAt < $1.createdAt }
        }
    }

    func replies(for parentID: UUID) -> [ChatMessage] {
        gridMessages.filter { $0.parentID == parentID }.sorted { $0.createdAt < $1.createdAt }
    }

    func flattenedReplies(for topLevelID: UUID) -> [ChatMessage] {
        let byID = Dictionary(uniqueKeysWithValues: gridMessages.map { ($0.id, $0) })
        return gridMessages
            .filter { message in
                guard message.id != topLevelID else { return false }
                return rootID(for: message, byID: byID) == topLevelID
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func replyCount(for topLevelID: UUID) -> Int {
        flattenedReplies(for: topLevelID).count
    }

    private func rootID(for message: ChatMessage, byID: [UUID: ChatMessage]) -> UUID? {
        var current: ChatMessage? = message
        while let parentID = current?.parentID {
            current = byID[parentID]
        }
        return current?.id
    }


    func depth(for message: ChatMessage) -> Int {
        let byID = Dictionary(uniqueKeysWithValues: gridMessages.map { ($0.id, $0) })
        var level = 0
        var current = message

        while let parentID = current.parentID, let parent = byID[parentID] {
            level += 1
            current = parent
        }

        return level
    }

    func signInWithApple(idToken: String, nonce: String) async {
        authBusy = true
        defer { authBusy = false }

        do {
            let user = try await backend.signInWithApple(idToken: idToken, nonce: nonce)
            activeUser = user
            if user.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                authFlowStep = .usernameSetup
                statusMessage = "Choose a username to finish creating your account."
                await validateUsernameAvailability()
            } else {
                showingAuthFlow = false
                authFlowStep = .signIn
                statusMessage = ""
                await refreshProfile()
                await refreshGridData()
            }
        } catch {
            statusMessage = userFacingErrorMessage(error)
        }
    }

    func completeUsernameSetup() async {
        guard let user = activeUser else { return }
        let trimmed = usernameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UsernameRules.isValid(trimmed) else {
            statusMessage = UsernameRules.helperText
            usernameAvailability = .unavailable
            return
        }

        authBusy = true
        defer { authBusy = false }

        do {
            let updated = try await backend.updateUsername(userID: user.id, username: trimmed)
            activeUser = updated
            showingAuthFlow = false
            authFlowStep = .signIn
            statusMessage = ""
            await refreshProfile()
            await refreshGridData()
        } catch {
            statusMessage = userFacingErrorMessage(error)
            usernameAvailability = .unavailable
        }
    }

    func handleUsernameDraftChanged() {
        usernameCheckTask?.cancel()
        usernameCheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.validateUsernameAvailability()
        }
    }

    func validateUsernameAvailability() async {
        let trimmed = usernameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            usernameAvailability = .idle
            statusMessage = ""
            return
        }

        guard UsernameRules.isValid(trimmed) else {
            usernameAvailability = .unavailable
            statusMessage = UsernameRules.helperText
            return
        }

        usernameAvailability = .checking
        do {
            let available = try await backend.isUsernameAvailable(trimmed)
            usernameAvailability = available ? .available : .unavailable
            statusMessage = available ? "" : BackendError.usernameTaken.localizedDescription
        } catch {
            usernameAvailability = .idle
            statusMessage = userFacingErrorMessage(error)
        }
    }

    func beginAuthFlow() {
        statusMessage = ""
        authFlowStep = .signIn
        usernameAvailability = .idle
        showingAuthFlow = true
    }

    func requestLocation() {
        locationState = .idle
        locationManager.requestAuthorizationAndStart()
    }

    func postMessage() async {
        guard
            let user = activeUser,
            let cell = activeCell,
            !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        let messageText = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let parentID = replyTo?.id

        do {
            let posted = try await backend.postMessage(messageText, in: cell, from: user, parentID: parentID)
            draftMessage = ""
            replyTo = nil

            if parentID == nil {
                gridMessages.insert(posted, at: 0)
            } else {
                gridMessages.append(posted)
            }
            profileMessages.insert(posted, at: 0)

            let localCellID = cell.id.split(separator: "_").first.map(String.init) ?? ""
            if !localCellID.isEmpty {
                heatmapCounts[localCellID, default: 0] += 1
            }

            Task {
                await refreshGridData()
                await refreshProfile()
                await refreshHeatmapData()
            }
        } catch {
            statusMessage = userFacingErrorMessage(error)
        }
    }

    func vote(_ message: ChatMessage, value: Int) async {
        guard let user = activeUser else { return }
        let nextVote: Int? = message.userVote == value ? nil : value
        do {
            try await backend.vote(messageID: message.id, by: user.id, value: nextVote)
            await refreshGridData()
            await refreshHeatmapData()
        } catch {
            statusMessage = userFacingErrorMessage(error)
        }
    }

    func delete(_ message: ChatMessage) async {
        guard let user = activeUser else { return }
        do {
            try await backend.delete(messageID: message.id, by: user.id)
            await refreshGridData()
            await refreshProfile()
            await refreshHeatmapData()
        } catch {
            statusMessage = userFacingErrorMessage(error)
        }
    }

    func deleteAccount() async {
        guard let user = activeUser else { return }
        do {
            try await backend.deleteAccount(userID: user.id)
            activeUser = nil
            usernameDraft = ""
            draftMessage = ""
            gridMessages = []
            profileMessages = []
            heatmapCounts = [:]
            screen = .main
            statusMessage = "Account deleted."
        } catch {
            statusMessage = userFacingErrorMessage(error)
        }
    }

    func refreshGridData() async {
        guard let cell = activeCell, let user = activeUser else { return }
        do {
            gridMessages = try await backend.fetchMessages(in: cell, viewerID: user.id)
        } catch {
            statusMessage = userFacingErrorMessage(error)
        }
    }

    func refreshProfile() async {
        guard let user = activeUser else { return }
        do {
            profileMessages = try await backend.fetchProfileMessages(for: user.id)
        } catch {
            statusMessage = userFacingErrorMessage(error)
        }
    }

    func refreshHeatmapData() async {
        guard let coordinate = currentCoordinate else { return }
        do {
            heatmapCounts = try await backend.fetchDailyCellCounts(near: coordinate, radiusMeters: 750, date: .now)
        } catch {
            statusMessage = userFacingErrorMessage(error)
        }
    }

    func bootstrap() {
        requestLocation()
        Task {
            do {
                if let user = try await backend.currentUserProfile() {
                    activeUser = user
                }
            } catch {
                statusMessage = userFacingErrorMessage(error)
            }
        }
    }

    private func userFacingErrorMessage(_ error: Error) -> String {
        if let backendError = error as? BackendError {
            if case .serverUnavailable = backendError {
                return "Could not connect to Supabase. Confirm SUPABASE_URL + SUPABASE_ANON_KEY (or SUPABASE_KEY) are set on the app target Info.plist."
            }
            return backendError.localizedDescription
        }

        return "Server error. Please try again."
    }
}

/// Thin CLLocationManager wrapper that exposes closure-based callbacks.
final class LocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onLocation: ((CLLocationCoordinate2D) -> Void)?
    var onDenied: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 15
    }

    func requestAuthorizationAndStart() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            onDenied?()
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        onLocation?(location.coordinate)
    }
}
