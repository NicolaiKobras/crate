import Foundation

enum BinaryLocator {
    private static let candidateLocations: [String] = [
        "/opt/homebrew/bin/container",
        "/usr/local/bin/container",
        "/usr/bin/container"
    ]

    static func resolveContainerBinary(preferredPath: String? = nil) -> String? {
        if let preferred = preferredPath,
           !preferred.isEmpty,
           FileManager.default.isExecutableFile(atPath: preferred) {
            return preferred
        }

        for candidate in candidateLocations where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        if let fromPath = searchPATH(for: "container") {
            return fromPath
        }

        return nil
    }

    private static func searchPATH(for name: String) -> String? {
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        let directories = pathEnv.split(separator: ":").map(String.init)
        for dir in directories {
            let full = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: full) {
                return full
            }
        }
        return nil
    }
}
