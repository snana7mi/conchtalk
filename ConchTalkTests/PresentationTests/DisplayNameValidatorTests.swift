/// 文件说明:DisplayNameValidatorTests,验证客户端昵称校验(trim/非空/限长)。
import Testing
@testable import ConchTalk

@Suite("DisplayNameValidator")
struct DisplayNameValidatorTests {
    @Test("去首尾空白并接受有效名")
    func valid() {
        #expect(DisplayNameValidator.validate("  Alice  ") == "Alice")
    }

    @Test("空/纯空白返回 nil")
    func empty() {
        #expect(DisplayNameValidator.validate("   ") == nil)
        #expect(DisplayNameValidator.validate("") == nil)
    }

    @Test("超过 24 grapheme 返回 nil")
    func tooLong() {
        #expect(DisplayNameValidator.validate(String(repeating: "x", count: 25)) == nil)
    }

    @Test("正好 24 grapheme 通过")
    func boundary() {
        #expect(DisplayNameValidator.validate(String(repeating: "x", count: 24)) != nil)
    }
}
