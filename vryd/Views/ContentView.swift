import SwiftUI
import MapKit
import AuthenticationServices
import CryptoKit
import Security

// MARK: - Root Screen

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
