/// 文件说明：SSHConnectionProgressViewModelTests，测试 SSH 连接进度视图模型的阶段管理与状态上报。
import Testing
@testable import ConchTalk
import Foundation

@Suite("SSHConnectionProgressViewModel")
@MainActor
struct SSHConnectionProgressViewModelTests {
    private func makeViewModel() -> SSHConnectionProgressViewModel {
        let server = TestFixtures.makeServer(
            host: "192.168.1.1",
            port: 22,
            username: "root",
            authMethod: .password
        )
        return SSHConnectionProgressViewModel(server: server)
    }

    @Test("init creates exactly 5 stages")
    func initHasFiveStages() {
        let vm = makeViewModel()
        #expect(vm.stages.count == 5)
    }

    @Test("all stages are initially pending")
    func allStagesInitiallyPending() {
        let vm = makeViewModel()
        for stage in vm.stages {
            #expect(stage.status == .pending)
        }
    }

    @Test("startAnimation success path marks all stages completed")
    func startAnimationSuccessCompletesAllStages() async throws {
        let vm = makeViewModel()
        vm.reportConnectionResult(.success(()))

        await vm.startAnimation()

        #expect(vm.isFinished == true)
        #expect(vm.stages.allSatisfy { $0.status == .completed })
        #expect(vm.logLines.contains { $0.type == .success })
    }

    @Test("startAnimation failure path marks stage failed and logs error")
    func startAnimationFailureMarksFailedStage() async throws {
        struct TestError: LocalizedError {
            var errorDescription: String? { "simulated failure" }
        }

        let vm = makeViewModel()
        vm.reportConnectionResult(.failure(TestError()))

        await vm.startAnimation()

        #expect(vm.isFinished == true)
        #expect(vm.stages.contains { $0.status == .failed })
        #expect(vm.logLines.contains { $0.type == .error && $0.text.contains("simulated failure") })
    }

    @Test("all stage titles are non-empty")
    func allStageTitlesAreNonEmpty() {
        let vm = makeViewModel()
        for stage in vm.stages {
            #expect(!stage.title.isEmpty)
        }
    }

    @Test("isFinished starts as false")
    func isFinishedStartsFalse() {
        let vm = makeViewModel()
        #expect(vm.isFinished == false)
    }

    @Test("logLines starts empty")
    func logLinesStartEmpty() {
        let vm = makeViewModel()
        #expect(vm.logLines.isEmpty)
    }
}
