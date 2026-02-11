import SwiftUI
import MapKit
import CoreLocation
internal import Combine

@MainActor
final class AppViewModel: ObservableObject {
    enum SessionState {
        case signedOut
        case signedIn(UserProfile)
    }

    enum LocationGateState {
        case loading
        case denied
        case ready
    }

    @Published var session: SessionState = .signedOut
    @Published var statusMessage = ""
    @Published var currentCoordinate: CLLocationCoordinate2D?
    @Published var currentCity = ""
    @Published var locationState: LocationGateState = .loading
    @Published var gridMessages: [ChatMessage] = []
    @Published var profileMessages: [ChatMessage] = []
    @Published var draftMessage = ""

    let backend: VrydBackend
    let locationManager = LocationManager()

    init(backend: VrydBackend = LiveVrydBackend()) {
        self.backend = backend
        locationManager.onLocation = { [weak self] coordinate, city in
            Task { @MainActor in
                self?.currentCoordinate = coordinate
                self?.currentCity = city
                self?.locationState = .ready
                await self?.refreshGridData()
            }
        }
        locationManager.onDenied = { [weak self] in
            Task { @MainActor in
                self?.locationState = .denied
                self?.statusMessage = "Location is required to use VRYD."
            }
        }
    }

    var activeCell: GridCell? {
        guard let coordinate = currentCoordinate else { return nil }
        return GridCell(center: coordinate)
    }

    var activeUser: UserProfile? {
        if case let .signedIn(profile) = session { return profile }
        return nil
    }

    func bootstrapLocation() {
        locationManager.requestAuthorizationAndStart()
    }

    func continueWithLocalSession() async {
        let user = UserProfile(
            id: UUID(),
            username: "local_user",
            email: "local@vryd.dev",
            city: currentCity,
            provider: .email
        )
        session = .signedIn(user)
        await refreshGridData()
        await refreshProfile()
        statusMessage = "Local preview mode: data is only stored while the app is running."
    }

    func postMessage() async {
        guard
            let user = activeUser,
            let cell = activeCell,
            !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        do {
            _ = try await backend.postMessage(draftMessage, in: cell, from: user)
            draftMessage = ""
            await refreshGridData()
            await refreshProfile()
        } catch {
            statusMessage = "Could not send message."
        }
    }

    func like(_ message: ChatMessage) async {
        do {
            try await backend.like(messageID: message.id)
            await refreshGridData()
        } catch {
            statusMessage = "Could not like message."
        }
    }

    func delete(_ message: ChatMessage) async {
        guard let user = activeUser else { return }
        do {
            try await backend.delete(messageID: message.id, by: user.id)
            await refreshGridData()
            await refreshProfile()
        } catch {
            statusMessage = "Could not delete message."
        }
    }

    func refreshGridData() async {
        guard let cell = activeCell else { return }
        do {
            gridMessages = try await backend.fetchMessages(in: cell)
        } catch {
            statusMessage = "Could not load chat data."
        }
    }

    func refreshProfile() async {
        guard let user = activeUser else { return }
        do {
            profileMessages = try await backend.fetchProfileMessages(for: user.id)
        } catch {
            statusMessage = "Could not load profile."
        }
    }
}

final class LocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    var onLocation: ((CLLocationCoordinate2D, String) -> Void)?
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
        geocoder.reverseGeocodeLocation(location) { [weak self] places, _ in
            let city = places?.first?.locality ?? ""
            self?.onLocation?(location.coordinate, city)
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()
    @State private var showingGridChat = false
    @State private var showingProfile = false

    var body: some View {
        Group {
            switch viewModel.locationState {
            case .loading:
                ProgressView("Getting your location…")
            case .denied:
                LocationBlockedView(retryAction: viewModel.bootstrapLocation)
            case .ready:
                switch viewModel.session {
                case .signedOut:
                    LoginView(viewModel: viewModel)
                case .signedIn:
                    mapScreen
                }
            }
        }
        .onAppear(perform: viewModel.bootstrapLocation)
    }

    private var mapScreen: some View {
        ZStack(alignment: .bottom) {
            if let coordinate = viewModel.currentCoordinate {
                GridMapView(center: coordinate)
                    .ignoresSafeArea()
            }

            VStack {
                HStack {
                    Spacer()
                    FloatingCircleButton(systemName: "person.fill") { showingProfile = true }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer()

                FloatingCircleButton(systemName: "arrow.up.circle.fill") { showingGridChat = true }
                    .padding(.bottom, 26)
            }
        }
        .sheet(isPresented: $showingGridChat) {
            GridChatSheet(viewModel: viewModel)
                .presentationDetents([.fraction(0.35), .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingProfile) {
            ProfileView(viewModel: viewModel)
        }
    }
}

struct LocationBlockedView: View {
    let retryAction: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "location.slash")
                .font(.system(size: 46))
            Text("Location Required")
                .font(.title2.weight(.bold))
            Text("Allow location access in Settings to use the app.")
                .foregroundStyle(.secondary)
            Button("Try Again", action: retryAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(20)
    }
}

struct LoginView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("VRYD")
                    .font(.system(size: 42, weight: .heavy, design: .rounded))
                Text("Talk with people in your exact square.")
                    .foregroundStyle(.secondary)

                Button("Continue") { Task { await viewModel.continueWithLocalSession() } }
                    .buttonStyle(.borderedProminent)

                Text("No account or database required for this preview build.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if !viewModel.statusMessage.isEmpty {
                    Text(viewModel.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Database schema")
                        .font(.caption.weight(.semibold))
                    ScrollView {
                        Text(SupabaseSetupGuide.sql)
                            .font(.caption2.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 130)
                    .padding(8)
                    .background(.black.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(20)
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
                Text("Grid \(GridCell.cellKey(for: viewModel.currentCoordinate ?? CLLocationCoordinate2D()))")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.gridMessages) { message in
                        CommentCard(
                            message: message,
                            canDelete: viewModel.activeUser?.id == message.authorID,
                            likeAction: { Task { await viewModel.like(message) } },
                            deleteAction: { Task { await viewModel.delete(message) } }
                        )
                    }

                    if viewModel.gridMessages.isEmpty {
                        Text("No comments in this square yet.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 16)
                    }
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
            .padding()
        }
        .task { await viewModel.refreshGridData() }
    }
}

struct CommentCard: View {
    let message: ChatMessage
    let canDelete: Bool
    let likeAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("@\(message.author)")
                    .font(.subheadline.bold())
                Spacer()
                Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(message.text)
            HStack(spacing: 12) {
                Button(action: likeAction) {
                    Label("\(message.likes)", systemImage: "heart")
                }
                .buttonStyle(.plain)
                if canDelete {
                    Button("Delete", role: .destructive, action: deleteAction)
                        .font(.caption)
                }
            }
        }
        .padding(12)
        .background(.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct ProfileView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        NavigationStack {
            List(viewModel.profileMessages) { message in
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.text)
                    Text(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Your comments")
            .task { await viewModel.refreshProfile() }
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
        return map
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let region = MKCoordinateRegion(center: center, latitudinalMeters: 650, longitudinalMeters: 650)
        mapView.setRegion(region, animated: true)

        let overlays = context.coordinator.gridOverlays(in: region, active: center)
        mapView.removeOverlays(mapView.overlays)
        mapView.addOverlays(overlays)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private let cellDistance: Double = 100

        func gridOverlays(in region: MKCoordinateRegion, active coordinate: CLLocationCoordinate2D) -> [MKPolygon] {
            let latStep = GridCell.metersToLatitudeDegrees(cellDistance)
            let lonStep = GridCell.metersToLongitudeDegrees(cellDistance, at: coordinate.latitude)

            let latMin = region.center.latitude - region.span.latitudeDelta * 0.75
            let latMax = region.center.latitude + region.span.latitudeDelta * 0.75
            let lonMin = region.center.longitude - region.span.longitudeDelta * 0.75
            let lonMax = region.center.longitude + region.span.longitudeDelta * 0.75

            let latStart = Int(floor(latMin / latStep))
            let latEnd = Int(ceil(latMax / latStep))
            let lonStart = Int(floor(lonMin / lonStep))
            let lonEnd = Int(ceil(lonMax / lonStep))

            let activeKey = GridCell.cellKey(for: coordinate)
            var result: [MKPolygon] = []

            for latIndex in latStart...latEnd {
                for lonIndex in lonStart...lonEnd {
                    let startLat = Double(latIndex) * latStep
                    let startLon = Double(lonIndex) * lonStep
                    let points = [
                        CLLocationCoordinate2D(latitude: startLat, longitude: startLon),
                        CLLocationCoordinate2D(latitude: startLat + latStep, longitude: startLon),
                        CLLocationCoordinate2D(latitude: startLat + latStep, longitude: startLon + lonStep),
                        CLLocationCoordinate2D(latitude: startLat, longitude: startLon + lonStep)
                    ]
                    let polygon = MKPolygon(coordinates: points, count: points.count)
                    polygon.title = "\(latIndex):\(lonIndex)" == activeKey ? "active" : "grid"
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
