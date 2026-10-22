import Foundation
import Testing
@testable import ReportKit

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
private let gb: Int64 = 1_000_000_000

private let diskOnly = AlertThresholds(diskFreeBelowBytes: 10 * gb, memoryRedMinutes: nil, temperatureAboveCelsius: nil, batteryCapacityBelowPercent: nil)
private let memoryOnly = AlertThresholds(diskFreeBelowBytes: nil, memoryRedMinutes: 5, temperatureAboveCelsius: nil, batteryCapacityBelowPercent: nil)

private extension AlertEngine {
    mutating func disk(_ minutes: Double, _ gigabytes: Double) -> [AlertKind] {
        evaluate(AlertSample(date: at(minutes), diskAvailable: Int64(gigabytes * 1e9))).map(\.kind)
    }
    mutating func pressure(_ minutes: Double, _ raw: Int) -> [AlertKind] {
        evaluate(AlertSample(date: at(minutes), pressure: raw)).map(\.kind)
    }
}

@Suite("AlertEngine")
struct AlertEngineTests {
    @Test("Disk: enter fires once, sustain stays quiet, recovery past +10 % re-arms")
    func diskSequence() {
        var engine = AlertEngine(thresholds: diskOnly)
        #expect(engine.disk(0, 20) == [])
        let fired = engine.evaluate(AlertSample(date: at(1), diskAvailable: 9 * gb))
        #expect(fired == [AlertEvent(kind: .diskLow, value: Double(9 * gb), threshold: Double(10 * gb))])
        #expect(engine.disk(2, 8) == [])          // sustained
        #expect(engine.disk(3, 10.5) == [])       // above threshold but inside hysteresis: not re-armed
        #expect(!engine.isArmed(.diskLow))
        #expect(engine.disk(4, 9) == [])          // still the same crossing
        #expect(engine.disk(5, 11) == [])         // ≥ 11 GB: re-armed
        #expect(engine.isArmed(.diskLow))
        #expect(engine.disk(6 * 60 + 2, 9) == [.diskLow])  // new crossing after the cool-down
    }

    @Test("Cool-down: a re-armed crossing within 6 h waits until the cool-down ends")
    func coolDown() {
        var engine = AlertEngine(thresholds: diskOnly)
        #expect(engine.disk(0, 5) == [.diskLow])
        #expect(engine.disk(60, 20) == [])        // recovered, re-armed
        #expect(engine.disk(120, 5) == [])        // crossing inside cool-down: suppressed
        #expect(engine.disk(359, 5) == [])
        #expect(engine.disk(360, 5) == [.diskLow])  // exactly 6 h after the first alert
        #expect(engine.disk(361, 5) == [])
        #expect(engine.lastFired(.diskLow) == at(360))
    }

    @Test("Temperature re-arms at threshold − 5 °C; battery at threshold + 1 point")
    func temperatureAndBattery() {
        var engine = AlertEngine(thresholds: AlertThresholds(diskFreeBelowBytes: nil, memoryRedMinutes: nil,
                                                             temperatureAboveCelsius: 95, batteryCapacityBelowPercent: 80))
        func temp(_ m: Double, _ c: Double) -> [AlertKind] { engine.evaluate(AlertSample(date: at(m), temperatureCelsius: c)).map(\.kind) }
        func batt(_ m: Double, _ p: Double) -> [AlertKind] { engine.evaluate(AlertSample(date: at(m), batteryMaxCapacityPercent: p)).map(\.kind) }
        #expect(temp(0, 95) == [])                // not above
        #expect(temp(1, 96) == [.temperatureHigh])
        #expect(temp(2, 91) == [])
        #expect(!engine.isArmed(.temperatureHigh))
        #expect(temp(3, 90) == [])
        #expect(engine.isArmed(.temperatureHigh))

        #expect(batt(0, 80) == [])
        #expect(batt(1, 79) == [.batteryWorn])
        #expect(batt(2, 80.5) == [])
        #expect(!engine.isArmed(.batteryWorn))
        #expect(batt(3, 81) == [])
        #expect(engine.isArmed(.batteryWorn))
        #expect(batt(400, 79.5) == [.batteryWorn])
    }

    @Test("Memory red needs critical pressure continuously for the set minutes")
    func memoryDuration() {
        var engine = AlertEngine(thresholds: memoryOnly)
        #expect(engine.pressure(0, 4) == [])
        #expect(engine.pressure(2, 4) == [])
        #expect(engine.pressure(3, 2) == [])      // warning breaks the run
        #expect(engine.pressure(4, 4) == [])      // run restarts at 4
        #expect(engine.pressure(8.5, 4) == [])    // 4.5 min
        let events = engine.evaluate(AlertSample(date: at(9), pressure: 4))
        #expect(events == [AlertEvent(kind: .memoryRed, value: 5, threshold: 5)])
        #expect(engine.pressure(15, 4) == [])     // sustained
        #expect(engine.pressure(16, 1) == [])
        #expect(engine.pressure(17, 1) == [])     // 1 min calm: not re-armed
        #expect(!engine.isArmed(.memoryRed))
        #expect(engine.pressure(17.5, 4) == [])   // calm run broken
        #expect(engine.pressure(18, 1) == [])
        #expect(engine.pressure(20, 1) == [])     // 2 min calm: re-armed
        #expect(engine.isArmed(.memoryRed))
        // A new 5-minute run after the cool-down fires again.
        for m in stride(from: 400.0, through: 404.5, by: 0.5) { #expect(engine.pressure(m, 4) == []) }
        #expect(engine.pressure(405, 4) == [.memoryRed])
    }

    @Test("A long gap between samples restarts the memory run")
    func memoryGap() {
        var engine = AlertEngine(thresholds: memoryOnly)
        #expect(engine.pressure(0, 4) == [])
        #expect(engine.pressure(30, 4) == [])     // 30 min later (Mac was asleep): run restarts here
        #expect(engine.pressure(34, 4) == [])
        #expect(engine.pressure(35, 4) == [.memoryRed])
    }

    @Test("State survives encoding, so a relaunch doesn't repeat an alert")
    func codable() throws {
        var engine = AlertEngine(thresholds: diskOnly)
        #expect(engine.disk(0, 5) == [.diskLow])
        let data = try JSONEncoder().encode(engine)
        var restored = try JSONDecoder().decode(AlertEngine.self, from: data)
        #expect(restored == engine)
        #expect(restored.disk(1, 5) == [])
        #expect(restored.disk(2, 20) == [])
        #expect(restored.disk(3, 5) == [])        // cool-down kept across the round trip
    }

    @Test("Changing a threshold re-arms that kind; nil thresholds and missing readings do nothing")
    func thresholdsChange() {
        var engine = AlertEngine(thresholds: diskOnly)
        #expect(engine.disk(0, 5) == [.diskLow])
        #expect(engine.disk(1, 5) == [])
        var raised = diskOnly
        raised.diskFreeBelowBytes = 30 * gb
        engine.update(thresholds: raised)
        #expect(engine.disk(2, 25) == [.diskLow])

        var off = AlertEngine(thresholds: AlertThresholds(diskFreeBelowBytes: nil, memoryRedMinutes: nil,
                                                          temperatureAboveCelsius: nil, batteryCapacityBelowPercent: nil))
        #expect(off.evaluate(AlertSample(date: at(0), diskAvailable: 0, pressure: 4, temperatureCelsius: 120, batteryMaxCapacityPercent: 10)) == [])
        var defaults = AlertEngine()
        #expect(defaults.evaluate(AlertSample(date: at(0))) == [])
        #expect(defaults.evaluate(AlertSample(date: at(1), diskAvailable: 1 * gb, temperatureCelsius: 100, batteryMaxCapacityPercent: 70)).map(\.kind)
                == [.diskLow, .temperatureHigh, .batteryWorn])
    }
}

@Suite("CoffeePrompt")
struct CoffeePromptTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 86_400

    @Test("Shows after 2 GB or more, at most once per 30 days, never after Don't ask again")
    func policy() {
        #expect(!CoffeePrompt.shouldShow(freedBytes: 1_999_999_999, lastShown: nil, dismissedForever: false, now: now))
        #expect(CoffeePrompt.shouldShow(freedBytes: 2_000_000_000, lastShown: nil, dismissedForever: false, now: now))
        #expect(!CoffeePrompt.shouldShow(freedBytes: 14_000_000_000, lastShown: now.addingTimeInterval(-29 * day), dismissedForever: false, now: now))
        #expect(!CoffeePrompt.shouldShow(freedBytes: 14_000_000_000, lastShown: now.addingTimeInterval(-30 * day + 1), dismissedForever: false, now: now))
        #expect(CoffeePrompt.shouldShow(freedBytes: 14_000_000_000, lastShown: now.addingTimeInterval(-30 * day), dismissedForever: false, now: now))
        #expect(CoffeePrompt.shouldShow(freedBytes: 14_000_000_000, lastShown: now.addingTimeInterval(-90 * day), dismissedForever: false, now: now))
        #expect(!CoffeePrompt.shouldShow(freedBytes: 14_000_000_000, lastShown: nil, dismissedForever: true, now: now))
        #expect(!CoffeePrompt.shouldShow(freedBytes: 14_000_000_000, lastShown: now.addingTimeInterval(-90 * day), dismissedForever: true, now: now))
    }
}
