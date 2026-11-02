/// 文件说明：HealthCheckSettingsView，按服务器配置磁盘、负载和服务检查。
import SwiftUI

/// HealthCheckSettingsModel：设置页上的计划列表，保存后交给调度器重新提交后台刷新。
@MainActor
@Observable
final class HealthCheckSettingsModel {
    private let coordinator: HealthCheckCoordinator
    private let loadServers: () async -> [Server]
    private(set) var servers: [Server] = []
    private(set) var plans: [HealthCheckPlan] = []
    var errorMessage: String?

    init(coordinator: HealthCheckCoordinator, loadServers: @escaping () async -> [Server]) {
        self.coordinator = coordinator
        self.loadServers = loadServers
    }

    func reload() async {
        servers = await loadServers()
        plans = coordinator.plans()
    }

    func plan(for serverID: UUID) -> HealthCheckPlan? {
        plans.first { $0.serverID == serverID }
    }

    func runSavedCheck(for serverID: UUID) async {
        guard let plan = plan(for: serverID), plan.enabled else { return }
        await coordinator.runNow(planID: plan.id)
        plans = coordinator.plans()
    }

    func save(_ plan: HealthCheckPlan) -> Bool {
        let thresholds = plan.thresholds.sanitized()
        if HealthProbeCommand.script(services: thresholds.services) == nil {
            errorMessage = String(localized: "A service name is not safe to check.", bundle: LanguageSettings.currentBundle)
            return false
        }
        var updated = plan
        updated.thresholds = thresholds
        updated.requestedInterval = HealthCheckLimits.clampedInterval(plan.requestedInterval)
        var all = coordinator.plans()
        if let index = all.firstIndex(where: { $0.id == plan.id }) {
            all[index] = updated
        } else {
            all.append(updated)
        }
        coordinator.replace(all)
        plans = coordinator.plans()
        errorMessage = nil
        return true
    }
}

/// HealthCheckSettingsView：列出服务器，打开后编辑阈值。页脚说明 iOS 后台刷新的限制。
struct HealthCheckSettingsView: View {
    @Bindable var model: HealthCheckSettingsModel

    var body: some View {
        Form {
            if model.servers.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Servers", bundle: LanguageSettings.currentBundle),
                    systemImage: "server.rack"
                )
            } else {
                Section {
                    ForEach(model.servers) { server in
                        NavigationLink {
                            HealthCheckEditor(model: model, server: server)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(server.name)
                                if let summary = model.plan(for: server.id)?.lastSummary {
                                    Text(summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                } footer: {
                    Text(String(localized: "iOS chooses when a background refresh runs. Checks cannot be promised more often than about 15 minutes, and each wake checks one server. Force quit, Low Power Mode, or a short execution window can delay or skip a check.", bundle: LanguageSettings.currentBundle))
                }
            }
        }
        .navigationTitle(String(localized: "Health Checks", bundle: LanguageSettings.currentBundle))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await model.reload() }
        .alert(
            String(localized: "Health Checks", bundle: LanguageSettings.currentBundle),
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button(String(localized: "OK", bundle: LanguageSettings.currentBundle), role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// HealthCheckEditor：一台服务器的阈值、服务名和间隔。
private struct HealthCheckEditor: View {
    @Bindable var model: HealthCheckSettingsModel
    let server: Server
    @State private var enabled = false
    @State private var disk = 90
    @State private var load = 4.0
    @State private var services = ""
    @State private var interval = HealthCheckLimits.minimumInterval

    private static let intervals: [(TimeInterval, String)] = [
        (15 * 60, String(localized: "Every 15 minutes", bundle: LanguageSettings.currentBundle)),
        (30 * 60, String(localized: "Every 30 minutes", bundle: LanguageSettings.currentBundle)),
        (60 * 60, String(localized: "Every hour", bundle: LanguageSettings.currentBundle)),
        (6 * 60 * 60, String(localized: "Every 6 hours", bundle: LanguageSettings.currentBundle)),
        (24 * 60 * 60, String(localized: "Every day", bundle: LanguageSettings.currentBundle)),
    ]

    var body: some View {
        Form {
            Toggle(String(localized: "Enabled", bundle: LanguageSettings.currentBundle), isOn: $enabled)
            Stepper(value: $disk, in: 50...99) {
                Text(String(format: String(localized: "Disk alert at %d%%", bundle: LanguageSettings.currentBundle), disk))
            }
            Stepper(value: $load, in: 0.5...64, step: 0.5) {
                Text(String(format: String(localized: "Load alert at %.1f", bundle: LanguageSettings.currentBundle), load))
            }
            TextField(String(localized: "Services, comma separated", bundle: LanguageSettings.currentBundle), text: $services)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            Picker(String(localized: "Interval", bundle: LanguageSettings.currentBundle), selection: $interval) {
                ForEach(Self.intervals, id: \.0) { choice in
                    Text(choice.1).tag(choice.0)
                }
            }
            if let summary = model.plan(for: server.id)?.lastSummary {
                Section(String(localized: "Last result", bundle: LanguageSettings.currentBundle)) {
                    Text(summary)
                }
            }
        }
        .navigationTitle(server.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear(perform: load)
        .onDisappear(perform: persist)
    }

    private func load() {
        if let plan = model.plan(for: server.id) {
            enabled = plan.enabled
            disk = plan.thresholds.diskUsedPercent
            load = plan.thresholds.loadAverage
            services = plan.thresholds.services.joined(separator: ", ")
            interval = HealthCheckLimits.clampedInterval(plan.requestedInterval)
        }
    }

    private func persist() {
        let names = services.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let existing = model.plan(for: server.id)
        let plan = HealthCheckPlan(
            id: existing?.id ?? UUID(),
            serverID: server.id,
            enabled: enabled,
            thresholds: HealthThresholds(diskUsedPercent: disk, loadAverage: load, services: names),
            requestedInterval: interval,
            lastRunAt: existing?.lastRunAt,
            lastSummary: existing?.lastSummary
        )
        let wasEnabled = existing?.enabled == true
        if model.save(plan), enabled, !wasEnabled {
            Task { await model.runSavedCheck(for: server.id) }
        }
    }
}
