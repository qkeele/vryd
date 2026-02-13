import SwiftUI
import MapKit
import CoreLocation
import Combine
import AuthenticationServices
import CryptoKit
import Security

@MainActor
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

@MainActor
struct ContentView: View {
    @StateObject private var viewModel: AppViewModel
    @State private var showingGridChat = false
    @State private var showingProfile = false

    init(backend: VrydBackend) {
        _viewModel = StateObject(wrappedValue: AppViewModel(backend: backend))
    }

    var body: some View {
        mapScreen
        .task { viewModel.bootstrap() }
    }

    private var mapScreen: some View {
        ZStack(alignment: .bottom) {
            if let coordinate = viewModel.currentCoordinate {
                GridMapView(center: coordinate, heatmapCounts: viewModel.heatmapCounts)
                    .ignoresSafeArea()
            } else {
                Color.white
                    .ignoresSafeArea()
            }

            EdgeFadeOverlay()
                .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    FloatingCircleButton(systemName: "person.fill") {
                        guard viewModel.activeUser != nil else {
                            viewModel.beginAuthFlow()
                            return
                        }
                        guard !viewModel.enforceUsernameSetupIfNeeded() else { return }
                        showingProfile = true
                    }
                    .disabled(viewModel.currentCoordinate == nil)
                    .opacity(viewModel.currentCoordinate == nil ? 0.45 : 1)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer()

                FloatingCircleButton(systemName: "bubble.left.and.bubble.right.fill") {
                    guard viewModel.activeUser != nil else {
                        viewModel.beginAuthFlow()
                        return
                    }
                    guard !viewModel.enforceUsernameSetupIfNeeded() else { return }
                    showingGridChat = true
                }
                    .disabled(viewModel.currentCoordinate == nil)
                    .opacity(viewModel.currentCoordinate == nil ? 0.45 : 1)
                    .padding(.bottom, 26)
            }

            if viewModel.locationState == .denied {
                LocationUnavailableBanner(retryAction: viewModel.requestLocation)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 100)
            }
        }
        .fullScreenCover(isPresented: $viewModel.showingAuthFlow) {
            AuthOnboardingFlowView(viewModel: viewModel)
        }
        .fullScreenCover(isPresented: $showingGridChat) {
            GridChatSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showingProfile) {
            ProfileView(viewModel: viewModel)
        }
    }
}

struct AuthOnboardingFlowView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                if viewModel.authFlowStep == .signIn {
                    Text("Sign in")
                        .font(.title.bold())

                    Text("Use Apple to sign in to your existing account, or continue to create one.")
                        .foregroundStyle(.secondary)

                    SignInWithAppleButton(.signIn, onRequest: { request in
                        AppleSignInCoordinator.configure(request: request)
                    }, onCompletion: { result in
                        Task { await AppleSignInCoordinator.handle(result: result, viewModel: viewModel) }
                    })
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 50)
                    .disabled(viewModel.authBusy)
                } else {
                    Text("Choose a username")
                        .font(.title.bold())

                    Text("This is only needed once for new accounts.")
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 10) {
                        TextField("username", text: $viewModel.usernameDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Color.white)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Color.black.opacity(0.15), lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .onChange(of: viewModel.usernameDraft) { _, _ in
                                viewModel.handleUsernameDraftChanged()
                            }

                        HStack(spacing: 8) {
                            UsernameAvailabilityIndicator(state: viewModel.usernameAvailability)
                            Text(UsernameRules.helperText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Button(action: { Task { await viewModel.completeUsernameSetup() } }) {
                            HStack {
                                Spacer()
                                Text(viewModel.authBusy ? "Saving..." : "Continue")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                Spacer()
                            }
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .background(Color.black)
                        .clipShape(Capsule())
                        .disabled(viewModel.authBusy || viewModel.usernameAvailability != .available)
                    }
                    .padding(16)
                    .background(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.black.opacity(0.12), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }

                if !viewModel.statusMessage.isEmpty {
                    Text(viewModel.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Spacer()
            }
            .padding(20)
            .background(Color.white)
            .toolbar {
                CloseToolbarButton { dismiss() }
            }
        }
    }
}

struct UsernameAvailabilityIndicator: View {
    let state: AppViewModel.UsernameAvailability

    var body: some View {
        switch state {
        case .idle:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .available:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .unavailable:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}

private enum AppleSignInCoordinator {
    static func configure(request: ASAuthorizationAppleIDRequest) {
        let rawNonce = randomNonceString()
        AppleSignInState.shared.currentNonce = rawNonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(rawNonce)
    }

    @MainActor
    static func handle(result: Result<ASAuthorization, Error>, viewModel: AppViewModel) async {
        switch result {
        case .failure(let error):
            viewModel.statusMessage = error.localizedDescription
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                viewModel.statusMessage = "Invalid Apple sign-in response."
                return
            }

            guard
                let nonce = AppleSignInState.shared.currentNonce,
                let tokenData = credential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8)
            else {
                viewModel.statusMessage = "Missing Apple identity token."
                return
            }

            await viewModel.signInWithApple(idToken: idToken, nonce: nonce)
            AppleSignInState.shared.currentNonce = nil
        }
    }

    private static func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length

        while remainingLength > 0 {
            var random: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            guard status == errSecSuccess else {
                fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(status)")
            }

            if Int(random) < charset.count {
                result.append(charset[Int(random)])
                remainingLength -= 1
            }
        }

        return result
    }
}

private final class AppleSignInState {
    static let shared = AppleSignInState()
    var currentNonce: String?

    private init() {}
}

struct LocationPromptView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "location.slash.circle.fill")
                .font(.system(size: 46))
            Text("Location needed")
                .font(.title2.weight(.bold))

            Text("Please share your location to use Vryd.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Try Again", action: viewModel.requestLocation)
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color.black)
                .clipShape(Capsule())

            if viewModel.locationState == .denied {
                Text("Location access is currently off. Enable location permissions for Vryd in Settings and try again.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(20)
    }
}

struct LocationUnavailableBanner: View {
    var retryAction: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("Location unavailable")
                .font(.headline)
            Text("Turn on location access in Settings to interact with nearby posts.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Retry", action: retryAction)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black)
                .clipShape(Capsule())
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color.white)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.black.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct EdgeFadeOverlay: View {
    var body: some View {
        ZStack {
            VStack {
                LinearGradient(colors: [Color.white.opacity(0.92), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 90)
                Spacer()
                LinearGradient(colors: [.clear, Color.white.opacity(0.92)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 90)
            }

            HStack {
                LinearGradient(colors: [Color.white.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 64)
                Spacer()
                LinearGradient(colors: [.clear, Color.white.opacity(0.9)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 64)
            }
        }
        .allowsHitTesting(false)
    }
}

struct FloatingCircleButton: View {
    let systemName: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 58, height: 58)
                .background(Color.white)
                .clipShape(Circle())
        }
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }
}

struct CloseToolbarButton: ToolbarContent {
    var action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Close", action: action)
                .foregroundStyle(.black)
        }
    }
}

struct GridChatSheet: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedThread: ChatMessage?

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Picker("Sort", selection: $viewModel.topLevelSort) {
                    ForEach(AppViewModel.TopLevelSortOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.sortedTopLevelMessages) { message in
                            Button {
                                selectedThread = message
                            } label: {
                                FlatCommentRow(
                                    message: message,
                                    canDelete: false,
                                    upvoteAction: {},
                                    downvoteAction: {},
                                    replyAction: {},
                                    deleteAction: {},
                                    showReplyCount: viewModel.replyCount(for: message.id),
                                    compact: true
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        if viewModel.gridMessages.isEmpty {
                            Text("Nothing to see here yet.")
                                .foregroundStyle(.secondary)
                                .padding(.top, 16)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                composer
            }
            .background(Color.white)
            .toolbar {
                CloseToolbarButton { dismiss() }
            }
        }
        .sheet(item: $selectedThread) { thread in
            ThreadDetailView(viewModel: viewModel, topLevel: thread)
        }
        .task {
            await viewModel.refreshGridData()
            await viewModel.refreshHeatmapData()
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Write a post…", text: $viewModel.draftMessage, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.black.opacity(0.15), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Button("Post") { Task { await viewModel.postMessage() } }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color.black)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}

struct ThreadDetailView: View {
    enum CommentSort: String, CaseIterable, Identifiable {
        case top = "Top"
        case newest = "Newest"
        case oldest = "Oldest"
        var id: String { rawValue }
    }

    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    let topLevel: ChatMessage
    @State private var commentSort: CommentSort = .top
    @State private var visibleReplyCountByParent: [UUID: Int] = [:]

    private let pageSize = 10

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                FlatCommentRow(message: topLevel, canDelete: viewModel.activeUser?.id == topLevel.authorID, upvoteAction: { Task { await viewModel.vote(topLevel, value: 1) } }, downvoteAction: { Task { await viewModel.vote(topLevel, value: -1) } }, replyAction: {
                    viewModel.replyTo = topLevel
                    viewModel.draftMessage = "@\(resolvedAuthorName(for: topLevel)) "
                }, deleteAction: { Task { await viewModel.delete(topLevel) } }, showReplyCount: viewModel.replyCount(for: topLevel.id), compact: true)
                .padding(.horizontal, 16)

                Picker("Sort comments", selection: $commentSort) {
                    ForEach(CommentSort.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        nestedReplies(parentID: topLevel.id, depth: 1)
                    }
                    .padding(.horizontal, 16)
                }

                composer
            }
            .toolbar {
                CloseToolbarButton { dismiss() }
            }
        }
    }

    @ViewBuilder
    private func nestedReplies(parentID: UUID, depth: Int) -> some View {
        let replies = sortedReplies(for: parentID)
        let visibleCount = visibleReplyCountByParent[parentID] ?? 0

        if visibleCount == 0, !replies.isEmpty {
            Button("Show \(min(pageSize, replies.count)) of \(replies.count) repl\(replies.count == 1 ? "y" : "ies")") {
                visibleReplyCountByParent[parentID] = min(pageSize, replies.count)
            }
            .font(.caption)
        }

        ForEach(Array(replies.prefix(visibleCount))) { reply in
            FlatCommentRow(message: reply, canDelete: viewModel.activeUser?.id == reply.authorID, upvoteAction: { Task { await viewModel.vote(reply, value: 1) } }, downvoteAction: { Task { await viewModel.vote(reply, value: -1) } }, replyAction: {
                viewModel.replyTo = reply
                viewModel.draftMessage = "@\(resolvedAuthorName(for: reply)) "
            }, deleteAction: { Task { await viewModel.delete(reply) } }, showReplyCount: nil, compact: true, indentation: depth)
            nestedReplies(parentID: reply.id, depth: depth + 1)
        }

        if replies.count > visibleCount {
            Button("Show \(min(pageSize, replies.count - visibleCount)) more") {
                visibleReplyCountByParent[parentID] = min(replies.count, visibleCount + pageSize)
            }
            .font(.caption)
        }
    }

    private func sortedReplies(for parentID: UUID) -> [ChatMessage] {
        let replies = viewModel.replies(for: parentID)
        switch commentSort {
        case .top:
            return replies.sorted { $0.score > $1.score }
        case .newest:
            return replies.sorted { $0.createdAt > $1.createdAt }
        case .oldest:
            return replies.sorted { $0.createdAt < $1.createdAt }
        }
    }

    private func resolvedAuthorName(for message: ChatMessage) -> String {
        let trimmed = message.author.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "unknown" ? "deleted" : trimmed
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let reply = viewModel.replyTo {
                HStack {
                    Text("Replying to @\(resolvedAuthorName(for: reply))")
                        .font(.caption)
                    Spacer()
                    Button("Cancel") { viewModel.replyTo = nil; viewModel.draftMessage = "" }
                        .font(.caption)
                }
                .padding(.horizontal, 16)
            }

            HStack(spacing: 10) {
                TextField("Write a reply…", text: $viewModel.draftMessage, axis: .vertical)
                    .lineLimit(1...3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.15)))
                Button("Reply") { Task { await viewModel.postMessage() } }
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }
}

struct FlatCommentRow: View {
    let message: ChatMessage
    let canDelete: Bool
    let upvoteAction: () -> Void
    let downvoteAction: () -> Void
    let replyAction: () -> Void
    let deleteAction: () -> Void
    let showReplyCount: Int?
    var compact = false
    var indentation = 0

    private var authorLabel: String {
        let trimmed = message.author.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "unknown" ? "[deleted]" : "@\(trimmed)"
    }

    private var relativeTime: String {
        let seconds = Int(Date().timeIntervalSince(message.createdAt))
        if seconds < 60 { return "\(max(1, seconds))s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 7 { return "\(days)d ago" }
        let weeks = days / 7
        if weeks < 52 { return "\(weeks)w ago" }
        return "\(weeks / 52)y ago"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(authorLabel) • \(relativeTime)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(message.text)
                .font(compact ? .subheadline : .body)

            HStack(spacing: 12) {
                Button(action: upvoteAction) {
                    Label("\(message.upvoteCount)", systemImage: message.userVote == 1 ? "arrow.up.circle.fill" : "arrow.up.circle")
                }
                .buttonStyle(.plain)

                Button(action: downvoteAction) {
                    Label("\(message.downvoteCount)", systemImage: message.userVote == -1 ? "arrow.down.circle.fill" : "arrow.down.circle")
                }
                .buttonStyle(.plain)

                Text("Score \(message.score)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Reply", action: replyAction)
                    .font(.caption)
                    .buttonStyle(.plain)

                if let showReplyCount {
                    Text("\(showReplyCount) repl\(showReplyCount == 1 ? "y" : "ies")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(.leading, CGFloat(indentation * 12))
        .padding(8)
        .background(Color.black.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contextMenu {
            if canDelete {
                Button("Delete", role: .destructive, action: deleteAction)
            }
        }
    }
}

struct ProfileView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDeleteAccount = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(viewModel.displayUsername)
                                .font(.title2.weight(.bold))
                            Text("Your local social profile")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your messages")
                            .font(.headline)

                        if viewModel.profileMessages.isEmpty {
                            Text("Nothing to see here yet.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(viewModel.profileMessages) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(message.text)
                                    .foregroundStyle(.black)
                                Text(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.black.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                    .padding(16)
                    .background(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.black.opacity(0.12), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    Button("Delete Account", role: .destructive) {
                        confirmDeleteAccount = true
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(16)
            }
            .background(Color.white)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                CloseToolbarButton { dismiss() }
            }
            .task { await viewModel.refreshProfile() }
            .alert("Delete account?", isPresented: $confirmDeleteAccount) {
                Button("Delete", role: .destructive) {
                    Task {
                        await viewModel.deleteAccount()
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes your account, your messages, and your likes.")
            }
        }
    }
}

struct GridMapView: UIViewRepresentable {
    let center: CLLocationCoordinate2D
    let heatmapCounts: [String: Int]

    private let defaultDistance: CLLocationDistance = 140
    private let minDistance: CLLocationDistance = 100
    private let maxDistance: CLLocationDistance = 1290
    private let boundaryDistance: CLLocationDistance = 900
    private let heatmapThresholdDistance: CLLocationDistance = 280

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        let anchoredCenter = Self.cellCenterCoordinate(for: center)
        map.showsUserLocation = true
        map.pointOfInterestFilter = .excludingAll
        map.delegate = context.coordinator
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.isScrollEnabled = false
        map.isZoomEnabled = true
        map.mapType = .satellite
        map.userTrackingMode = .none
        map.setRegion(MKCoordinateRegion(center: anchoredCenter, latitudinalMeters: defaultDistance, longitudinalMeters: defaultDistance), animated: false)
        map.cameraBoundary = MKMapView.CameraBoundary(coordinateRegion: MKCoordinateRegion(center: anchoredCenter, latitudinalMeters: boundaryDistance, longitudinalMeters: boundaryDistance))
        map.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: minDistance, maxCenterCoordinateDistance: maxDistance)
        context.coordinator.parent = self
        return map
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        let anchoredCenter = Self.cellCenterCoordinate(for: center)
        mapView.cameraBoundary = MKMapView.CameraBoundary(coordinateRegion: MKCoordinateRegion(center: anchoredCenter, latitudinalMeters: boundaryDistance, longitudinalMeters: boundaryDistance))
        context.coordinator.syncCamera(on: mapView, userCenter: center, defaultDistance: defaultDistance)
        context.coordinator.refreshOverlays(on: mapView, center: center, heatmapCounts: heatmapCounts)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }


    private static func cellCenterCoordinate(for coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let indices = SpatialGrid.cellIndices(for: coordinate)
        let corners = SpatialGrid.corners(forX: indices.x, y: indices.y)
        let latitude = corners.map(\.latitude).reduce(0, +) / Double(corners.count)
        let longitude = corners.map(\.longitude).reduce(0, +) / Double(corners.count)
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: GridMapView
        private var overlaySignature: String = ""
        private var hasInitializedCamera = false
        private var lastAnchoredCellID: String?
        private var isRecenteringCamera = false

        init(parent: GridMapView) {
            self.parent = parent
        }


        func syncCamera(on mapView: MKMapView, userCenter: CLLocationCoordinate2D, defaultDistance: CLLocationDistance) {
            let anchoredCenter = GridMapView.cellCenterCoordinate(for: userCenter)
            let currentCellID = SpatialGrid.cellID(for: userCenter)

            if !hasInitializedCamera {
                let region = MKCoordinateRegion(center: anchoredCenter, latitudinalMeters: defaultDistance, longitudinalMeters: defaultDistance)
                mapView.setRegion(region, animated: false)
                hasInitializedCamera = true
                self.lastAnchoredCellID = currentCellID
                return
            }

            guard let previousCellID = self.lastAnchoredCellID else {
                self.lastAnchoredCellID = currentCellID
                return
            }

            let currentZoomDistance = mapView.camera.centerCoordinateDistance
            let clampedZoomDistance = max(parent.minDistance, min(currentZoomDistance, parent.maxDistance))

            if previousCellID == currentCellID {
                if abs(currentZoomDistance - clampedZoomDistance) > 0.5 {
                    mapView.camera.centerCoordinateDistance = clampedZoomDistance
                }
                return
            }

            self.lastAnchoredCellID = currentCellID
            recenterMap(on: mapView, to: anchoredCenter, zoomDistance: clampedZoomDistance, animated: true)
        }

        private func recenterMap(on mapView: MKMapView, to userCenter: CLLocationCoordinate2D, zoomDistance: CLLocationDistance, animated: Bool = false) {
            isRecenteringCamera = true
            mapView.setCenter(userCenter, animated: animated)
            mapView.camera.centerCoordinateDistance = zoomDistance
            isRecenteringCamera = false
        }

        func refreshOverlays(on mapView: MKMapView, center: CLLocationCoordinate2D, heatmapCounts: [String: Int]) {
            let showHeatmap = mapView.camera.centerCoordinateDistance >= parent.heatmapThresholdDistance
            let overlays = overlays(active: center, heatmapCounts: heatmapCounts, showHeatmap: showHeatmap)
            apply(overlays: overlays, to: mapView)
        }

        func overlays(active coordinate: CLLocationCoordinate2D, heatmapCounts: [String: Int], showHeatmap: Bool) -> [MKPolygon] {
            let activeIndices = SpatialGrid.cellIndices(for: coordinate)
            let visibleRadius = 5 // 11x11 visible interior centered on active cell
            let hiddenBufferCells = 2 // extra off-screen cells so swipes don't expose the grid edge
            let generationRadius = visibleRadius + hiddenBufferCells // 15x15 generated grid
            var result: [MKPolygon] = []

            for y in (activeIndices.y - generationRadius)...(activeIndices.y + generationRadius) {
                for x in (activeIndices.x - generationRadius)...(activeIndices.x + generationRadius) {
                    let points = SpatialGrid.corners(forX: x, y: y)
                    let polygon = HeatPolygon(coordinates: points, count: points.count)
                    let xOffset = x - activeIndices.x
                    let yOffset = y - activeIndices.y

                    polygon.cellID = SpatialGrid.cellID(x: x, y: y)
                    polygon.isActive = (x == activeIndices.x && y == activeIndices.y)
                    polygon.isVisible = abs(xOffset) <= visibleRadius && abs(yOffset) <= visibleRadius
                    polygon.hasComments = polygon.isVisible && showHeatmap && (heatmapCounts[polygon.cellID] ?? 0) > 0
                    result.append(polygon)
                }
            }
            return result
        }

        func apply(overlays: [MKPolygon], to mapView: MKMapView) {
            let signature = overlays.compactMap { ($0 as? HeatPolygon)?.signaturePart }.joined(separator: "|")
            guard signature != overlaySignature else { return }
            overlaySignature = signature
            mapView.removeOverlays(mapView.overlays)
            mapView.addOverlays(overlays)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard !isRecenteringCamera else { return }

            let anchoredCenter = GridMapView.cellCenterCoordinate(for: parent.center)
            let mapCenterOffset = MKMapPoint(mapView.centerCoordinate).distance(to: MKMapPoint(anchoredCenter))
            if mapCenterOffset > 2 {
                let clampedZoomDistance = max(parent.minDistance, min(mapView.camera.centerCoordinateDistance, parent.maxDistance))
                recenterMap(on: mapView, to: anchoredCenter, zoomDistance: clampedZoomDistance)
            }

            refreshOverlays(on: mapView, center: anchoredCenter, heatmapCounts: parent.heatmapCounts)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polygon = overlay as? HeatPolygon else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolygonRenderer(polygon: polygon)

            if !polygon.isVisible {
                renderer.fillColor = .clear
                renderer.strokeColor = .clear
                renderer.lineWidth = 0
            } else if polygon.isActive {
                renderer.fillColor = UIColor.white.withAlphaComponent(0.24)
                renderer.strokeColor = UIColor.white
                renderer.lineWidth = 3.8
            } else if polygon.hasComments {
                renderer.fillColor = .clear
                renderer.strokeColor = UIColor.systemGreen.withAlphaComponent(0.95)
                renderer.lineWidth = 1.6
            } else {
                renderer.fillColor = .clear
                renderer.strokeColor = UIColor.white.withAlphaComponent(0.9)
                renderer.lineWidth = 1.1
            }

            return renderer
        }
    }
}

final class HeatPolygon: MKPolygon, @unchecked Sendable {
    var cellID: String = ""
    var isActive: Bool = false
    var isVisible: Bool = true
    var hasComments: Bool = false

    var signaturePart: String {
        "\(cellID):\(isActive ? 1 : 0):\(isVisible ? 1 : 0):\(hasComments ? 1 : 0)"
    }
}
