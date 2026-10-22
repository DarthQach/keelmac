import Foundation
import Testing
@testable import AppsKit

@Suite struct LaunchAdvisorTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func item(_ label: String, domain: LaunchDomain = .userAgent, schedule: LaunchSchedule = .atLoad,
              program: String? = nil, ownerInstalled: Bool = true, disabled: Bool = false,
              bundleID: String? = nil) -> LaunchItem {
        let folder = domain == .userAgent ? "/Users/u/Library/LaunchAgents" : "/Library/LaunchAgents"
        return LaunchItem(label: label, plistPath: "\(folder)/\(label).plist", program: program, domain: domain,
                          schedule: schedule, ownerName: "App", ownerInstalled: ownerInstalled, isDisabled: disabled,
                          ownerBundleID: bundleID)
    }

    func app(_ bundleID: String, lastUsedDaysAgo days: Double?) -> InstalledApp {
        InstalledApp(name: bundleID, path: "/Applications/\(bundleID).app", bundleID: bundleID, version: nil, teamID: nil,
                     bytes: nil, lastUsed: days.map { now.addingTimeInterval(-$0 * 86_400) }, isApple: false)
    }

    func advice(_ items: [LaunchItem], installed: [InstalledApp] = []) -> [String: LaunchAdvice] {
        LaunchAdvisor.advise(items, installed: installed, now: now)
    }

    @Test func countsOnlyEnabledItemsThatStartOnTheirOwn() {
        #expect(item("a").countsTowardStartup)
        #expect(item("a", schedule: .interval(3600)).countsTowardStartup)
        #expect(!item("a", schedule: .onDemand).countsTowardStartup)
        #expect(!item("a", disabled: true).countsTowardStartup)
        #expect(!item("a", schedule: .onDemand).startsOnItsOwn)
    }

    @Test func orphanIsRemoved() {
        let orphan = item("com.gone.agent", ownerInstalled: false)
        #expect(advice([orphan])[orphan.id] == LaunchAdvice(action: .remove, reason: .appGone, isStrong: true))
    }

    @Test func duplicateTurnsOffTheUserCopy() {
        let user = item("com.google.keystone.agent", schedule: .onDemand)
        let global = item("com.google.keystone.agent", domain: .globalAgent, schedule: .onDemand)
        let result = advice([user, global])
        #expect(result[user.id] == LaunchAdvice(action: .turnOff, reason: .duplicate(otherPath: global.plistPath), isStrong: true))
        #expect(result[global.id] == nil)
    }

    @Test func duplicateOfADisabledGlobalCopyIsNotAdvised() {
        let user = item("com.vendor.agent")
        let global = item("com.vendor.agent", domain: .globalAgent, disabled: true)
        #expect(advice([user, global])[user.id] == nil)
    }

    @Test func updaterThatStartsOnItsOwnIsTurnedOff() {
        let zoom = item("us.zoom.updater", domain: .globalAgent, schedule: .interval(3600))
        let google = item("com.google.GoogleUpdater.wake", schedule: .interval(3600))
        let byProgram = item("com.microsoft.mau", program: "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate")
        let result = advice([zoom, google, byProgram])
        for i in [zoom, google, byProgram] {
            #expect(result[i.id] == LaunchAdvice(action: .turnOff, reason: .updater, isStrong: true))
        }
    }

    @Test func onDemandUpdaterGetsNoTurnOffAdvice() {
        let xpc = item("com.google.keystone.xpcservice", schedule: .onDemand)
        #expect(advice([xpc]).isEmpty)
    }

    @Test func disabledItemsGetNoAdvice() {
        let items = [item("com.gone", ownerInstalled: false, disabled: true), item("us.zoom.updater", disabled: true)]
        #expect(advice(items).isEmpty)
    }

    @Test func unusedOwnerAppIsWeakAdvice() {
        let old = item("com.vendor.helper", schedule: .keepAlive, bundleID: "com.vendor.app")
        let recent = item("com.other.helper", schedule: .keepAlive, bundleID: "com.other.app")
        let installed = [app("com.vendor.app", lastUsedDaysAgo: 120), app("com.other.app", lastUsedDaysAgo: 30)]
        let result = advice([old, recent], installed: installed)
        #expect(result[old.id]?.action == .turnOff)
        #expect(result[old.id]?.isStrong == false)
        if case .appUnused = result[old.id]?.reason {} else { Issue.record("expected appUnused") }
        #expect(result[recent.id] == nil)
    }

    @Test func unknownLastUsedGetsNoAdvice() {
        let i = item("com.vendor.helper", bundleID: "com.vendor.app")
        #expect(advice([i], installed: [app("com.vendor.app", lastUsedDaysAgo: nil)]).isEmpty)
    }
}
