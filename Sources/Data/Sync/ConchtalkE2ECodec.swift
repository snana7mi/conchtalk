import Foundation
import LLMGatewayKit

struct ConchtalkE2ECodec: SyncPayloadCodec {
    private let crypto: SyncCryptoService

    init(crypto: SyncCryptoService) {
        self.crypto = crypto
    }

    func encode(_ plaintext: Data, entityType: String) async throws -> Data {
        guard let syncEntityType = SyncEntityType(rawValue: entityType) else {
            throw SyncCryptoError.unknownEntityType(entityType)
        }
        return try await crypto.encrypt(plaintext, entityType: syncEntityType)
    }

    func decode(_ wire: Data, entityType: String) async throws -> Data {
        guard let syncEntityType = SyncEntityType(rawValue: entityType) else {
            throw SyncCryptoError.unknownEntityType(entityType)
        }
        return try await crypto.decrypt(wire, entityType: syncEntityType)
    }
}
