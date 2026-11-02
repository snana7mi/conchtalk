/// 文件说明：HostKeyVerifier，在写入已知主机之前先向用户确认 SHA256 指纹。
import Foundation
import NIOCore
import NIOSSH
import os

/// HostKeyVerifier：
/// 把「读当前记录」和「用户点头之后的比较写入」拆开。
/// 首次连接不再静默信任；密钥变化时带着旧指纹和新指纹去确认。
nonisolated enum HostKeyVerifier {
    /// 根据当前准入决定能不能继续握手。用户拒绝或没有确认器时不写盘。
    static func verify(
        store: KnownHostsStore,
        prompter: (any HostKeyPrompting)?,
        host: String,
        port: Int,
        fingerprint: String
    ) async throws {
        for _ in 0..<3 {
            let admission = await store.admission(host: host, port: port, fingerprint: fingerprint)
            switch admission {
            case .trusted:
                return
            case .firstUse, .changed:
                guard let prompter else {
                    throw unconfirmedError(admission, host: host)
                }
                let prompt = HostKeyPrompt(id: UUID(), host: host, port: port, admission: admission)
                let decision = await prompter.decide(prompt)
                guard decision == .accept else {
                    throw rejectedError(admission, host: host)
                }
                guard let action = commitAction(for: admission) else { return }
                if case .trusted = await store.commit(action, host: host, port: port) {
                    return
                }
            }
        }
        let admission = await store.admission(host: host, port: port, fingerprint: fingerprint)
        throw unconfirmedError(admission, host: host)
    }

    /// 用户接受后要执行的原子写入。已信任的记录不需要再写。
    static func commitAction(for admission: HostKeyAdmission) -> HostKeyCommit? {
        switch admission {
        case .trusted:
            return nil
        case .firstUse(let fingerprint):
            return .trustFirstUse(fingerprint: fingerprint)
        case .changed(let stored, let received):
            return .reset(expectedStored: stored, fingerprint: received)
        }
    }

    private static func rejectedError(_ admission: HostKeyAdmission, host: String) -> SSHError {
        switch admission {
        case .trusted:
            return .hostKeyRejected(host: host, stored: nil, received: "")
        case .firstUse(let fingerprint):
            return .hostKeyRejected(host: host, stored: nil, received: fingerprint)
        case .changed(let stored, let received):
            return .hostKeyRejected(host: host, stored: stored, received: received)
        }
    }

    private static func unconfirmedError(_ admission: HostKeyAdmission, host: String) -> SSHError {
        switch admission {
        case .trusted:
            return .connectionFailed(String(localized: "Host key state changed during confirmation", bundle: LanguageSettings.currentBundle))
        case .firstUse(let fingerprint):
            return .hostKeyConfirmationRequired(host: host, fingerprint: fingerprint)
        case .changed(let stored, let received):
            return .hostKeyMismatch(host: host, stored: stored, received: received)
        }
    }
}

/// ConfirmingHostKeyValidator：
/// 在 NIO 的主机密钥回调里挂起，等 `HostKeyVerifier` 完成确认后再兑现 promise。
nonisolated final class ConfirmingHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let store: KnownHostsStore
    private let host: String
    private let port: Int
    private let prompter: (any HostKeyPrompting)?

    init(store: KnownHostsStore, host: String, port: Int, prompter: (any HostKeyPrompting)?) {
        self.store = store
        self.host = host
        self.port = port
        self.prompter = prompter
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fingerprint = KnownHostsStore.fingerprint(of: hostKey)
        let store = self.store
        let host = self.host
        let port = self.port
        let prompter = self.prompter
        let once = OSAllocatedUnfairLock(initialState: false)

        Task {
            do {
                try await HostKeyVerifier.verify(
                    store: store,
                    prompter: prompter,
                    host: host,
                    port: port,
                    fingerprint: fingerprint
                )
                Self.complete(once, promise: validationCompletePromise, result: .success(()))
            } catch {
                Self.complete(once, promise: validationCompletePromise, result: .failure(error))
            }
        }
    }

    /// promise 只能完成一次；取消和确认撞在一起时丢掉后一次。
    private static func complete(
        _ once: OSAllocatedUnfairLock<Bool>,
        promise: EventLoopPromise<Void>,
        result: Result<Void, Error>
    ) {
        let first = once.withLock { done -> Bool in
            if done { return false }
            done = true
            return true
        }
        guard first else { return }
        switch result {
        case .success:
            promise.succeed(())
        case .failure(let error):
            promise.fail(error)
        }
    }
}
