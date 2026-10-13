import Foundation

/// Files a deleted device left behind, which nothing reads any more.
struct Leftover: Identifiable, Hashable {
    enum Kind: Hashable {
        /// `~/.android/<id>/emulator.log`: Android Studio deletes the AVD but keeps its log.
        case emulatorLog
        /// This app's own launch log for an AVD that no longer exists.
        case launchLog
        /// `~/Library/Logs/CoreSimulator/<udid>`: simctl keeps logs after deleting the simulator.
        case simulatorLogs
        /// An `.ini` without its folder, or a folder without its `.ini`.
        case brokenAVD
        /// Simulators whose iOS runtime was uninstalled: they can never boot.
        case unavailableSims
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let urls: [URL]
    let size: Int64
    var avd: AVD?

    var explanation: String {
        switch kind {
        case .emulatorLog:
            "Android Studio deleted this emulator but kept its log in ~/.android. Nothing reads it."
        case .launchLog:
            "Light-mulator’s launch log for an emulator that no longer exists."
        case .simulatorLogs:
            "CoreSimulator keeps each simulator’s logs after the simulator is deleted. Nothing reads them."
        case .brokenAVD:
            "\(avd?.problem ?? "Half an emulator is left.") Android Studio doesn’t list it and it can’t boot."
        case .unavailableSims:
            "Their iOS runtime is no longer installed, so they can’t boot. Deleting runs simctl delete unavailable."
        }
    }
}

enum LeftoverScanner {
    static let simulatorLogs = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/CoreSimulator")

    /// `sims` is nil while simctl hasn't answered: every simulator log would look orphaned otherwise.
    static func scan(paths: Paths, avds: [AVD], sims: [Sim]?) -> [Leftover] {
        let fm = FileManager.default
        let avdIDs = Set(avds.map(\.id))
        var result: [Leftover] = []

        for avd in avds where avd.problem != nil {
            let urls = [avd.ini, avd.dir].compactMap { $0 }.filter { fm.fileExists(atPath: $0.path) }
            result.append(Leftover(
                id: "avd-\(avd.id)",
                kind: .brokenAVD,
                title: "“\(avd.displayName)”",
                detail: avd.problem ?? "",
                urls: urls,
                size: urls.reduce(0) { $0 + size(of: $1) },
                avd: avd
            ))
        }

        for folder in subfolders(of: paths.userHome)
        where !avdIDs.contains(folder.lastPathComponent) && holdsOnlyEmulatorLog(folder) {
            result.append(Leftover(
                id: "log-\(folder.lastPathComponent)",
                kind: .emulatorLog,
                title: "Log of “\(folder.lastPathComponent)”",
                detail: "~/.android/\(folder.lastPathComponent)",
                urls: [folder],
                size: size(of: folder)
            ))
        }

        let launchLogs = ((try? fm.contentsOfDirectory(at: Paths.logs, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "log" && !avdIDs.contains($0.deletingPathExtension().lastPathComponent) }
        for log in launchLogs {
            result.append(Leftover(
                id: "launch-\(log.lastPathComponent)",
                kind: .launchLog,
                title: "Launch log of “\(log.deletingPathExtension().lastPathComponent)”",
                detail: "~/Library/Logs/Light-mulator",
                urls: [log],
                size: size(of: log)
            ))
        }

        if let sims {
            let simIDs = Set(sims.map(\.id))
            let orphans = subfolders(of: simulatorLogs)
                .filter { isUDID($0.lastPathComponent) && !simIDs.contains($0.lastPathComponent) }
            if !orphans.isEmpty {
                result.append(Leftover(
                    id: "simlogs",
                    kind: .simulatorLogs,
                    title: "Logs of \(orphans.count) deleted simulator\(orphans.count == 1 ? "" : "s")",
                    detail: "~/Library/Logs/CoreSimulator",
                    urls: orphans,
                    size: orphans.reduce(0) { $0 + size(of: $1) }
                ))
            }

            let unavailable = sims.filter { !$0.isUsable }
            if !unavailable.isEmpty {
                result.append(Leftover(
                    id: "unavailable-sims",
                    kind: .unavailableSims,
                    title: "\(unavailable.count) simulator\(unavailable.count == 1 ? "" : "s") without a runtime",
                    detail: unavailable.map(\.name).joined(separator: ", "),
                    urls: unavailable.compactMap(\.folder),
                    size: unavailable.compactMap(\.size).reduce(0, +)
                ))
            }
        }
        return result
    }

    /// Only the file kinds; AVDs and simulators go through their own delete.
    static func delete(_ item: Leftover, paths: Paths) throws {
        for url in item.urls {
            guard isRemovable(url, kind: item.kind, paths: paths) else {
                throw AppError("Refusing to delete \(url.path): it no longer looks like a leftover.")
            }
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func isRemovable(_ url: URL, kind: Leftover.Kind, paths: Paths) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        switch kind {
        case .emulatorLog:
            return parent == paths.userHome.standardizedFileURL.path && holdsOnlyEmulatorLog(url)
        case .launchLog:
            return parent == Paths.logs.standardizedFileURL.path && url.pathExtension == "log"
        case .simulatorLogs:
            return parent == simulatorLogs.standardizedFileURL.path && isUDID(url.lastPathComponent)
        case .brokenAVD, .unavailableSims:
            return false
        }
    }

    private static func holdsOnlyEmulatorLog(_ folder: URL) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        return items.filter { $0 != ".DS_Store" } == ["emulator.log"]
    }

    private static func isUDID(_ name: String) -> Bool {
        name.range(of: #"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"#, options: .regularExpression) != nil
    }

    private static func subfolders(of url: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey])
        if values?.isDirectory == true { return DiskUsage.allocated(url) }
        return Int64(values?.totalFileAllocatedSize ?? 0)
    }
}
