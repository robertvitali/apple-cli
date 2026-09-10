import Foundation
import Testing
import TestSupport

@Suite("Shared write-posture environment window", .serialized)
struct WritePostureEnvironmentTests {
    @Test("the shared pin clears every posture variable and restores the enclosing values")
    func pinnedWindowClearsAndRestores() {
        let outer: [String: String?] = Dictionary(uniqueKeysWithValues:
            TestEnvironment.writeModeVariables.enumerated().map { index, key in
                (key, "apple-cli-test-outer-\(index)")
            })
        TestEnvironment.with(outer) {
            for (key, expected) in outer {
                #expect(getenv(key).map { String(cString: $0) } == expected)
            }
            TestEnvironment.withoutWriteModeOverrides {
                for key in TestEnvironment.writeModeVariables {
                    #expect(getenv(key) == nil, "\(key) must be absent inside the shared pin")
                }
            }
            for (key, expected) in outer {
                #expect(getenv(key).map { String(cString: $0) } == expected,
                        "\(key) must be restored after the shared pin closes")
            }
        }
    }
}
