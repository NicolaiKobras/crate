import Foundation

extension ContainerCreateOptions {
    /// Build a clone-able `ContainerCreateOptions` from a raw `container inspect` JSON payload.
    /// Returns nil if the payload can't be decoded.
    static func from(inspectJSON: String, suggestedName: String) -> ContainerCreateOptions? {
        let data = Data(inspectJSON.utf8)
        let decoder = JSONDecoder()

        let parsed: [InspectItem]
        if let arr = try? decoder.decode([InspectItem].self, from: data) {
            parsed = arr
        } else if let single = try? decoder.decode(InspectItem.self, from: data) {
            parsed = [single]
        } else {
            return nil
        }

        guard let item = parsed.first, let cfg = item.configuration else { return nil }

        var options = ContainerCreateOptions(
            name: suggestedName,
            image: cfg.image?.reference ?? ""
        )

        // Environment variables
        options.env = cfg.initProcess?.environment ?? []

        // Labels
        if let labels = cfg.labels {
            options.labels = labels.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }
        }

        // Published ports
        options.publishPorts = (cfg.publishedPorts ?? []).compactMap { p in
            guard let host = p.hostPort, let cport = p.containerPort else { return nil }
            let hostPart: String
            if let addr = p.hostAddress, !addr.isEmpty, addr != "0.0.0.0" {
                hostPart = "\(addr):\(host)"
            } else {
                hostPart = "\(host)"
            }
            let base = "\(hostPart):\(cport)"
            if let proto = p.proto, !proto.isEmpty { return "\(base)/\(proto)" }
            return base
        }

        // Working directory (only if non-trivial)
        if let wd = cfg.initProcess?.workingDirectory, !wd.isEmpty, wd != "/" {
            options.workingDir = wd
        }

        // Resources
        if let cpus = cfg.resources?.cpus { options.cpus = String(cpus) }
        if let mem = cfg.resources?.memoryInBytes {
            options.memory = humanReadableMemory(mem)
        }

        // Platform
        if let os = cfg.platform?.os, let arch = cfg.platform?.architecture {
            options.platform = "\(os)/\(arch)"
            options.osValue = os
            options.archValue = arch
        }

        // Network — only if explicitly non-default
        if let net = cfg.networks?.first?.network, net != "default" {
            options.network = net
        }

        // DNS
        if let ns = cfg.dns?.nameservers, !ns.isEmpty {
            options.dns = ns
        }

        // Volume mappings (named volumes only — bind mounts can't round-trip via --volume)
        var mappings: [String: String] = [:]
        for m in cfg.mounts ?? [] {
            if let name = m.type?.volume?.name, !name.isEmpty,
               let dest = m.destination, !dest.isEmpty {
                mappings[name] = dest
            }
        }
        options.volumeMappings = mappings

        return options
    }

    private static func humanReadableMemory(_ bytes: Int) -> String {
        let suffixes = ["", "K", "M", "G", "T", "P"]
        var value = bytes
        var idx = 0
        while idx < suffixes.count - 1 && value >= 1024 && value % 1024 == 0 {
            value /= 1024
            idx += 1
        }
        return "\(value)\(suffixes[idx])"
    }
}

// MARK: - Decodable shape of `container inspect`

private struct InspectItem: Decodable {
    let configuration: Config?

    struct Config: Decodable {
        let image: Image?
        let labels: [String: String]?
        let mounts: [Mount]?
        let publishedPorts: [PublishedPort]?
        let initProcess: InitProcess?
        let resources: Resources?
        let platform: Platform?
        let networks: [Network]?
        let dns: DNS?
    }

    struct Image: Decodable { let reference: String? }
    struct Platform: Decodable { let os: String?; let architecture: String? }
    struct Resources: Decodable { let cpus: Int?; let memoryInBytes: Int? }
    struct Network: Decodable { let network: String? }
    struct DNS: Decodable { let nameservers: [String]?; let searchDomains: [String]?; let options: [String]? }

    struct PublishedPort: Decodable {
        let proto: String?
        let hostPort: Int?
        let hostAddress: String?
        let containerPort: Int?
    }

    struct InitProcess: Decodable {
        let environment: [String]?
        let workingDirectory: String?
        let executable: String?
        let arguments: [String]?
    }

    struct MountTypeVolume: Decodable { let name: String?; let format: String? }
    struct MountType: Decodable { let volume: MountTypeVolume? }
    struct Mount: Decodable { let type: MountType?; let source: String?; let destination: String? }
}
