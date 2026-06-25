import Foundation

/// Structured view of `container image inspect`, populated from the raw JSON.
struct ImageInspect: Equatable {
    var name: String
    var digest: String?
    var mediaType: String?
    var indexSize: Int?
    var variants: [Variant]
    var labels: [String: String]

    struct Variant: Equatable, Identifiable {
        let id = UUID()
        var os: String?
        var architecture: String?
        var variant: String?
        var size: Int?
        var created: String?
        var workingDir: String?
        var command: [String]?
        var entrypoint: [String]?
        var env: [String]
        var labels: [String: String]

        var platformDisplay: String {
            var parts: [String] = []
            if let os { parts.append(os) }
            if let architecture { parts.append(architecture) }
            var joined = parts.joined(separator: "/")
            if let variant, !variant.isEmpty { joined += "/" + variant }
            return joined
        }
    }

    static func parse(_ json: String) -> ImageInspect? {
        let data = Data(json.utf8)
        let decoder = JSONDecoder()

        let raw: [RawItem]
        if let arr = try? decoder.decode([RawItem].self, from: data) {
            raw = arr
        } else if let single = try? decoder.decode(RawItem.self, from: data) {
            raw = [single]
        } else {
            return nil
        }

        guard let item = raw.first else { return nil }

        let variants: [Variant] = (item.variants ?? []).map { rv in
            let inner = rv.config?.config
            return Variant(
                os: rv.platform?.os ?? rv.config?.os,
                architecture: rv.platform?.architecture ?? rv.config?.architecture,
                variant: rv.platform?.variant ?? rv.config?.variant,
                size: rv.size,
                created: rv.config?.created,
                workingDir: inner?.WorkingDir,
                command: inner?.Cmd,
                entrypoint: inner?.Entrypoint,
                env: inner?.Env ?? [],
                labels: inner?.Labels ?? [:]
            )
        }

        // Merge labels — most images attach them per-variant config, identical
        // across variants. Pick the first non-empty for a top-level summary.
        var topLabels: [String: String] = [:]
        for v in variants where !v.labels.isEmpty {
            topLabels = v.labels
            break
        }

        return ImageInspect(
            name: item.name ?? "",
            digest: item.index?.digest,
            mediaType: item.index?.mediaType,
            indexSize: item.index?.size,
            variants: variants,
            labels: topLabels
        )
    }
}

// MARK: - Decodable schema (private)

private struct RawItem: Decodable {
    let name: String?
    let index: IndexDescriptor?
    let variants: [VariantRaw]?

    struct IndexDescriptor: Decodable {
        let mediaType: String?
        let digest: String?
        let size: Int?
    }

    struct Platform: Decodable {
        let architecture: String?
        let os: String?
        let variant: String?
    }

    struct VariantRaw: Decodable {
        let platform: Platform?
        let size: Int?
        let config: Config?
    }

    struct Config: Decodable {
        let created: String?
        let architecture: String?
        let os: String?
        let variant: String?
        let config: InnerConfig?

        struct InnerConfig: Decodable {
            let WorkingDir: String?
            let Cmd: [String]?
            let Entrypoint: [String]?
            let Env: [String]?
            let Labels: [String: String]?
        }
    }
}
