//
//  CompilePolicyHarnessTests.swift
//  CompilePolicyTests
//
//  Harness placeholder. Later work populates the real negative-compile checks
//  (implicit time-type mixing must fail to compile; scope and mechanism per
//  symbol-graph and grep policies
//  are CI jobs, deliberately NOT compile tests).
//

import Foundation
import Testing

/// The executable half lives in scripts/check-compile-policy.sh (a host-side
/// CI job: `swiftc -typecheck` cannot run inside a simulator test bundle).
/// This suite pins the fixture contract so a fixture rename/removal fails
/// visibly in the test run too.
struct CompilePolicyHarnessTests {
    @Test func fixtureContractIsPresent() throws {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        let names = try FileManager.default.contentsOfDirectory(atPath: fixtures.path)
        #expect(names.contains("implicit-installed-to-observed-must-fail.swift"))
        #expect(names.contains("explicit-conversion-must-compile.swift"))
    }
}
