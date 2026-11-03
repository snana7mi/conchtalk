/// 文件说明：KnownHostsStoreTests，验证指纹确认、原子写入和已知主机列表。
import Foundation
import Testing
@testable import ConchTalk

@Suite("KnownHostsStore")
struct KnownHostsStoreTests {
    @Test("SHA256 指纹使用 OpenSSH 展示形式")
    func openSSHFingerprint() {
        let emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        #expect(HostKeyFingerprint.openSSH(hex: emptySHA256) == "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU")
        #expect(HostKeyFingerprint.openSSH(hex: "abc") == "SHA256:abc")
    }

    @Test("首次提交不会被另一次首次提交覆盖")
    func firstUseDoesNotClobber() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let store = KnownHostsStore(fileURL: url)
        let first = await store.commit(.trustFirstUse(fingerprint: "aa"), host: "h", port: 22)
        let second = await store.commit(.trustFirstUse(fingerprint: "bb"), host: "h", port: 22)
        #expect(first == .trusted)
        #expect(second == .conflict(.changed(stored: "aa", received: "bb")))
        #expect(await store.admission(host: "h", port: 22, fingerprint: "aa") == .trusted)
        #expect(await store.lookup(host: "h", port: 22, fingerprint: "bb") == .mismatch(stored: "aa", received: "bb"))
    }

    @Test("两个存储实例并发首次信任只留下一枚指纹")
    func concurrentStoresAreAtomic() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let storeA = KnownHostsStore(fileURL: url)
        let storeB = KnownHostsStore(fileURL: url)
        let fingerprints = ["aa", "bb", "cc", "dd"]
        let results = await withTaskGroup(of: HostKeyCommitResult.self) { group in
            for fingerprint in fingerprints {
                group.addTask {
                    let store = (fingerprint == "aa" || fingerprint == "cc") ? storeA : storeB
                    return await store.commit(.trustFirstUse(fingerprint: fingerprint), host: "h", port: 22)
                }
            }
            var collected: [HostKeyCommitResult] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
        let trustedCount = results.filter {
            if case .trusted = $0 { return true }
            return false
        }.count
        #expect(trustedCount == 1)
        let records = await storeB.list()
        #expect(records.count == 1)
        let winner = try #require(records.first?.fingerprint)
        #expect(fingerprints.contains(winner))
        let loser = try #require(fingerprints.first { $0 != winner })
        #expect(await storeA.admission(host: "h", port: 22, fingerprint: loser) == .changed(stored: winner, received: loser))
    }

    @Test("重置只在旧指纹匹配时替换")
    func resetIsCompareAndSwap() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let store = KnownHostsStore(fileURL: url)
        #expect(await store.commit(.trustFirstUse(fingerprint: "aa"), host: "h", port: 22) == .trusted)
        let wrong = await store.commit(.reset(expectedStored: "zz", fingerprint: "bb"), host: "h", port: 22)
        #expect(wrong == .conflict(.changed(stored: "aa", received: "bb")))
        #expect(await store.admission(host: "h", port: 22, fingerprint: "aa") == .trusted)
        #expect(await store.commit(.reset(expectedStored: "aa", fingerprint: "bb"), host: "h", port: 22) == .trusted)
        #expect(await store.admission(host: "h", port: 22, fingerprint: "bb") == .trusted)
    }

    @Test("列表和删除")
    func listAndRemove() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let store = KnownHostsStore(fileURL: url)
        _ = await store.commit(.trustFirstUse(fingerprint: "aa"), host: "b.example", port: 22)
        _ = await store.commit(.trustFirstUse(fingerprint: "bb"), host: "a.example", port: 2222)
        let records = await store.list()
        #expect(records.map(\.host) == ["a.example", "b.example"])
        await store.remove(host: "a.example", port: 2222)
        #expect(await store.admission(host: "a.example", port: 2222, fingerprint: "bb") == .firstUse(fingerprint: "bb"))
        #expect(await store.list().count == 1)
    }

    @Test("拒绝首次指纹时不写入")
    func rejectFirstUseDoesNotStore() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let store = KnownHostsStore(fileURL: url)
        let prompter = ScriptedHostKeyPrompter()
        prompter.decision = .reject
        do {
            try await HostKeyVerifier.verify(store: store, prompter: prompter, host: "h", port: 22, fingerprint: "aa")
            Issue.record("应拒绝")
        } catch let error as SSHError {
            #expect(error == .hostKeyRejected(host: "h", stored: nil, received: "aa"))
        }
        #expect(await store.list().isEmpty)
        #expect(prompter.prompts.count == 1)
        #expect(prompter.prompts[0].admission == .firstUse(fingerprint: "aa"))
        #expect(HostKeyVerifier.commitAction(for: .firstUse(fingerprint: "aa")) == .trustFirstUse(fingerprint: "aa"))
    }

    @Test("接受后再次连接不再询问")
    func acceptThenMatch() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let store = KnownHostsStore(fileURL: url)
        let prompter = ScriptedHostKeyPrompter()
        prompter.decision = .accept
        try await HostKeyVerifier.verify(store: store, prompter: prompter, host: "h", port: 22, fingerprint: "aa")
        prompter.prompts.removeAll()
        try await HostKeyVerifier.verify(store: store, prompter: prompter, host: "h", port: 22, fingerprint: "aa")
        #expect(prompter.prompts.isEmpty)
        #expect(await store.admission(host: "h", port: 22, fingerprint: "aa") == .trusted)
    }

    @Test("密钥变化展示旧指纹和新指纹，拒绝时保留旧记录")
    func changedKeyShowsBothAndRejectKeepsOld() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let store = KnownHostsStore(fileURL: url)
        _ = await store.commit(.trustFirstUse(fingerprint: "aa"), host: "h", port: 22)
        let prompter = ScriptedHostKeyPrompter()
        prompter.decision = .reject
        do {
            try await HostKeyVerifier.verify(store: store, prompter: prompter, host: "h", port: 22, fingerprint: "bb")
            Issue.record("应拒绝")
        } catch let error as SSHError {
            #expect(error == .hostKeyRejected(host: "h", stored: "aa", received: "bb"))
        }
        #expect(prompter.prompts.first?.admission == .changed(stored: "aa", received: "bb"))
        #expect(await store.admission(host: "h", port: 22, fingerprint: "aa") == .trusted)
        #expect(HostKeyVerifier.commitAction(for: .changed(stored: "aa", received: "bb")) == .reset(expectedStored: "aa", fingerprint: "bb"))
    }

    @Test("接受新密钥后替换旧指纹")
    func acceptChangedKeyResets() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let store = KnownHostsStore(fileURL: url)
        _ = await store.commit(.trustFirstUse(fingerprint: "aa"), host: "h", port: 22)
        let prompter = ScriptedHostKeyPrompter()
        prompter.decision = .accept
        try await HostKeyVerifier.verify(store: store, prompter: prompter, host: "h", port: 22, fingerprint: "bb")
        #expect(await store.admission(host: "h", port: 22, fingerprint: "bb") == .trusted)
    }

    @Test("没有确认器时不静默信任")
    func missingPrompterDoesNotTrust() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let store = KnownHostsStore(fileURL: url)
        do {
            try await HostKeyVerifier.verify(store: store, prompter: nil, host: "h", port: 22, fingerprint: "aa")
            Issue.record("应失败")
        } catch let error as SSHError {
            #expect(error == .hostKeyConfirmationRequired(host: "h", fingerprint: "aa"))
        }
        #expect(await store.list().isEmpty)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("known-hosts-\(UUID().uuidString).json")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("lock"))
    }
}

nonisolated private final class ScriptedHostKeyPrompter: HostKeyPrompting, @unchecked Sendable {
    var decision: HostKeyPromptDecision = .reject
    var prompts: [HostKeyPrompt] = []

    func decide(_ prompt: HostKeyPrompt) async -> HostKeyPromptDecision {
        prompts.append(prompt)
        return decision
    }
}
