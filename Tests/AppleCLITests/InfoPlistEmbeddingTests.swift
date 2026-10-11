import Foundation
import Testing

@Suite("apple executable Info.plist embedding")
struct AppleInfoPlistEmbeddingTests {
    @Test("built executable embeds non-empty Contacts usage metadata")
    func contactsUsageDescriptionIsEmbeddedInMachO() throws {
        let binary = try locateBuiltAppleExecutable()
        let plist = try embeddedInfoPlist(from: binary)
        let value = try #require(plist["NSContactsUsageDescription"] as? String)
        #expect(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    private func locateBuiltAppleExecutable() throws -> URL {
        let candidate = Bundle(for: TestBundleMarker.self)
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("apple")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw MetadataTestError("could not locate apple executable beside the current test bundle")
        }
        return candidate
    }

    private func embeddedInfoPlist(from binary: URL) throws -> [String: Any] {
        let file = try Data(contentsOf: binary)
        let section = try machOSection(file, segment: "__TEXT", section: "__info_plist")
        var bytes = section
        while bytes.last == 0 { bytes.removeLast() }
        guard !bytes.isEmpty else { throw MetadataTestError("empty __TEXT,__info_plist section") }
        let object = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil)
        guard let dict = object as? [String: Any] else { throw MetadataTestError("embedded plist is not a dictionary") }
        return dict
    }

    private func machOSection(_ file: Data, segment targetSegment: String, section targetSection: String) throws -> Data {
        guard readUInt32(file, 0) == 0xfeedfacf else { throw MetadataTestError("built apple is not a little-endian 64-bit Mach-O") }
        let ncmds = Int(readUInt32(file, 16))
        var offset = 32
        for _ in 0..<ncmds {
            let command = readUInt32(file, offset)
            let commandSize = Int(readUInt32(file, offset + 4))
            guard commandSize >= 8, offset + commandSize <= file.count else {
                throw MetadataTestError("malformed Mach-O load command")
            }
            if command == 0x19 { // LC_SEGMENT_64
                let segmentName = readCString(file, offset + 8, length: 16)
                let sectionCount = Int(readUInt32(file, offset + 64))
                var sectionOffset = offset + 72
                for _ in 0..<sectionCount {
                    guard sectionOffset + 80 <= offset + commandSize else {
                        throw MetadataTestError("malformed Mach-O section")
                    }
                    let sectionName = readCString(file, sectionOffset, length: 16)
                    let sectionSegment = readCString(file, sectionOffset + 16, length: 16)
                    if segmentName == targetSegment, sectionSegment == targetSegment, sectionName == targetSection {
                        let size = Int(readUInt64(file, sectionOffset + 40))
                        let fileOffset = Int(readUInt32(file, sectionOffset + 48))
                        guard fileOffset >= 0, size >= 0, fileOffset + size <= file.count else {
                            throw MetadataTestError("Mach-O plist section points outside the file")
                        }
                        return file.subdata(in: fileOffset..<(fileOffset + size))
                    }
                    sectionOffset += 80
                }
            }
            offset += commandSize
        }
        throw MetadataTestError("missing __TEXT,__info_plist section")
    }

    private func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private func readUInt64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(readUInt32(data, offset)) | UInt64(readUInt32(data, offset + 4)) << 32
    }

    private func readCString(_ data: Data, _ offset: Int, length: Int) -> String {
        let bytes = data[offset..<(offset + length)].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private struct MetadataTestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private final class TestBundleMarker {}
