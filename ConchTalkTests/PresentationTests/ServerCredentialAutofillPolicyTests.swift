/// 文件说明：ServerCredentialAutofillPolicyTests，测试服务器表单字段不会参与系统凭据自动填充。
import Testing
@testable import ConchTalk
#if os(iOS)
import UIKit

@Suite("Server Credential Autofill Policy")
struct ServerCredentialAutofillPolicyTests {
    @Test("credential fields use one-time-code strategy to avoid password save heuristics")
    func credentialsUseOneTimeCodeStrategy() {
        #expect(ServerCredentialField.username.textContentType == .oneTimeCode)
        #expect(ServerCredentialField.password.textContentType == .oneTimeCode)
    }

    @Test("non-credential fields keep their default autofill behavior")
    func nonCredentialsKeepDefaultAutofillBehavior() {
        #expect(ServerCredentialField.name.textContentType == nil)
        #expect(ServerCredentialField.host.textContentType == nil)
        #expect(ServerCredentialField.port.textContentType == nil)
    }
}
#endif
