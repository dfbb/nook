#if DEBUG
import Testing
@testable import NookKit

/// Perf gates read a flag only as its own argument followed by a value, so the
/// key appearing as another flag's value, or with nothing after it, is inert.
struct PerfLaunchTests {
    @Test func readsTheValueAfterTheKey() {
        #expect(PerfLaunch.value(for: "-NookPerfLibrary", in: ["Nook", "-NookPerfLibrary", "/tmp/lib"]) == "/tmp/lib")
    }

    @Test func ignoresAKeyWithNoValue() {
        #expect(PerfLaunch.value(for: "-NookPerfLibrary", in: ["Nook", "-NookPerfLibrary"]) == nil)
    }

    @Test func ignoresAKeyThatOnlyAppearsInsideAnotherValue() {
        #expect(PerfLaunch.value(for: "-NookPerfLibrary", in: ["Nook", "-NookPerfLabel", "x-NookPerfLibrary"]) == nil)
    }
}
#endif
