import SwiftUI
import MapKit
import CoreLocation
import Combine

@MainActor
final class AppViewModel: ObservableObject {
    enum Screen {
        case main
    }

    enum AuthFlowStep {
        case username
        case appleSignIn
    }

    enum LocationGateState {
        case idle
        case denied
        case ready
    }

    @Published var screen: Screen = .main
    @Published var statusMessage = ""
    @Published var usernameDraft = ""
    @Published var authFlowStep: AuthFlowStep = .username
    @Published var showingAuthFlow = false
    @Published var currentCoordinate: CLLocationCoordinate2D?
    @Published var locationState: LocationGateState = .idle
    @Published var gridMessages: [ChatMessage] = []
    @Published var profileMessages: [ChatMessage] = []
    @Published var draftMessage = ""
    @Published var replyTo: ChatMessage?
    @Published var heatmapCounts: [String: Int] = [:]

    let backend: VrydBackend
    let locationManager = LocationManager()
    private(set) var activeUser: UserProfile?
    private var lastLoadedCellID: String?

    var displayUsername: String {
        let trimmed = activeUser?.username.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "@new_user" : "@\(trimmed)"
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

    func replies(for parentID: UUID) -> [ChatMessage] {
        gridMessages.filter { $0.parentID == parentID }.sorted { $0.createdAt < $1.createdAt }
    }

    func signInWithApple() async {
        let desiredUsername = usernameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UsernameRules.isValid(desiredUsername) else {
            statusMessage = UsernameRules.helperText
            return
        }

        do {
            guard try await backend.isUsernameAvailable(desiredUsername) else {
                statusMessage = BackendError.usernameTaken.localizedDescription
                return
            }

            let user = try await backend.signInWithApple()
            let updated = try await backend.updateUsername(userID: user.id, username: desiredUsername)
            activeUser = updated
            showingAuthFlow = false
            authFlowStep = .username
            statusMessage = ""
        } catch {
            statusMessage = userFacingErrorMessage(error)
        }
    }

    func continueToAppleStep() async {
        let trimmed = usernameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UsernameRules.isValid(trimmed) else {
            statusMessage = UsernameRules.helperText
            return
        }

        do {
            guard try await backend.isUsernameAvailable(trimmed) else {
                statusMessage = BackendError.usernameTaken.localizedDescription
                return
            }
            statusMessage = ""
            authFlowStep = .appleSignIn
        } catch {
            statusMessage = userFacingErrorMessage(error)
        }
    }

    func beginAuthFlow() {
        statusMessage = ""
        authFlowStep = .username
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

        do {
            _ = try await backend.postMessage(draftMessage, in: cell, from: user, parentID: replyTo?.id)
            draftMessage = ""
            replyTo = nil
            await refreshGridData()
            await refreshProfile()
            await refreshHeatmapData()
        } catch {
            statusMessage = userFacingErrorMessage(error)
        }
    }

    func like(_ message: ChatMessage) async {
        guard let user = activeUser else { return }
        do {
            try await backend.like(messageID: message.id, by: user.id)
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
                Text("Set up your account")
                    .font(.title.bold())

                Text("Choose a username to continue.")
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

                    Text(UsernameRules.helperText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if viewModel.authFlowStep == .username {
                        Button("Continue") { Task { await viewModel.continueToAppleStep() } }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.black)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                            .disabled(!UsernameRules.isValid(viewModel.usernameDraft.trimmingCharacters(in: .whitespacesAndNewlines)))
                    } else {
                        Text("Username locked in: @\(viewModel.usernameDraft)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Button(action: { Task { await viewModel.signInWithApple() } }) {
                            Label("Sign in with Apple", systemImage: "apple.logo")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.black)
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                    }
                }
                .padding(16)
                .background(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.black.opacity(0.12), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

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

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.topLevelMessages) { message in
                            VStack(alignment: .leading, spacing: 8) {
                                CommentCard(
                                    message: message,
                                    canDelete: viewModel.activeUser?.id == message.authorID,
                                    likeAction: { Task { await viewModel.like(message) } },
                                    replyAction: {
                                        viewModel.replyTo = message
                                        viewModel.draftMessage = "@\(message.author) "
                                    },
                                    deleteAction: { Task { await viewModel.delete(message) } }
                                )

                                ForEach(viewModel.replies(for: message.id)) { reply in
                                    CommentCard(
                                        message: reply,
                                        canDelete: viewModel.activeUser?.id == reply.authorID,
                                        likeAction: { Task { await viewModel.like(reply) } },
                                        replyAction: {},
                                        deleteAction: { Task { await viewModel.delete(reply) } }
                                    )
                                    .padding(.leading, 18)
                                }
                            }
                        }

                        if viewModel.gridMessages.isEmpty {
                            Text("No comments in this square yet.")
                                .foregroundStyle(.secondary)
                                .padding(.top, 16)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                VStack(spacing: 8) {
                    if let reply = viewModel.replyTo {
                        HStack {
                            Text("Replying to @\(reply.author)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") {
                                viewModel.replyTo = nil
                                viewModel.draftMessage = ""
                            }
                            .font(.caption)
                        }
                        .padding(.horizontal)
                    }

                    HStack(spacing: 10) {
                        TextField("Write a comment…", text: $viewModel.draftMessage, axis: .vertical)
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
                .background(Color.white)
            }
            .background(Color.white)
            .toolbar {
                CloseToolbarButton { dismiss() }
            }
        }
        .task {
            await viewModel.refreshGridData()
            await viewModel.refreshHeatmapData()
        }
    }
}

struct CommentCard: View {
    let message: ChatMessage
    let canDelete: Bool
    let likeAction: () -> Void
    let replyAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.text)
                .foregroundStyle(.black)
            HStack(spacing: 14) {
                Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(action: likeAction) {
                    Label("\(message.likeCount)", systemImage: message.userHasLiked ? "heart.fill" : "heart")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black)
                .disabled(message.userHasLiked)

                if message.parentID == nil {
                    Button("Reply", action: replyAction)
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.black)
                }

                Spacer()

                if canDelete {
                    Button("Delete", action: deleteAction)
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.black)
                }
            }
            .font(.caption)
        }
        .padding(14)
        .background(Color.white)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.black.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
                        Text("Your comments")
                            .font(.headline)

                        if viewModel.profileMessages.isEmpty {
                            Text("You haven’t posted any comments yet.")
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
                Text("This removes your account, your comments, and your likes.")
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
