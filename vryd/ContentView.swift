import SwiftUI
import MapKit
import CoreLocation

@MainActor
final class AppViewModel: ObservableObject {
    enum Screen {
        case signIn
        case username
        case location
        case main
    }

    enum LocationGateState {
        case idle
        case denied
        case ready
    }

    @Published var screen: Screen = .signIn
    @Published var statusMessage = ""
    @Published var usernameDraft = ""
    @Published var currentCoordinate: CLLocationCoordinate2D?
    @Published var locationState: LocationGateState = .idle
    @Published var gridMessages: [ChatMessage] = []
    @Published var profileMessages: [ChatMessage] = []
    @Published var draftMessage = ""
    @Published var replyTo: ChatMessage?

    let backend: VrydBackend
    let locationManager = LocationManager()
    private(set) var activeUser: UserProfile?

    init(backend: VrydBackend = LiveVrydBackend()) {
        self.backend = backend
        locationManager.onLocation = { [weak self] coordinate in
            Task { @MainActor in
                self?.currentCoordinate = coordinate
                self?.locationState = .ready
                self?.screen = .main
                await self?.refreshGridData()
            }
        }
        locationManager.onDenied = { [weak self] in
            Task { @MainActor in
                self?.locationState = .denied
                self?.statusMessage = "Location is required to see your nearby grid."
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
        do {
            let user = try await backend.signInWithApple()
            activeUser = user
            screen = .username
        } catch {
            statusMessage = "Apple sign in failed."
        }
    }

    func finishUsername() async {
        guard let user = activeUser else { return }
        do {
            let updated = try await backend.updateUsername(userID: user.id, username: usernameDraft)
            activeUser = updated
            screen = .location
        } catch {
            statusMessage = error.localizedDescription
        }
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
        } catch {
            statusMessage = "Could not send comment."
        }
    }

    func like(_ message: ChatMessage) async {
        guard let user = activeUser else { return }
        do {
            try await backend.like(messageID: message.id, by: user.id)
            await refreshGridData()
        } catch {
            statusMessage = "Could not like comment."
        }
    }

    func delete(_ message: ChatMessage) async {
        guard let user = activeUser else { return }
        do {
            try await backend.delete(messageID: message.id, by: user.id)
            await refreshGridData()
            await refreshProfile()
        } catch {
            statusMessage = "Could not delete comment."
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
            screen = .signIn
            statusMessage = "Account deleted."
        } catch {
            statusMessage = "Could not delete account."
        }
    }

    func refreshGridData() async {
        guard let cell = activeCell, let user = activeUser else { return }
        do {
            gridMessages = try await backend.fetchMessages(in: cell, viewerID: user.id)
        } catch {
            statusMessage = "Could not load comments."
        }
    }

    func refreshProfile() async {
        guard let user = activeUser else { return }
        do {
            profileMessages = try await backend.fetchProfileMessages(for: user.id)
        } catch {
            statusMessage = "Could not load profile comments."
        }
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

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()
    @State private var showingGridChat = false
    @State private var showingProfile = false

    var body: some View {
        Group {
            switch viewModel.screen {
            case .signIn:
                AppleSignInView(viewModel: viewModel)
            case .username:
                UsernameOnboardingView(viewModel: viewModel)
            case .location:
                LocationPromptView(viewModel: viewModel)
            case .main:
                mapScreen
            }
        }
    }

    private var mapScreen: some View {
        ZStack(alignment: .bottom) {
            if let coordinate = viewModel.currentCoordinate {
                GridMapView(center: coordinate)
                    .ignoresSafeArea()
            }

            EdgeFadeOverlay()
                .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    FloatingCircleButton(systemName: "person.fill") { showingProfile = true }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer()

                FloatingCircleButton(systemName: "bubble.left.and.bubble.right.fill") { showingGridChat = true }
                    .padding(.bottom, 26)
            }
        }
        .sheet(isPresented: $showingGridChat) {
            GridChatSheet(viewModel: viewModel)
                .presentationDetents([.fraction(0.38), .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingProfile) {
            ProfileView(viewModel: viewModel)
        }
    }
}

struct AppleSignInView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("VRYD")
                .font(.system(size: 48, weight: .heavy, design: .rounded))
            Text("Talk to people in your exact 100m square.")
                .foregroundStyle(.secondary)

            Button(action: { Task { await viewModel.signInWithApple() } }) {
                Label("Sign in with Apple", systemImage: "apple.logo")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.black)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.top, 14)

            if !viewModel.statusMessage.isEmpty {
                Text(viewModel.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(20)
    }
}

struct UsernameOnboardingView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a username")
                .font(.title.bold())
            Text("Instagram-style rules")
                .foregroundStyle(.secondary)

            TextField("username", text: $viewModel.usernameDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            Text(UsernameRules.helperText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("Continue") { Task { await viewModel.finishUsername() } }
                .buttonStyle(.borderedProminent)
                .disabled(!UsernameRules.isValid(viewModel.usernameDraft))

            if !viewModel.statusMessage.isEmpty {
                Text(viewModel.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(20)
    }
}

struct LocationPromptView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "location.circle.fill")
                .font(.system(size: 46))
            Text("Enable location")
                .font(.title2.weight(.bold))
            Text("We only use your location to compute your current grid cell.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Allow Location", action: viewModel.requestLocation)
                .buttonStyle(.borderedProminent)

            if viewModel.locationState == .denied {
                Text("Location is required for the map experience. Enable it in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(20)
    }
}

struct EdgeFadeOverlay: View {
    var body: some View {
        HStack {
            LinearGradient(colors: [Color.white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 42)
            Spacer()
            LinearGradient(colors: [.clear, Color.white.opacity(0.55)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 42)
        }
    }
}

struct FloatingCircleButton: View {
    let systemName: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 56, height: 56)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
        .shadow(radius: 8)
    }
}

struct GridChatSheet: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Grid \(SpatialGrid.cellID(for: viewModel.currentCoordinate ?? CLLocationCoordinate2D()))")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal)

            ScrollView {
                LazyVStack(spacing: 8) {
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
                                .padding(.leading, 22)
                            }
                        }
                    }

                    if viewModel.gridMessages.isEmpty {
                        Text("No comments in this square yet.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 16)
                    }
                }
                .padding(.horizontal)
            }

            VStack(spacing: 6) {
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
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                    Button("Post") { Task { await viewModel.postMessage() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 10)
        }
        .task { await viewModel.refreshGridData() }
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
            HStack {
                Text("u/\(message.author)")
                    .font(.subheadline.bold())
                Spacer()
                Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(message.text)
            HStack(spacing: 14) {
                Button(action: likeAction) {
                    Label("\(message.likeCount)", systemImage: message.userHasLiked ? "heart.fill" : "heart")
                }
                .buttonStyle(.plain)
                .foregroundStyle(message.userHasLiked ? .pink : .secondary)
                .disabled(message.userHasLiked)

                if message.parentID == nil {
                    Button("Reply", action: replyAction)
                        .font(.caption)
                        .buttonStyle(.plain)
                }

                if canDelete {
                    Button("Delete", role: .destructive, action: deleteAction)
                        .font(.caption)
                }
            }
            .font(.caption)
        }
        .padding(12)
        .background(.gray.opacity(0.11))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ProfileView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDeleteAccount = false

    var body: some View {
        NavigationStack {
            List {
                Section("Your comments") {
                    ForEach(viewModel.profileMessages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.text)
                            Text(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button("Delete Account", role: .destructive) {
                        confirmDeleteAccount = true
                    }
                }
            }
            .navigationTitle("Profile")
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

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.showsUserLocation = true
        map.pointOfInterestFilter = .excludingAll
        map.delegate = context.coordinator
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.isScrollEnabled = false
        map.isZoomEnabled = false
        map.mapType = .satellite
        return map
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let region = MKCoordinateRegion(center: center, latitudinalMeters: 150, longitudinalMeters: 150)
        mapView.setRegion(region, animated: true)

        let overlays = context.coordinator.gridOverlays(active: center, radius: 2)
        mapView.removeOverlays(mapView.overlays)
        mapView.addOverlays(overlays)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func gridOverlays(active coordinate: CLLocationCoordinate2D, radius: Int) -> [MKPolygon] {
            let active = SpatialGrid.cellIndices(for: coordinate)
            var result: [MKPolygon] = []

            for y in (active.y - radius)...(active.y + radius) {
                for x in (active.x - radius)...(active.x + radius) {
                    let points = SpatialGrid.corners(forX: x, y: y)
                    let polygon = MKPolygon(coordinates: points, count: points.count)
                    polygon.title = (x == active.x && y == active.y) ? "active" : "grid"
                    result.append(polygon)
                }
            }
            return result
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polygon = overlay as? MKPolygon else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolygonRenderer(polygon: polygon)
            if polygon.title == "active" {
                renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.35)
                renderer.strokeColor = UIColor.systemBlue
                renderer.lineWidth = 2.5
            } else {
                renderer.fillColor = UIColor.clear
                renderer.strokeColor = UIColor.white.withAlphaComponent(0.35)
                renderer.lineWidth = 1
            }
            return renderer
        }
    }
}

#Preview {
    ContentView()
}
