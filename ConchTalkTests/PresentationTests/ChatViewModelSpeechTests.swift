/// 文件说明：ChatViewModelSpeechTests，验证 ChatViewModel 的语音识别集成逻辑。
import Testing
@testable import ConchTalk
import Foundation

@MainActor
struct ChatViewModelSpeechTests {
    private func makeSUT() throws -> (ChatViewModel, MockSpeechRecognitionService) {
        let store = try ChatViewModelTestSupport.makeInMemoryStore()
        let server = Server(name: "Test", host: "localhost", username: "test", authMethod: .password)
        let mockSpeech = MockSpeechRecognitionService()
        let coordinator = SpeechInputCoordinator(speechRecognitionService: mockSpeech)
        let vm = ChatViewModelTestSupport.makeViewModel(server: server, store: store, speechCoordinator: coordinator)
        return (vm, mockSpeech)
    }

    @Test func toggleSpeechRecognitionStartsListening() async throws {
        let (vm, mockSpeech) = try makeSUT()
        mockSpeech.isAvailable = true

        await vm.toggleSpeechRecognition()

        #expect(mockSpeech.startListeningCallCount == 1)
    }

    @Test func toggleSpeechRecognitionStopsWhenListening() async throws {
        let (vm, mockSpeech) = try makeSUT()
        mockSpeech.isAvailable = true
        mockSpeech.stopListeningResult = "hello world"

        await vm.toggleSpeechRecognition()
        await vm.toggleSpeechRecognition()

        #expect(mockSpeech.stopListeningCallCount == 1)
        #expect(vm.inputText == "hello world")
    }

    @Test func partialTextSyncsToInputText() throws {
        let (vm, mockSpeech) = try makeSUT()

        mockSpeech.simulatePartialResult("你好")
        vm.syncSpeechState()

        #expect(vm.inputText == "你好")
    }

    @Test func partialTextAppendsToExistingInputDuringSpeechSession() async throws {
        let (vm, mockSpeech) = try makeSUT()
        vm.inputText = "继续继续"

        await vm.toggleSpeechRecognition()
        mockSpeech.simulatePartialResult("12345")
        vm.syncSpeechState()

        #expect(vm.inputText == "继续继续12345")
    }

    @Test func emptyStopResultDoesNotOverwriteExistingInput() async throws {
        let (vm, mockSpeech) = try makeSUT()
        vm.inputText = "继续继续"
        mockSpeech.stopListeningResult = ""

        await vm.toggleSpeechRecognition()
        await vm.toggleSpeechRecognition()

        #expect(vm.inputText == "继续继续")
    }

    @Test func speechStateIdleDoesNotOverwriteInputText() throws {
        let (vm, _) = try makeSUT()
        vm.inputText = "existing text"

        vm.syncSpeechState()

        #expect(vm.inputText == "existing text")
    }

    @Test func isSpeechListeningReflectsServiceState() throws {
        let (vm, mockSpeech) = try makeSUT()

        #expect(vm.isSpeechListening == false)

        mockSpeech.simulatePartialResult("test")
        #expect(vm.isSpeechListening == true)
    }
}
