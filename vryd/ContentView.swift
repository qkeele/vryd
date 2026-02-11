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
    @Published var heatmapCounts: [String: Int] = [:]

    let backend: VrydBackend
    let locationManager = LocationManager()
    private(set) var activeUser: UserProfile?

    var displayUsername: String {
        let trimmed = activeUser?.username.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "@new_user" : "@\(trimmed)"
    }

    init(backend: VrydBackend = LiveVrydBackend()) {
        self.backend = backend
        locationManager.onLocation = { [weak self] coordinate in
            Task { @MainActor in
                self?.currentCoordinate = coordinate
                self?.locationState = .ready
                self?.screen = .main
                await self?.refreshGridData()
                await self?.refreshHeatmapData()
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
            await refreshHeatmapData()
        } catch {
            statusMessage = "Could not send comment."
        }
    }

    func like(_ message: ChatMessage) async {
        guard let user = activeUser else { return }
        do {
            try await backend.like(messageID: message.id, by: user.id)
            await refreshGridData()
            await refreshHeatmapData()
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
            await refreshHeatmapData()
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
            heatmapCounts = [:]
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

    func refreshHeatmapData() async {
        guard let coordinate = currentCoordinate else { return }
        do {
            heatmapCounts = try await backend.fetchDailyCellCounts(near: coordinate, radiusMeters: 2_500, date: .now)
        } catch {
            statusMessage = "Could not load heatmap data."
        }
    }
}

final class LocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var lastDeliveredCellID: String?
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
        let cellID = SpatialGrid.cellID(for: location.coordinate)
        guard lastDeliveredCellID != cellID else { return }
        lastDeliveredCellID = cellID
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
                GridMapView(center: coordinate, heatmapCounts: viewModel.heatmapCounts)
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
        .fullScreenCover(isPresented: $showingGridChat) {
            GridChatSheet(viewModel: viewModel)
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
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.black)
                }
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
    @State private var pushNotificationsEnabled = true
    @State private var privateAccountEnabled = false
    @State private var darkMapEnabled = true

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

                        Spacer()

                        Button(action: {}) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.black)
                                .frame(width: 38, height: 38)
                                .background(Color.black.opacity(0.08))
                                .clipShape(Circle())
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Settings")
                            .font(.headline)

                        Toggle("Push notifications", isOn: $pushNotificationsEnabled)
                        Toggle("Private account", isOn: $privateAccountEnabled)
                        Toggle("Dark grid style", isOn: $darkMapEnabled)
                    }
                    .padding(16)
                    .background(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.black.opacity(0.12), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

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
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.black)
                }
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

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.showsUserLocation = true
        map.pointOfInterestFilter = .excludingAll
        map.delegate = context.coordinator
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.isScrollEnabled = false
        map.isZoomEnabled = true
        map.mapType = .standard
        map.userTrackingMode = .follow
        map.setRegion(MKCoordinateRegion(center: center, latitudinalMeters: 120, longitudinalMeters: 120), animated: false)
        map.cameraBoundary = MKMapView.CameraBoundary(coordinateRegion: MKCoordinateRegion(center: center, latitudinalMeters: 5_000, longitudinalMeters: 5_000))
        map.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 65, maxCenterCoordinateDistance: 5_500)
        return map
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        mapView.cameraBoundary = MKMapView.CameraBoundary(coordinateRegion: MKCoordinateRegion(center: center, latitudinalMeters: 5_000, longitudinalMeters: 5_000))
        if mapView.userTrackingMode != .follow {
            mapView.userTrackingMode = .follow
        }

        let overlays = context.coordinator.overlays(
            active: center,
            visibleMeters: max(mapView.region.span.latitudeDelta * 111_000, 100),
            heatmapCounts: heatmapCounts
        )
        context.coordinator.apply(overlays: overlays, to: mapView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var overlaySignature: String = ""

        func overlays(active coordinate: CLLocationCoordinate2D, visibleMeters: Double, heatmapCounts: [String: Int]) -> [MKPolygon] {
            let activeIndices = SpatialGrid.cellIndices(for: coordinate)
            let showHeatmap = visibleMeters >= 1_200
            let radius = showHeatmap ? 25 : 2
            var result: [MKPolygon] = []

            for y in (activeIndices.y - radius)...(activeIndices.y + radius) {
                for x in (activeIndices.x - radius)...(activeIndices.x + radius) {
                    let points = SpatialGrid.corners(forX: x, y: y)
                    let polygon = HeatPolygon(coordinates: points, count: points.count)
                    polygon.cellID = SpatialGrid.cellID(x: x, y: y)
                    polygon.isActive = (x == activeIndices.x && y == activeIndices.y)
                    let count = heatmapCounts[polygon.cellID] ?? 0
                    if showHeatmap {
                        polygon.intensity = count
                        polygon.showActivityDot = count > 0 && !polygon.isActive
                    }
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

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polygon = overlay as? HeatPolygon else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolygonRenderer(polygon: polygon)

            if polygon.isActive {
                renderer.fillColor = UIColor.white.withAlphaComponent(0.95)
                renderer.strokeColor = UIColor.white
                renderer.lineWidth = 2.4
            } else {
                renderer.fillColor = UIColor.black.withAlphaComponent(0.55)
                renderer.strokeColor = UIColor.black.withAlphaComponent(0.85)
                renderer.lineWidth = 0.8
            }

            if polygon.showActivityDot {
                let dotted = HeatPolygonRenderer(polygon: polygon)
                dotted.fillColor = renderer.fillColor
                dotted.strokeColor = renderer.strokeColor
                dotted.lineWidth = renderer.lineWidth
                return dotted
            }

            return renderer
        }
    }
}

final class HeatPolygon: MKPolygon, @unchecked Sendable {
    var cellID: String = ""
    var intensity: Int = 0
    var isActive: Bool = false
    var showActivityDot: Bool = false

    var signaturePart: String {
        "\(cellID):\(intensity):\(isActive ? 1 : 0):\(showActivityDot ? 1 : 0)"
    }
}


final class HeatPolygonRenderer: MKPolygonRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        super.draw(mapRect, zoomScale: zoomScale, in: context)
        guard let polygon = overlay as? HeatPolygon, polygon.showActivityDot else { return }

        let polygonPoints = polygon.points()
        let pointCount = polygon.pointCount
        guard pointCount > 0 else { return }

        var minPoint = point(for: polygonPoints[0])
        var maxPoint = minPoint

        for idx in 1..<pointCount {
            let projected = point(for: polygonPoints[idx])
            minPoint.x = min(minPoint.x, projected.x)
            minPoint.y = min(minPoint.y, projected.y)
            maxPoint.x = max(maxPoint.x, projected.x)
            maxPoint.y = max(maxPoint.y, projected.y)
        }

        let rect = CGRect(x: minPoint.x, y: minPoint.y, width: maxPoint.x - minPoint.x, height: maxPoint.y - minPoint.y)
        let diameter = max(4, min(rect.width, rect.height) * 0.24)
        let dotRect = CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter)

        context.saveGState()
        context.setFillColor(UIColor.white.cgColor)
        context.fillEllipse(in: dotRect)
        context.restoreGState()
    }
}

#Preview {
    ContentView()
}
