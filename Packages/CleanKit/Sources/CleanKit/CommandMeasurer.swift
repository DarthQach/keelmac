import Foundation
import SafetyKit

/// Measures what a command rule would free, before planning and again after it runs.
enum CommandMeasurer {
    static let checkTimeout: TimeInterval = 15

    struct Measured: Sendable {
        var bytes: Int64 = 0
        var detail: ItemDetail?
        /// Folders the measurement covers (claimed so no path rule offers them too).
        var paths: [String] = []
        var unreadable = 0
    }

    enum Failure: Error, Sendable, Equatable {
        case toolMissing
        case failed(String)
    }

    static func measure(_ m: CommandMeasurement, runner: CommandRunning) async -> Result<Measured, Failure> {
        switch m {
        case .none:
            return .success(Measured())
        case .paths(let paths):
            let sizes = await DirectorySizer.size(paths)
            let existing = paths.filter { sizes[$0]?.exists == true }
            return .success(Measured(bytes: existing.reduce(0) { $0 + (sizes[$1]?.bytes ?? 0) }, paths: existing,
                                     unreadable: existing.reduce(0) { $0 + (sizes[$1]?.unreadable ?? 0) }))
        case .simctlUnavailableDevices(let xcrun, let folder):
            let r = await runner.run(xcrun, ["simctl", "list", "devices", "unavailable", "-j"], timeout: checkTimeout)
            guard r.succeeded else {
                // 72: xcrun can't find simctl (no Xcode selected or installed).
                if r.exitCode == 72 || r.exitCode == 127 || r.stderr.contains("unable to find utility") { return .failure(.toolMissing) }
                return .failure(.failed(failureText("simctl list", r)))
            }
            let found = parseUnavailableDevices(r.stdout, devicesFolder: folder)
            let sizes = await DirectorySizer.size(found.map(\.path))
            let devices = found.map { d in
                SimulatorDevice(udid: d.udid, name: d.name, runtime: d.runtime, path: d.path, bytes: sizes[d.path]?.bytes ?? 0)
            }
            return .success(Measured(bytes: devices.reduce(0) { $0 + $1.bytes }, detail: devices.isEmpty ? nil : .simulators(devices),
                                     paths: devices.map(\.path)))
        case .dockerSystemDF(let docker):
            let r = await runner.run(docker, ["system", "df", "--format", "{{json .}}"], timeout: checkTimeout)
            guard r.succeeded else { return .failure(.failed(failureText("docker system df", r))) }
            let usage = parseDockerDF(r.stdout)
            return .success(Measured(bytes: usage.containersBytes + usage.buildCacheBytes, detail: .docker(usage)))
        }
    }

    static func failureText(_ what: String, _ r: CommandResult) -> String {
        if r.timedOut { return "\(what): timed out" }
        let last = r.stderr.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return last.isEmpty ? "\(what): exit code \(r.exitCode)" : "\(what): exit code \(r.exitCode): \(last)"
    }

    // MARK: - simctl

    struct FoundDevice: Equatable { let udid: String; let name: String; let runtime: String; let path: String }

    /// Parses `xcrun simctl list devices unavailable -j`. Each device folder is
    /// `<devicesFolder>/<udid>`; a udid that isn't a plain UUID is ignored.
    static func parseUnavailableDevices(_ json: String, devicesFolder: String) -> [FoundDevice] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byRuntime = root["devices"] as? [String: Any] else { return [] }
        var out: [FoundDevice] = []
        for (runtime, value) in byRuntime.sorted(by: { $0.key < $1.key }) {
            for case let device as [String: Any] in (value as? [Any]) ?? [] {
                guard let udid = device["udid"] as? String, UUID(uuidString: udid) != nil else { continue }
                if let available = device["isAvailable"] as? Bool, available { continue }
                out.append(FoundDevice(udid: udid, name: device["name"] as? String ?? udid,
                                       runtime: runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: ""),
                                       path: devicesFolder + "/" + udid))
            }
        }
        return out
    }

    // MARK: - docker

    /// Parses `docker system df --format '{{json .}}'` (one JSON object per line).
    static func parseDockerDF(_ output: String) -> DockerUsage {
        var containers: Int64 = 0, cache: Int64 = 0, images: Int64 = 0
        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["Type"] as? String, let reclaimable = obj["Reclaimable"] as? String else { continue }
            let bytes = parseDockerSize(reclaimable) ?? 0
            switch type.lowercased() {
            case "containers": containers += bytes
            case "build cache": cache += bytes
            case "images": images += bytes
            default: break
            }
        }
        return DockerUsage(containersBytes: containers, buildCacheBytes: cache, imagesReclaimableBytes: images)
    }

    /// `"1.234GB (50%)"`, `"512kB"`, `"0B"` → bytes. Docker uses decimal units.
    static func parseDockerSize(_ text: String) -> Int64? {
        let s = text.split(separator: " ").first.map(String.init) ?? text
        let number = s.prefix { $0.isNumber || $0 == "." }
        let unit = s.dropFirst(number.count).lowercased()
        guard let value = Double(number) else { return nil }
        let multipliers: [String: Double] = ["b": 1, "kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12, "pb": 1e15,
                                             "kib": 1024, "mib": 1_048_576, "gib": 1_073_741_824, "tib": 1_099_511_627_776]
        guard let m = multipliers[unit.isEmpty ? "b" : unit] else { return nil }
        return Int64(value * m)
    }

    // MARK: - pnpm

    /// `pnpm store path` prints one absolute path.
    static func parseStorePath(_ output: String) -> String? {
        let line = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
        guard let line, line.hasPrefix("/") else { return nil }
        return PathGuard.normalize(line)
    }
}
