import Foundation

enum PathResolver {
    static var extraBinDirs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            URL(fileURLWithPath: "/usr/bin"),
            home.appendingPathComponent(".local/bin"),
            home.appendingPathComponent(".volta/bin"),
            home.appendingPathComponent(".fnm/current/bin"),
            home.appendingPathComponent(".asdf/shims"),
        ]
        let nvmRoot = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(
            at: nvmRoot,
            includingPropertiesForKeys: nil
        ) {
            dirs.append(contentsOf: versions.map { $0.appendingPathComponent("bin") })
        }
        return dirs
    }

    static func augmentedPATH(from environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let existing = environment["PATH"] ?? ""
        var parts = existing.split(separator: ":").map(String.init)
        for dir in extraBinDirs {
            if FileManager.default.fileExists(atPath: dir.path), !parts.contains(dir.path) {
                parts.append(dir.path)
            }
        }
        return parts.joined(separator: ":")
    }

    static func locate(_ name: String, path: String? = nil) -> URL? {
        let pathValue = path ?? augmentedPATH()
        for dir in pathValue.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func nodeMeetsMinimum(_ version: String?) -> Bool {
        guard var v = version, v.hasPrefix("v") else { return false }
        v.removeFirst()
        let parts = v.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        if parts[0] != 22 { return parts[0] > 22 }
        return parts[1] >= 19
    }

    static func nodeVersion(path: String? = nil) -> String? {
        guard let node = locate("node", path: path) else { return nil }
        let proc = Process()
        proc.executableURL = node
        proc.arguments = ["-v"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
