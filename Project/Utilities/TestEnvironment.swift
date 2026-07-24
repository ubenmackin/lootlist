import Foundation

enum TestEnvironment {
    /// Detects if the current process is running unit tests (XCTest/Swift Testing) or UI tests.
    static var isRunningUnitOrUITests: Bool {
        // XCTestConfigurationFilePath is set in processes run by Xcode test runners
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }

        // When UI tests run the XCTest framework is loaded into the app process;
        // checking for XCTestCase presence is a common technique.
        if NSClassFromString("XCTestCase") != nil {
            return true
        }

        // Custom launch arguments passed during XCUI test runs
        if CommandLine.arguments.contains("--uitesting") || CommandLine.arguments.contains("--skip-cloudkit") {
            return true
        }

        return false
    }
}
