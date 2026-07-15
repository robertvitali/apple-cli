import Testing
import Foundation
@testable import ContactsKit
import AppleKit

// Logic-tier tests for the pure helpers ported from apple-contacts-mcp utils.py /
// security.py. No Contacts TCC required (swift-testing, runnable in CI).

@Suite("Label translation (label_to_apple_token)")
struct LabelTranslationTests {
    @Test("human form → Apple token") func human() {
        #expect(labelToAppleToken("mobile") == "_$!<Mobile>!$_")
        #expect(labelToAppleToken("work") == "_$!<Work>!$_")
        #expect(labelToAppleToken("home fax") == "_$!<HomeFAX>!$_")
    }
    @Test("case-insensitive + whitespace-trimmed") func caseTrim() {
        #expect(labelToAppleToken("MOBILE") == "_$!<Mobile>!$_")
        #expect(labelToAppleToken("  Home Fax ") == "_$!<HomeFAX>!$_")
        #expect(labelToAppleToken("iPhone") == "_$!<iPhone>!$_")
    }
    @Test("Apple token passes through unchanged") func token() {
        #expect(labelToAppleToken("_$!<Mobile>!$_") == "_$!<Mobile>!$_")
    }
    @Test("custom label passes through unchanged") func custom() {
        #expect(labelToAppleToken("Spotify") == "Spotify")
        #expect(labelToAppleToken("Personal") == "Personal")
    }
    @Test("empty string returns empty") func empty() {
        #expect(labelToAppleToken("") == "")
    }
}

@Suite("Image-format detection (detect_image_format)")
struct ImageFormatTests {
    @Test("JPEG magic") func jpeg() {
        #expect(detectImageFormat([0xFF, 0xD8, 0xFF]) == "jpeg")
        #expect(detectImageFormat([0xFF, 0xD8, 0xFF, 0xE0, 0x00]) == "jpeg")
    }
    @Test("PNG magic") func png() {
        #expect(detectImageFormat([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) == "png")
    }
    @Test("GIF magic") func gif() {
        #expect(detectImageFormat(Array("GIF89a".utf8)) == "gif")
        #expect(detectImageFormat(Array("GIF87a".utf8)) == "gif")
    }
    @Test("HEIF-family ftyp brands → heic") func heic() {
        for brand in ["heic", "heix", "heif", "hevc", "hevx", "mif1", "msf1"] {
            let bytes: [UInt8] = [0x00, 0x00, 0x00, 0x18] + Array("ftyp".utf8) + Array(brand.utf8)
            #expect(detectImageFormat(bytes) == "heic", "brand \(brand)")
        }
    }
    @Test("unknown / short / empty never traps") func unknown() {
        #expect(detectImageFormat([]) == "unknown")
        #expect(detectImageFormat([0xFF]) == "unknown")
        #expect(detectImageFormat([0x00, 0x01, 0x02, 0x03, 0x04]) == "unknown")
        // ftyp with a non-HEIF brand is not heic
        let mp4: [UInt8] = [0, 0, 0, 0x18] + Array("ftyp".utf8) + Array("mp42".utf8)
        #expect(detectImageFormat(mp4) == "unknown")
    }
    @Test("Data overload agrees with [UInt8]") func dataOverload() {
        #expect(detectImageFormat(Data([0xFF, 0xD8, 0xFF])) == "jpeg")
    }
}

@Suite("AppleScript helpers")
struct AppleScriptHelperTests {
    @Test("escape backslash then quote") func escape() {
        #expect(escapeAppleScriptString(#"a"b\c"#) == #"a\"b\\c"#)
        #expect(escapeAppleScriptString("plain") == "plain")
    }
    @Test("not-found pattern (straight + curly apostrophe + invalid index)") func notFound() {
        #expect(isAppleScriptNotFound("execution error: Invalid index. (-1719)"))
        #expect(isAppleScriptNotFound("Contacts got an error: Can't get person 1"))
        #expect(isAppleScriptNotFound("Contacts got an error: Can’t get person 1"))
        #expect(!isAppleScriptNotFound("Application isn’t running. (-600)"))
        #expect(!isAppleScriptNotFound("some other failure"))
    }
}

@Suite("Domain error mapping")
struct ErrorMappingTests {
    @Test("safety_violation carries the MCP error.type + exit 77") func safety() {
        let e = AppleError.safetyViolation("nope")
        #expect(e.type == "safety_violation")
        #expect(e.exitCode == AppleExit.permissionDenied) // 77
    }
    @Test("validation / not_found map to MCP types + exit codes") func others() {
        #expect(AppleError.validation("x").type == "validation_error")
        #expect(AppleError.validation("x").exitCode == 64)
        #expect(AppleError.notFound("x").type == "not_found")
        #expect(AppleError.notFound("x").exitCode == 65)
        #expect(AppleError.permissionDenied("x").type == "authorization_denied")
        #expect(AppleError.permissionDenied("x").exitCode == 77)
    }
}
