import Darwin
import Foundation
import Testing
@testable import SpottySessionRuntime

/// Resource-turnover probe, not an app memory budget. No requests or external services are used.
struct ArtworkSourceLoaderMeasurementTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPOTTY_ARTWORK_MEASUREMENT_REPORT"] != nil))
    func measureIdleLoaderTurnover() async throws {
        var samples = [[String: UInt64]]()
        for wave in 0...5 {
            if wave > 0 {
                for _ in 0..<200 {
                    let loader = ArtworkSourceLoader()
                    await loader.cancelAll()
                }
            }
            var memory = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &memory) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            try #require(status == KERN_SUCCESS)
            samples.append(["loadersRetired": UInt64(wave * 200), "physicalFootprintBytes": memory.phys_footprint])
        }
        let report = try JSONSerialization.data(
            withJSONObject: ["version": 1, "samples": samples], options: [.prettyPrinted, .sortedKeys])
        let path = try #require(ProcessInfo.processInfo.environment["SPOTTY_ARTWORK_MEASUREMENT_REPORT"])
        try report.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
