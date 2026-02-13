import SwiftUI
import MapKit

// MARK: - Grid Chat

struct GridChatSheet: View {
    enum CommentSort: String, CaseIterable, Identifiable {
        case top = "Top"
        case newest = "Newest"
        case oldest = "Oldest"
        var id: String { rawValue }
    }

    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var commentSort: CommentSort = .top
    @State private var visibleReplyCountByParent: [UUID?: Int] = [:]

    private let pageSize = 12

    var body: some View {
        NavigationStack {
            VStack(spacing: 6) {
                Picker("Sort comments", selection: $commentSort) {
                    ForEach(CommentSort.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if viewModel.gridMessages.isEmpty {
                            Text("No comments yet — be the first one in this grid.")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                                .padding(.top, 20)
                        } else {
                            nestedReplies(parentID: nil, depth: 0)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.horizontal, 12)
                }

                composer
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

    private func nestedReplies(parentID: UUID?, depth: Int) -> AnyView {
        let replies = sortedReplies(for: parentID)
        let visibleCount = visibleReplyCountByParent[parentID] ?? min(pageSize, replies.count)

        return AnyView(VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(replies.prefix(visibleCount))) { reply in
                let childCount = viewModel.replies(for: reply.id).count
                FlatCommentRow(
                    message: reply,
                    canDelete: viewModel.activeUser?.id == reply.authorID,
                    upvoteAction: { Task { await viewModel.vote(reply, value: 1) } },
                    downvoteAction: { Task { await viewModel.vote(reply, value: -1) } },
                    replyAction: {
                        viewModel.replyTo = reply
                        viewModel.draftMessage = "@\(resolvedAuthorName(for: reply)) "
                    },
                    deleteAction: { Task { await viewModel.delete(reply) } },
                    showReplyCount: childCount == 0 ? nil : childCount,
                    compact: true,
                    indentation: depth
                )

                if childCount > 0 {
                    nestedReplies(parentID: reply.id, depth: depth + 1)
                }
            }

            if replies.count > visibleCount {
                Button("Show \(min(pageSize, replies.count - visibleCount)) more repl\(replies.count - visibleCount == 1 ? "y" : "ies")") {
                    visibleReplyCountByParent[parentID] = min(replies.count, visibleCount + pageSize)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, CGFloat(depth * 12) + 6)
                .padding(.vertical, 2)
            }
        })
    }

    private func sortedReplies(for parentID: UUID?) -> [ChatMessage] {
        let replies = viewModel.gridMessages.filter { $0.parentID == parentID }
        switch commentSort {
        case .top:
            return replies.sorted {
                if $0.score == $1.score { return $0.createdAt < $1.createdAt }
                return $0.score > $1.score
            }
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
        VStack(spacing: 4) {
            if let reply = viewModel.replyTo {
                HStack {
                    Text("Replying to @\(resolvedAuthorName(for: reply))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { viewModel.replyTo = nil; viewModel.draftMessage = "" }
                        .font(.caption)
                }
                .padding(.horizontal, 16)
            }

            HStack(spacing: 8) {
                TextField("Add a comment…", text: $viewModel.draftMessage, axis: .vertical)
                    .lineLimit(1...3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.black.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button(viewModel.replyTo == nil ? "Post" : "Reply") { Task { await viewModel.postMessage() } }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
            }
            .padding(.horizontal, 12)
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
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            Text("\(authorLabel) • \(relativeTime)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(message.text)
                .font(compact ? .subheadline : .body)

            HStack(spacing: compact ? 10 : 12) {
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
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 6 : 8)
        .background(Color.black.opacity(compact ? 0.02 : 0.03))
        .clipShape(RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous))
        .contextMenu {
            if canDelete {
                Button("Delete", role: .destructive, action: deleteAction)
            }
        }
    }
}

// MARK: - Profile

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

// MARK: - Map

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
