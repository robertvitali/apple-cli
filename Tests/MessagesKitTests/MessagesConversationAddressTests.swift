import Testing
@testable import MessagesKit

@Suite("Conversation creation address identity")
struct MessagesConversationAddressTests {
    @Test(arguments: ["+1 (212) 555-0100", "+1.212.555.0100", "  +12125550100  "])
    func phoneFormatting(_ raw: String) throws {
        let address = try MessagesConversationAddress.parse(raw)
        #expect(address.kind == .phone)
        #expect(address.canonical == "+12125550100")
    }

    @Test(arguments: [
        "", "   ", "+", "+1", "+012", "+1234567890123456", "2125550100",
        "0012125550100", "+1+2125550100", "+1 ((212)) 5550100", "+1 (212 5550100",
        "+1 212) 5550100", "+12125550100 ext 42", "+12125550100X-IMAGETYPE",
        "+１２１２５５５０１００", "+١٢١٢٥٥٥٠١٠٠", "\u{00a0}+12125550100",
        "\u{200b}+12125550100", "\u{202e}+12125550100", "+12125550100/42",
    ])
    func refusesUnsupportedPhone(_ raw: String) {
        #expect(throws: MessagesConversationAddress.ParseError.unsupportedAddress) {
            try MessagesConversationAddress.parse(raw)
        }
    }

    @Test(arguments: Array(UInt8(0)...UInt8(31)) + [127])
    func refusesControlsBeforeTrimming(_ byte: UInt8) {
        let control = String(Unicode.Scalar(byte))
        for raw in [control + "+12125550100", "+12125550100" + control,
                    "Alice@" + control + "example.com"] {
            #expect(throws: MessagesConversationAddress.ParseError.unsupportedAddress) {
                try MessagesConversationAddress.parse(raw)
            }
        }
    }

    @Test func emailPreservesLocalIdentity() throws {
        let a = try MessagesConversationAddress.parse(" Alice.Tag+label@EXAMPLE.COM ")
        #expect(a.kind == .email)
        #expect(a.canonical == "Alice.Tag+label@example.com")
        #expect(try a != MessagesConversationAddress.parse("alice.tag+label@example.com"))
        #expect(try a != MessagesConversationAddress.parse("AliceTag@example.com"))
        #expect(try a == MessagesConversationAddress.parse("Alice.Tag+label@example.com"))
    }

    @Test(arguments: [
        "a", "@example.com", "a@", "a@@example.com", ".a@example.com",
        "a.@example.com", "a..b@example.com", "a b@example.com", "\"a\"@example.com",
        "a@example", "a@.example.com", "a@example..com", "a@example.com.",
        "a@-example.com", "a@example-.com", "a@exa_mple.com", "a@[127.0.0.1]",
        "é@example.com", "a@éxample.com", "a\u{0301}@example.com", "a@example.com\u{00a0}",
    ])
    func refusesUnsupportedEmail(_ raw: String) {
        #expect(throws: MessagesConversationAddress.ParseError.unsupportedAddress) {
            try MessagesConversationAddress.parse(raw)
        }
    }

    @Test func emailAtomPunctuation() throws {
        let local = "!#$%&'*+-/=?^_`{|}~"
        #expect(try MessagesConversationAddress.parse(local + "@example.com").canonical
                == local + "@example.com")
    }

    @Test func byteBoundaries() throws {
        let maxLocal = String(repeating: "a", count: 64)
        let label = String(repeating: "b", count: 63)
        let email = maxLocal + "@" + label + "." + label + "." + String(repeating: "c", count: 61)
        #expect(email.utf8.count == 254)
        #expect(try MessagesConversationAddress.parse(email).canonical == email)
        for raw in ["a" + email, email + "c", "a@" + label + "b.com"] {
            #expect(throws: MessagesConversationAddress.ParseError.unsupportedAddress) {
                try MessagesConversationAddress.parse(raw)
            }
        }
        let padded = String(repeating: " ", count: 258) + email
        #expect(padded.utf8.count == 512)
        #expect(try MessagesConversationAddress.parse(padded).canonical == email)
        #expect(throws: MessagesConversationAddress.ParseError.rawAddressTooLong) {
            try MessagesConversationAddress.parse(" " + padded)
        }
        #expect(throws: MessagesConversationAddress.ParseError.rawAddressTooLong) {
            try MessagesConversationAddress.parse(String(repeating: "a", count: 1_000_000))
        }
    }

    @Test func internationalPhoneBoundaries() throws {
        for raw in ["+12", "+123456789012345"] {
            #expect(try MessagesConversationAddress.parse(raw).canonical == raw)
        }
    }

    @Test(arguments: ["+1 (212) 555-0100", "Alice@EXAMPLE.COM", "a.b+tag@example.org"])
    func canonicalizationIsIdempotent(_ raw: String) throws {
        let address = try MessagesConversationAddress.parse(raw)
        #expect(try MessagesConversationAddress.parse(address.canonical) == address)
    }

    @Test func duplicatesUseExactCanonicalIdentity() throws {
        let inputs = ["+1 (212) 555-0100", "+1.212.555.0100", "Alice@EXAMPLE.COM",
                      "Alice@example.com", "alice@example.com", "a.b+tag@example.com",
                      "ab@example.com"]
        let addresses = try inputs.map(MessagesConversationAddress.parse)
        #expect(Set(addresses).count == 5)
    }

    @Test func failuresContainNoRawInput() {
        for error in [MessagesConversationAddress.ParseError.unsupportedAddress, .rawAddressTooLong] {
            #expect(!String(describing: error).contains("@"))
            #expect(!String(describing: error).contains("+1212"))
        }
    }
    @Test(arguments: ["+tag@example.com", "+Tag@EXAMPLE.COM", "+12125550100@example.com", "+@example.com"])
    func leadingPlusEmailUsesEmailGrammar(_ raw: String) throws {
        let address = try MessagesConversationAddress.parse(raw)
        #expect(address.kind == .email)
        let expected = raw.split(separator: "@")[0] + "@example.com"
        #expect(address.canonical == expected)
        #expect(try MessagesConversationAddress.parse(address.canonical) == address)
    }

}
