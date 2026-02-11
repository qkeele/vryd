import SwiftUI
import MapKit
import CoreLocation

@MainActor
final class AppViewModel: ObservableObject {
    enum SessionState {
        case signedOut
        case signedIn(UserProfile)
    }

    @Published var session: SessionState = .signedOut
    @Published var email = ""
    @Published var password = ""
    @Published var username = ""
    @Published var locationStatus = "Requesting location…"
    @Published var currentCoordinate = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
    @Published var liveMessages: [ChatMessage] = []
    @Published var archivedMessages: [String: [ChatMessage]] = [:]
    @Published var profileMessages: [ChatMessage] = []
    @Published var draftMessage = ""

    let backend: VrydBackend
    let locationManager = LocationManager()

    init(backend: VrydBackend = MockVrydBackend()) {
        self.backend = backend
        locationManager.onLocation = { [weak self] coordinate, city in
            Task { @MainActor in
                self?.currentCoordinate = coordinate
                self?.locationStatus = city.isEmpty ? "Location active" : city
                await self?.refreshGridData()
            }
        }
    }

    var activeCell: GridCell {
        GridCell(center: currentCoordinate)
    }

    var activeUser: UserProfile? {
        if case let .signedIn(profile) = session { return profile }
        return nil
    }

    func bootstrapLocation() {
        locationManager.requestAuthorizationAndStart()
    }

    func signIn() async {
        do {
            let user = try await backend.signIn(email: email, password: password)
            session = .signedIn(user)
            await refreshGridData()
            await refreshProfile()
        } catch {
            locationStatus = "Could not sign in."
        }
    }

    func signUp() async {
        do {
            let user = try await backend.signUp(username: username, email: email, password: password)
            session = .signedIn(user)
            await refreshGridData()
            await refreshProfile()
        } catch {
            locationStatus = "Could not sign up."
        }
    }

    func postMessage() async {
        guard let user = activeUser, !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            _ = try await backend.postMessage(draftMessage, in: activeCell, from: user)
            draftMessage = ""
            await refreshGridData()
            await refreshProfile()
        } catch {
            locationStatus = "Could not send message."
        }
    }

    func like(_ message: ChatMessage) async {
        do {
            try await backend.like(messageID: message.id)
            await refreshGridData()
        } catch {
            locationStatus = "Could not like message."
        }
    }

    func delete(_ message: ChatMessage) async {
        guard let user = activeUser else { return }
        do {
            try await backend.delete(messageID: message.id, by: user.id)
            await refreshGridData()
            await refreshProfile()
        } catch {
            locationStatus = "Could not delete message."
        }
    }

    func refreshGridData() async {
        do {
            liveMessages = try await backend.fetchLiveMessages(in: activeCell)
            archivedMessages = try await backend.fetchArchivedMessages(in: activeCell)
        } catch {
            locationStatus = "Could not load chat data."
        }
    }

    func refreshProfile() async {
        guard let user = activeUser else { return }
        do {
            profileMessages = try await backend.fetchProfileMessages(for: user.id)
        } catch {
            locationStatus = "Could not load profile."
        }
    }
}

final class LocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    var onLocation: ((CLLocationCoordinate2D, String) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestAuthorizationAndStart() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
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
            switch viewModel.session {
            case .signedOut:
                LoginView(viewModel: viewModel)
            case .signedIn:
                ZStack {
                    VStack(spacing: 0) {
                        HeaderBar(locationStatus: viewModel.locationStatus) {
                            showingProfile = true
                        }
                        GridMapView(center: viewModel.currentCoordinate)
                            .overlay(alignment: .bottom) {
                                Button {
                                    showingGridChat = true
                                } label: {
                                    Image(systemName: "bubble.left.and.bubble.right.fill")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(16)
                                        .background(.black)
                                        .clipShape(Circle())
                                }
                                .padding(.bottom, 26)
                            }
                    }
                }
                .sheet(isPresented: $showingGridChat) {
                    GridChatSheet(viewModel: viewModel)
                }
                .sheet(isPresented: $showingProfile) {
                    ProfileView(viewModel: viewModel)
                }
            }
        }
        .onAppear {
            viewModel.bootstrapLocation()
        }
    }
}

struct LoginView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 18) {
            Text("VRYD")
                .font(.system(size: 40, weight: .heavy, design: .rounded))
            Text("Virtual Realm You Define")
                .foregroundStyle(.secondary)

            Group {
                TextField("username", text: $viewModel.username)
                TextField("email", text: $viewModel.email)
                    .textInputAutocapitalization(.never)
                SecureField("password", text: $viewModel.password)
            }
            .padding(12)
            .background(.white)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.black, lineWidth: 2))

            HStack {
                Button("Create account") {
                    Task { await viewModel.signUp() }
                }
                .buttonStyle(VrydButtonStyle())

                Button("Sign in") {
                    Task { await viewModel.signIn() }
                }
                .buttonStyle(VrydButtonStyle(fill: .black, foreground: .white))
            }

            if let config = SupabaseConfig.fromEnvironment() {
                Text("Supabase connected: \(config.projectURL.host() ?? "custom")")
                    .font(.footnote)
            } else {
                Text("No Supabase keys set. Running local mock data.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Supabase starter SQL")
                    .font(.caption.weight(.semibold))
                ScrollView {
                    Text(SupabaseSetupGuide.sql)
                        .font(.caption2.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
                .padding(8)
                .background(.black.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(22)
        .background(.white)
    }
}

struct HeaderBar: View {
    let locationStatus: String
    var profileAction: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("VRYD")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(locationStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: profileAction) {
                Image(systemName: "person.crop.square")
                    .font(.title2)
                    .foregroundStyle(.black)
            }
        }
        .padding()
        .background(.white)
        .overlay(Rectangle().frame(height: 2).foregroundStyle(.black), alignment: .bottom)
    }
}

struct GridChatSheet: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        NavigationStack {
            VStack {
                HStack {
                    Text("Grid \(GridCell.cellKey(for: viewModel.currentCoordinate))")
                        .font(.headline)
                    Spacer()
                }

                List {
                    Section("Live") {
                        ForEach(viewModel.liveMessages) { message in
                            MessageRow(
                                message: message,
                                canLike: true,
                                canDelete: viewModel.activeUser?.id == message.authorID,
                                likeAction: { Task { await viewModel.like(message) } },
                                deleteAction: { Task { await viewModel.delete(message) } }
                            )
                        }
                    }

                    Section("Archive by date") {
                        ForEach(viewModel.archivedMessages.keys.sorted(by: >), id: \.self) { key in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(key).font(.subheadline.bold())
                                ForEach(viewModel.archivedMessages[key] ?? []) { message in
                                    MessageRow(
                                        message: message,
                                        canLike: false,
                                        canDelete: viewModel.activeUser?.id == message.authorID,
                                        likeAction: {},
                                        deleteAction: { Task { await viewModel.delete(message) } }
                                    )
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(.insetGrouped)

                HStack {
                    TextField("Say something for this square...", text: $viewModel.draftMessage)
                        .textFieldStyle(.roundedBorder)
                    Button("Post") {
                        Task { await viewModel.postMessage() }
                    }
                    .buttonStyle(VrydButtonStyle(fill: .black, foreground: .white, compact: true))
                }
                .padding(.horizontal)
            }
            .navigationTitle("Grid Chat")
            .task {
                await viewModel.refreshGridData()
            }
        }
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let canLike: Bool
    let canDelete: Bool
    let likeAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("@\(message.author)")
                    .font(.caption.bold())
                Spacer()
                Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(message.text)
                .font(.body)

            HStack {
                Text(message.city)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if canLike {
                    Button("❤️ \(message.likes)", action: likeAction)
                        .font(.caption)
                        .buttonStyle(.plain)
                } else {
                    Text("♡ \(message.likes)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if canDelete {
                    Button("Delete", role: .destructive, action: deleteAction)
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct ProfileView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        NavigationStack {
            List(viewModel.profileMessages) { message in
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.text)
                    Text("\(message.city) • \(message.dayKey)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Your posts")
            .task {
                await viewModel.refreshProfile()
            }
        }
    }
}

struct VrydButtonStyle: ButtonStyle {
    var fill: Color = .white
    var foreground: Color = .black
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 13 : 16, weight: .semibold))
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 8 : 10)
            .frame(maxWidth: compact ? nil : .infinity)
            .background(fill)
            .foregroundStyle(foreground)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.black, lineWidth: 2))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct GridMapView: UIViewRepresentable {
    let center: CLLocationCoordinate2D

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.showsUserLocation = true
        map.pointOfInterestFilter = .excludingAll
        map.delegate = context.coordinator
        return map
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let region = MKCoordinateRegion(
            center: center,
            latitudinalMeters: 700,
            longitudinalMeters: 700
        )
        mapView.setRegion(region, animated: true)

        mapView.removeOverlays(mapView.overlays)
        mapView.addOverlays(context.coordinator.gridOverlays(around: center))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func gridOverlays(around coordinate: CLLocationCoordinate2D) -> [MKPolygon] {
            var overlays: [MKPolygon] = []
            let latStep = GridCell.metersToLatitudeDegrees(100)
            let lonStep = GridCell.metersToLongitudeDegrees(100, at: coordinate.latitude)
            let baseLat = floor(coordinate.latitude / latStep) * latStep
            let baseLon = floor(coordinate.longitude / lonStep) * lonStep

            for x in -1...1 {
                for y in -1...1 {
                    let startLat = baseLat + (Double(x) * latStep)
                    let startLon = baseLon + (Double(y) * lonStep)
                    let points = [
                        CLLocationCoordinate2D(latitude: startLat, longitude: startLon),
                        CLLocationCoordinate2D(latitude: startLat + latStep, longitude: startLon),
                        CLLocationCoordinate2D(latitude: startLat + latStep, longitude: startLon + lonStep),
                        CLLocationCoordinate2D(latitude: startLat, longitude: startLon + lonStep)
                    ]
                    overlays.append(MKPolygon(coordinates: points, count: points.count))
                }
            }
            return overlays
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polygon = overlay as? MKPolygon else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolygonRenderer(polygon: polygon)
            renderer.strokeColor = UIColor.black.withAlphaComponent(0.55)
            renderer.lineWidth = 1
            renderer.fillColor = UIColor.clear
            return renderer
        }
    }
}

#Preview {
    ContentView()
}
