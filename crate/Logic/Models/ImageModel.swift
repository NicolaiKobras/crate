import Foundation

struct ImageModel: Identifiable, Equatable {
    let id: String
    let size: String?
    let digest: String?
    let mediaType: String?
}
