import Testing
import Foundation
@testable import KeelMac

@Suite("Routes")
struct RouteTests {
    @Test func everyRouteBelongsToOneSection() {
        let fromSections = Route.Section.allCases.flatMap(\.routes)
        #expect(Set(fromSections) == Set(Route.allCases))
        #expect(fromSections.count == Route.allCases.count)
    }

    @Test func urlScheme() {
        #expect(Route(url: URL(string: "keelmac://open/cleanup")!) == .cleanup)
        #expect(Route(url: URL(string: "keelmac://open/nope")!) == nil)
        #expect(Route(url: URL(string: "https://open/cleanup")!) == nil)
    }

    @Test func shortcutsForFirstNine() {
        #expect(Route.allCases.compactMap(\.shortcut).count == 9)
    }
}
