import Testing
@testable import SpottyGateway

struct KeymasterReceiptChecks {
    @Test
    func receiptCanCompleteWithNilAndRejectLaterResolutions() async {
        let receipt = KeymasterPersistenceReceipt<Int?>()
        receipt.resolve(nil)
        receipt.resolve(7)
        #expect(await receipt.value() == nil)
        #expect(await receipt.value() == nil)
    }

    @Test
    func concurrentReceiptWaitersAllReceiveTheFirstResolution() async {
        let receipt = KeymasterPersistenceReceipt<Int>()
        let values = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<32 {
                group.addTask { await receipt.value() }
            }
            group.addTask {
                receipt.resolve(7)
                receipt.resolve(9)
                return await receipt.value()
            }
            var values: [Int] = []
            for await value in group { values.append(value) }
            return values
        }
        #expect(values.count == 33)
        #expect(values.allSatisfy { $0 == 7 })
    }

}
