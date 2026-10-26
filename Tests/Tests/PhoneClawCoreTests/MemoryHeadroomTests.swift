import XCTest
@testable import PhoneClawCore

final class MemoryHeadroomTests: XCTestCase {
    func testSimulatorKeepsHistoryBudgetWhenKernelReportsNoLimit() {
        XCTAssertEqual(MemoryStats.calculateHeadroomMB(footprint: 4200, limit: 4200, simulated: true), 1944)
    }

    func testDeviceUsesReportedLimitAndDoesNotInventFreeMemory() {
        XCTAssertEqual(MemoryStats.calculateHeadroomMB(footprint: 4200, limit: 5000, simulated: false), 800)
        XCTAssertEqual(MemoryStats.calculateHeadroomMB(footprint: 4200, limit: 4200, simulated: false), 0)
    }

    func testMemoryPressureAndInvalidMeasurementsClampToZero() {
        XCTAssertEqual(MemoryStats.calculateHeadroomMB(footprint: 6500, limit: 6500, simulated: true), 0)
        XCTAssertEqual(MemoryStats.calculateHeadroomMB(footprint: .nan, limit: 5000, simulated: true), 0)
        XCTAssertEqual(MemoryStats.calculateHeadroomMB(footprint: -1, limit: 5000, simulated: true), 0)
    }
}
