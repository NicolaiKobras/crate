import Foundation

struct VolumeModel: Identifiable, Equatable {
    let id: String
    let mountpoint: String?
    let source: String?
    let driver: String?
    let labels: [String: String]?
    let options: [String: String]?
    let createdAt: TimeInterval?
    let format: String?
}