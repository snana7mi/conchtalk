/// 文件说明：ProfileView，负责用户个人资料页面，包含头像修改、账户信息与账户操作。
import SwiftUI
import AuthenticationServices
import PhotosUI
import UIKit
import RevenueCat

/// ProfileView：用户个人资料页面。
struct ProfileView: View {
    var authService: AuthService
    var subscriptionService: SubscriptionService

    @State private var showPaywall = false
    @State private var avatarItem: PhotosPickerItem?
    @State private var avatarImage: Image?
    @State private var isUploadingAvatar = false
    @State private var usageInfo: UsageInfo?
    @State private var showDeleteConfirmation = false
    @State private var authError: String?

    var body: some View {
        Form {
            if authService.isLoggedIn {
                avatarSection
                accountInfoSection
                accountActionsSection
            } else {
                signInSection
            }
        }
        .navigationTitle(String(localized: "Profile", bundle: LanguageSettings.currentBundle))
        .navigationBarTitleDisplayMode(.inline)
        .alert(String(localized: "Delete Account", bundle: LanguageSettings.currentBundle), isPresented: $showDeleteConfirmation) {
            Button(String(localized: "Cancel", bundle: LanguageSettings.currentBundle), role: .cancel) {}
            Button(String(localized: "Delete", bundle: LanguageSettings.currentBundle), role: .destructive) {
                Task {
                    do {
                        try await authService.deleteAccount()
                    } catch {
                        authError = error.localizedDescription
                    }
                }
            }
        } message: {
            Text(String(localized: "This will permanently delete your account and all data. This action cannot be undone.", bundle: LanguageSettings.currentBundle))
        }
        .onChange(of: avatarItem) {
            guard let avatarItem else { return }
            Task { await handleAvatarSelection(avatarItem) }
        }
        .task {
            if authService.isLoggedIn {
                await loadAvatarImage()
                usageInfo = try? await authService.fetchUsage()
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(viewModel: PaywallViewModel(subscriptionService: subscriptionService))
        }
    }

    // MARK: - 头像区域

    @ViewBuilder
    private var avatarSection: some View {
        Section {
            HStack {
                Spacer()
                VStack(spacing: 12) {
                    PhotosPicker(selection: $avatarItem, matching: .images) {
                        ZStack {
                            if let avatarImage {
                                avatarImage
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Circle()
                                    .fill(Color.accentColor.opacity(0.15))
                                Text(Self.avatarInitial(from: authService.currentUser?.displayName))
                                    .font(.largeTitle.bold())
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .frame(width: 88, height: 88)
                        .clipShape(Circle())
                        .rainbowAvatarBorder(isActive: authService.currentUser?.tier == "paid", size: 88)
                        .overlay(alignment: .bottomTrailing) {
                            if isUploadingAvatar {
                                ProgressView()
                                    .frame(width: 24, height: 24)
                                    .background(.ultraThinMaterial, in: Circle())
                            } else {
                                Image(systemName: "camera.fill")
                                    .font(.caption)
                                    .foregroundStyle(.white)
                                    .padding(5)
                                    .background(Color.accentColor, in: Circle())
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isUploadingAvatar)

                    if let displayName = authService.currentUser?.displayName, !displayName.isEmpty {
                        Text(displayName)
                            .font(.title3.bold())
                    }
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - 账户信息区域

    @ViewBuilder
    private var accountInfoSection: some View {
        Section(String(localized: "Account", bundle: LanguageSettings.currentBundle)) {
            if let user = authService.currentUser {
                LabeledContent(String(localized: "Tier", bundle: LanguageSettings.currentBundle)) {
                    HStack(spacing: 8) {
                        Text(user.tier.capitalized)
                            .foregroundStyle(user.tier == "paid" ? .green : .secondary)
                        if user.tier != "paid" {
                            Button(String(localized: "Upgrade", bundle: LanguageSettings.currentBundle)) {
                                showPaywall = true
                            }
                            .font(.caption)
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .controlSize(.mini)
                        }
                    }
                }

            }

            if let usage = usageInfo {
                LabeledContent(String(localized: "Usage", bundle: LanguageSettings.currentBundle)) {
                    Text("\(String(format: "%.1f", usage.percentage))%")
                        .foregroundStyle(usage.percentage > 100 ? .red : .primary)
                }
                if let resetsAt = usage.resetsAt, let countdown = Self.countdownString(from: resetsAt) {
                    LabeledContent(String(localized: "Resets In", bundle: LanguageSettings.currentBundle), value: countdown)
                }
            }
        }
    }

    // MARK: - 账户操作区域

    @ViewBuilder
    private var accountActionsSection: some View {
        Section {
            Button(String(localized: "Restore Purchases", bundle: LanguageSettings.currentBundle)) {
                Task { await subscriptionService.restore() }
            }
            .font(.footnote)

            Button(String(localized: "Sign Out", bundle: LanguageSettings.currentBundle), role: .destructive) {
                Task {
                    await authService.logout()
                    usageInfo = nil
                    avatarImage = nil
                }
            }

            Button(String(localized: "Delete Account", bundle: LanguageSettings.currentBundle), role: .destructive) {
                showDeleteConfirmation = true
            }
        }

        if let error = authError {
            Section {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    // MARK: - 登录区域

    @ViewBuilder
    private var signInSection: some View {
        Section(String(localized: "Account", bundle: LanguageSettings.currentBundle)) {
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                handleSignInResult(result)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 44)

            if let error = authError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    // MARK: - 头像辅助方法

    static func avatarInitial(from name: String?) -> String {
        guard let name, let first = name.first else { return "?" }
        return String(first).uppercased()
    }

    /// 加载头像：优先使用 AuthService 缓存，若无则尝试 iCloud 通讯录头像。
    func loadAvatarImage() async {
        if let data = await authService.loadAvatarDataIfNeeded(),
           let img = ImageUtils.makeSwiftUIImage(from: data) {
            avatarImage = img
            return
        }

        if let data = await Self.fetchContactMeAvatar(), let img = ImageUtils.makeSwiftUIImage(from: data) {
            avatarImage = img
        }
    }

    private func handleAvatarSelection(_ item: PhotosPickerItem) async {
        defer { avatarItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        guard let compressed = ImageUtils.compressImage(data, maxSize: 512) else { return }

        if let img = ImageUtils.makeSwiftUIImage(from: compressed) {
            avatarImage = img
        }

        isUploadingAvatar = true
        defer { isUploadingAvatar = false }
        do {
            _ = try await authService.uploadAvatar(imageData: compressed)
        } catch {
            authError = String(localized: "Avatar upload failed: \(error.localizedDescription)", bundle: LanguageSettings.currentBundle)
        }
    }

    private static func fetchContactMeAvatar() async -> Data? {
        return nil
    }

    static func compressImage(_ data: Data, maxSize: CGFloat) -> Data? {
        ImageUtils.compressImage(data, maxSize: maxSize)
    }

    static func makeSwiftUIImage(from data: Data) -> Image? {
        ImageUtils.makeSwiftUIImage(from: data)
    }

    // MARK: - 辅助方法

    private static func countdownString(from isoString: String) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let targetDate = formatter.date(from: isoString) else { return nil }
        let remaining = targetDate.timeIntervalSince(Date())
        guard remaining > 0 else { return nil }
        let totalMinutes = Int(remaining) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    // MARK: - 登录处理

    private func handleSignInResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let identityToken = credential.identityToken else {
                authError = String(localized: "Failed to get Apple ID credential", bundle: LanguageSettings.currentBundle)
                return
            }

            let fullName: String?
            if let nameComponents = credential.fullName {
                let formatter = PersonNameComponentsFormatter()
                let name = formatter.string(from: nameComponents)
                fullName = name.isEmpty ? nil : name
            } else {
                fullName = nil
            }

            Task {
                do {
                    try await authService.authenticate(identityToken: identityToken, fullName: fullName, appleSub: credential.user)
                    // 登录后将 Apple 用户标识符同步给 RevenueCat
                    if Purchases.isConfigured {
                        _ = try? await Purchases.shared.logIn(credential.user)
                    }
                    usageInfo = try? await authService.fetchUsage()
                    await loadAvatarImage()
                    authError = nil
                } catch {
                    authError = error.localizedDescription
                }
            }

        case .failure(let error):
            if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                authError = error.localizedDescription
            }
        }
    }
}
