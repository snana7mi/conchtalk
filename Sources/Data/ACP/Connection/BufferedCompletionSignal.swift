import Foundation

/// 缓冲单次完成信号，避免完成通知早于等待注册时被丢失。
actor BufferedCompletionSignal {
    private var continuation: CheckedContinuation<Void, Error>?
    private var continuationToken = 0
    private var bufferedResult: Result<Void, Error>?
    private var bufferedToken = 0
    private var currentToken = 0

    func wait() async throws {
        if currentToken == 0 {
            currentToken = 1
        }
        try await wait(for: currentToken)
    }

    func succeed() {
        if currentToken == 0 {
            currentToken = 1
        }
        resolve(with: .success(()), for: currentToken)
    }

    func fail(_ error: Error) {
        if currentToken == 0 {
            currentToken = 1
        }
        resolve(with: .failure(error), for: currentToken)
    }

    func beginTurn() -> Int {
        currentToken += 1
        if bufferedToken != currentToken {
            bufferedResult = nil
            bufferedToken = 0
        }
        return currentToken
    }

    func activeTurnToken() -> Int {
        currentToken
    }

    func wait(for token: Int) async throws {
        if bufferedToken == token, let bufferedResult {
            self.bufferedResult = nil
            bufferedToken = 0
            try bufferedResult.get()
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            continuationToken = token
        }
    }

    func succeed(for token: Int) {
        resolve(with: .success(()), for: token)
    }

    func fail(_ error: Error, for token: Int) {
        resolve(with: .failure(error), for: token)
    }

    private func resolve(with result: Result<Void, Error>, for token: Int) {
        guard token == currentToken else { return }

        if let continuation, continuationToken == token {
            self.continuation = nil
            continuationToken = 0
            continuation.resume(with: result)
        } else {
            bufferedResult = result
            bufferedToken = token
        }
    }
}

actor BufferedResponseBuffer<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var bufferedResult: Result<Value, Error>?

    func wait() async throws -> Value {
        if let bufferedResult {
            self.bufferedResult = nil
            return try bufferedResult.get()
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func succeed(_ value: Value) {
        resolve(with: .success(value))
    }

    func fail(_ error: Error) {
        resolve(with: .failure(error))
    }

    private func resolve(with result: Result<Value, Error>) {
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else {
            bufferedResult = result
        }
    }
}
