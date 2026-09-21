import Foundation
import XCTest
@testable import WorkTempoCore

final class CollectorResolverTests: XCTestCase {
    func testResolutionPrefersExplicitThenHomeThenFixedThenPath() throws {
        let home = URL(fileURLWithPath: "/home/tester")
        let homeCandidate = home.appending(path: ".local/bin/work-tempo")
        let fixed = URL(fileURLWithPath: "/fixed/work-tempo")
        let path = URL(fileURLWithPath: "/ambient/work-tempo")
        var available = Set([homeCandidate.path, fixed.path, path.path])
        let resolver = CollectorResolver(
            homeDirectory: home,
            environmentPath: "/ambient",
            fixedCandidates: [fixed],
            isExecutable: { available.contains($0.path) }
        )

        XCTAssertEqual(try resolver.resolve(), homeCandidate)

        available.remove(homeCandidate.path)
        XCTAssertEqual(try resolver.resolve(), fixed)

        available.remove(fixed.path)
        XCTAssertEqual(try resolver.resolve(), path)

        let explicit = URL(fileURLWithPath: "/chosen/work-tempo")
        available.insert(explicit.path)
        XCTAssertEqual(try resolver.resolve(explicit: explicit), explicit)
    }

    func testInvalidExplicitOverrideDoesNotFallBack() {
        let resolver = CollectorResolver(
            homeDirectory: URL(fileURLWithPath: "/home/tester"),
            environmentPath: "/ambient",
            fixedCandidates: [],
            isExecutable: { $0.path == "/ambient/work-tempo" }
        )
        let explicit = URL(fileURLWithPath: "/missing/work-tempo")

        XCTAssertThrowsError(try resolver.resolve(explicit: explicit)) { error in
            XCTAssertEqual(error as? CollectorResolutionError, .explicitNotExecutable(explicit.path))
        }
    }

    func testMissingErrorListsEverySearchedLocation() {
        let resolver = CollectorResolver(
            homeDirectory: URL(fileURLWithPath: "/home/tester"),
            environmentPath: "/ambient-one:/ambient-two",
            fixedCandidates: [URL(fileURLWithPath: "/fixed/work-tempo")],
            isExecutable: { _ in false }
        )

        XCTAssertThrowsError(try resolver.resolve()) { error in
            guard case let CollectorResolutionError.notFound(searched) = error else {
                return XCTFail("Expected a not-found error")
            }
            XCTAssertEqual(searched, [
                "/home/tester/.local/bin/work-tempo",
                "/fixed/work-tempo",
                "/ambient-one/work-tempo",
                "/ambient-two/work-tempo",
            ])
        }
    }
}
