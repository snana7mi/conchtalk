/// 文件说明：PaywallView，Free vs Paid 对比表格式的订阅升级页面。
import SwiftUI

/// PaywallView：展示功能对比和订阅按钮，供 sheet 弹出使用。
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: PaywallViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    headerSection
                    comparisonTable
                    priceSection
                    subscribeButton
                    errorMessage
                    footerLinks
                }
                .padding()
            }
            .navigationTitle(String(localized: "Upgrade to Pro", bundle: LanguageSettings.currentBundle))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close", bundle: LanguageSettings.currentBundle)) {
                        dismiss()
                    }
                }
            }
            .task {
                await viewModel.loadProducts()
            }
            .onChange(of: viewModel.purchaseState) {
                if viewModel.purchaseState == .success {
                    dismiss()
                }
            }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "crown.fill")
                .font(.system(size: 48))
                .foregroundStyle(.yellow)
            Text(String(localized: "Unlock the full experience", bundle: LanguageSettings.currentBundle))
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .padding(.top)
    }

    private var comparisonTable: some View {
        VStack(spacing: 0) {
            // 表头
            HStack {
                Text(String(localized: "Feature", bundle: LanguageSettings.currentBundle))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(String(localized: "Free", bundle: LanguageSettings.currentBundle))
                    .frame(width: 80)
                Text(String(localized: "Pro", bundle: LanguageSettings.currentBundle))
                    .frame(width: 80)
                    .fontWeight(.bold)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // 功能对比行
            comparisonRow(
                feature: String(localized: "AI Assistant", bundle: LanguageSettings.currentBundle),
                free: .check,
                pro: .check
            )
            comparisonRow(
                feature: String(localized: "SSH Connections", bundle: LanguageSettings.currentBundle),
                free: .text(String(localized: "1", bundle: LanguageSettings.currentBundle)),
                pro: .text(String(localized: "Unlimited", bundle: LanguageSettings.currentBundle))
            )
            comparisonRow(
                feature: String(localized: "Cloud Sync", bundle: LanguageSettings.currentBundle),
                free: .cross,
                pro: .check
            )
        }
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var priceSection: some View {
        Group {
            if let price = viewModel.displayPrice {
                VStack(spacing: 4) {
                    Text("\(price) / \(String(localized: "month", bundle: LanguageSettings.currentBundle))")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(String(localized: "Auto-renews monthly. Cancel anytime.", bundle: LanguageSettings.currentBundle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }
        }
    }

    private var subscribeButton: some View {
        Button {
            Task { await viewModel.purchase() }
        } label: {
            Group {
                switch viewModel.purchaseState {
                case .purchasing, .verifying:
                    ProgressView()
                        .tint(.white)
                default:
                    Text(String(localized: "Subscribe Now", bundle: LanguageSettings.currentBundle))
                        .fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .disabled(viewModel.displayPrice == nil || viewModel.purchaseState == .purchasing || viewModel.purchaseState == .verifying)
    }

    @ViewBuilder
    private var errorMessage: some View {
        if case .failed(let message) = viewModel.purchaseState {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
    }

    private var footerLinks: some View {
        VStack(spacing: 12) {
            Button(String(localized: "Restore Purchases", bundle: LanguageSettings.currentBundle)) {
                Task { await viewModel.restore() }
            }
            .font(.footnote)

            HStack(spacing: 16) {
                if let termsURL = URL(string: "https://conch-talk.com/terms") {
                    Link(String(localized: "Terms of Service", bundle: LanguageSettings.currentBundle),
                         destination: termsURL)
                }
                if let privacyURL = URL(string: "https://conch-talk.com/privacy") {
                    Link(String(localized: "Privacy Policy", bundle: LanguageSettings.currentBundle),
                         destination: privacyURL)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Comparison Row

    private enum CellContent {
        case check, cross, text(String)
    }

    private func comparisonRow(feature: String, free: CellContent, pro: CellContent) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(feature)
                    .frame(maxWidth: .infinity, alignment: .leading)
                cellView(free)
                    .frame(width: 80)
                cellView(pro)
                    .frame(width: 80)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
        }
    }

    @ViewBuilder
    private func cellView(_ content: CellContent) -> some View {
        switch content {
        case .check:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .cross:
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
        case .text(let value):
            Text(value)
                .font(.subheadline)
        }
    }
}
