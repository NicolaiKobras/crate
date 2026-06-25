import Foundation

struct ContainerModel: Identifiable, Equatable {
    let id: String
    let image: String
    let os: String?
    let arch: String?
    let state: String
    let running: Bool
    let addr: String?
    let mounts: [ContainerMount]
    let ports: [ContainerPort]
}

struct ContainerMount: Equatable, Identifiable {
    let id = UUID()
    let source: String?
    let destination: String?
    let volumeName: String?
    let format: String?
}

struct ContainerPort: Equatable, Identifiable {
    let id = UUID()
    let proto: String?
    let hostAddress: String?
    let hostPort: Int
    let containerPort: Int

    var displayString: String {
        let host = (hostAddress.map { $0.isEmpty ? "0.0.0.0" : $0 }) ?? "0.0.0.0"
        let prefix = "\(host):\(hostPort)→\(containerPort)"
        if let proto, !proto.isEmpty { return "\(prefix)/\(proto)" }
        return prefix
    }
}
