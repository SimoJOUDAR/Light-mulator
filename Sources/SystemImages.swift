import Foundation

/// A folder under `sdk/system-images/<platform>/<tag>[/<abi>]` that no AVD boots from.
struct SystemImage: Identifiable, Hashable {
    /// Relative to the SDK, the form AVDs use in `image.sysdir.1`.
    let id: String
    let dir: URL
    let apiLevel: Int?
    let tag: String
    let abi: String?

    /// A platform/tag folder with no image inside, left behind by an older uninstall.
    var isEmptyFolder: Bool { abi == nil }

    var title: String {
        let version = apiLevel.flatMap(AVD.androidVersionName).map { "Android \($0)" } ?? apiLevel.map { "API \($0)" }
        return [version, tag].compactMap { $0 }.joined(separator: " · ")
    }
}

enum SystemImageRepository {
    static func unused(_ paths: Paths, avds: [AVD]) -> [SystemImage] {
        let root = paths.sdk.appendingPathComponent("system-images")
        let used = usedIDs(avds)
        var result: [SystemImage] = []

        for platform in subfolders(of: root) {
            for tag in subfolders(of: platform) {
                let images = subfolders(of: tag).filter { containsFiles($0) }
                if images.isEmpty {
                    let id = "system-images/\(platform.lastPathComponent)/\(tag.lastPathComponent)"
                    guard !used.contains(where: { $0.hasPrefix(id + "/") }) else { continue }
                    result.append(SystemImage(
                        id: id,
                        dir: tag,
                        apiLevel: apiLevel(platform.lastPathComponent),
                        tag: "Empty folder (\(tag.lastPathComponent))",
                        abi: nil
                    ))
                }
                for image in images {
                    let id = "system-images/\(platform.lastPathComponent)/\(tag.lastPathComponent)/\(image.lastPathComponent)"
                    guard !used.contains(id) else { continue }
                    let properties = INI.parse(image.appendingPathComponent("source.properties")) ?? [:]
                    result.append(SystemImage(
                        id: id,
                        dir: image,
                        apiLevel: properties["AndroidVersion.ApiLevel"].flatMap { Int($0) } ?? apiLevel(platform.lastPathComponent),
                        tag: properties["SystemImage.TagDisplay"]?.replacingOccurrences(of: ",", with: ", ") ?? tag.lastPathComponent,
                        abi: properties["SystemImage.Abi"] ?? image.lastPathComponent
                    ))
                }
            }
        }
        return result.sorted { ($0.apiLevel ?? 0, $0.id) > ($1.apiLevel ?? 0, $1.id) }
    }

    /// Checked again right before deleting: an AVD created since the list was built must keep its image.
    static func isUsed(_ image: SystemImage, by avds: [AVD]) -> Bool {
        let used = usedIDs(avds)
        return used.contains(image.id) || used.contains { $0.hasPrefix(image.id + "/") }
    }

    static func delete(_ image: SystemImage, paths: Paths) throws {
        let fm = FileManager.default
        let root = paths.sdk.appendingPathComponent("system-images").standardizedFileURL
        let dir = image.dir.standardizedFileURL
        let depth = dir.pathComponents.count - root.pathComponents.count
        guard dir.path.hasPrefix(root.path + "/"), depth == (image.isEmptyFolder ? 2 : 3) else {
            throw AppError("Refusing to delete \(dir.path): not a system image folder.")
        }
        try fm.removeItem(at: dir)
        var parent = dir.deletingLastPathComponent()
        while parent.path != root.path,
              let left = try? fm.contentsOfDirectory(atPath: parent.path),
              left.allSatisfy({ $0 == ".DS_Store" }) {
            try? fm.removeItem(at: parent)
            parent = parent.deletingLastPathComponent()
        }
    }

    private static func usedIDs(_ avds: [AVD]) -> Set<String> {
        Set(avds.flatMap { avd in
            ["image.sysdir.1", "image.sysdir.2"].compactMap { avd.config[$0] }
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }
        })
    }

    private static func subfolders(of url: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private static func containsFiles(_ url: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let file as URL in walker where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            return true
        }
        return false
    }

    private static func apiLevel(_ platform: String) -> Int? {
        Int(platform.replacingOccurrences(of: "android-", with: ""))
    }
}
