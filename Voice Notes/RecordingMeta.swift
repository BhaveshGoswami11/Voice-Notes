import Foundation

/// A simple model describing a stored audio recording.
/// This mirrors the fields we write to Firestore.
public struct RecordingMeta: Codable, Sendable {
    public let id: String
    public let title: String
    public let duration: TimeInterval
    public let createdAt: Date
    public let storagePath: String
    public let downloadURL: String
    public let userId: String

    public init(id: String,
                title: String,
                duration: TimeInterval,
                createdAt: Date,
                storagePath: String,
                downloadURL: String,
                userId: String) {
        self.id = id
        self.title = title
        self.duration = duration
        self.createdAt = createdAt
        self.storagePath = storagePath
        self.downloadURL = downloadURL
        self.userId = userId
    }
}
