import Foundation

/// A test harness small enough to have no dependencies. XCTest ships with Xcode,
/// not with the Command Line Tools, and this project builds with either.
enum Check {
    nonisolated(unsafe) private static var failures: [String] = []
    nonisolated(unsafe) private static var passed = 0
    nonisolated(unsafe) private static var currentCase = ""

    static func suite(_ name: String, _ body: () -> Void) {
        print("\u{2022} \(name)")
        body()
    }

    static func test(_ name: String, _ body: () -> Void) {
        currentCase = name
        body()
    }

    static func that(_ condition: Bool, _ description: String, line: UInt = #line) {
        record(condition, "\(description)", line: line)
    }

    static func equal<T: Equatable>(_ actual: T, _ expected: T, _ description: String, line: UInt = #line) {
        record(actual == expected, "\(description): expected \(expected), got \(actual)", line: line)
    }

    static func nil_<T>(_ value: T?, _ description: String, line: UInt = #line) {
        record(value == nil, "\(description): expected nil, got \(String(describing: value))", line: line)
    }

    private static func record(_ ok: Bool, _ message: String, line: UInt) {
        if ok {
            passed += 1
        } else {
            failures.append("  \u{2717} \(currentCase) (line \(line)) \u{2014} \(message)")
        }
    }

    static func report() -> Never {
        for failure in failures { print(failure) }
        print("\n\(passed) passed, \(failures.count) failed")
        exit(failures.isEmpty ? 0 : 1)
    }
}
