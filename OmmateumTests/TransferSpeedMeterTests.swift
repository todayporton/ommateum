import Testing
@testable import Ommateum

struct TransferSpeedMeterTests {
    @Test func unknownUntilHalfASecondOfHistory() {
        var meter = TransferSpeedMeter()
        meter.add(bytes: 0, at: 10)
        meter.add(bytes: 1000, at: 10.3)
        #expect(meter.bytesPerSecond == nil)
        meter.add(bytes: 2000, at: 10.5)
        #expect(meter.bytesPerSecond == 4000)
    }

    @Test func averagesOnlyOverTheWindow() {
        var meter = TransferSpeedMeter(window: 3)
        // 1 MB/s for 10 s, then 4 MB/s.
        for second in 0...10 { meter.add(bytes: Int64(second) * 1_000_000, at: Double(second)) }
        for second in 11...20 { meter.add(bytes: 10_000_000 + Int64(second - 10) * 4_000_000, at: Double(second)) }
        #expect(meter.bytesPerSecond == 4_000_000)
    }

    @Test func remainingTimeAtCurrentSpeed() {
        var meter = TransferSpeedMeter()
        meter.add(bytes: 0, at: 0)
        meter.add(bytes: 1_000_000, at: 1)
        #expect(meter.secondsRemaining(completed: 1_000_000, total: 11_000_000) == 10)
        #expect(meter.secondsRemaining(completed: 11_000_000, total: 11_000_000) == nil)
    }

    @Test func stalledTransferHasNoEstimate() {
        var meter = TransferSpeedMeter()
        meter.add(bytes: 500, at: 0)
        meter.add(bytes: 500, at: 2)
        #expect(meter.bytesPerSecond == 0)
        #expect(meter.secondsRemaining(completed: 500, total: 1000) == nil)
    }
}
