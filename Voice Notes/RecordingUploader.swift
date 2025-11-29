import Foundation
#if canImport(FirebaseStorage) && canImport(FirebaseFirestore)
import FirebaseStorage
import FirebaseFirestore

/// Service responsible for uploading audio recordings to Firebase Storage
/// and writing metadata documents to Firestore.
public enum RecordingUploader {

    /// Uploads a local audio file to Firebase Storage and returns the download URL and storage path.
    /// - Parameters:
    ///   - fileURL: Local file URL to the audio (e.g., .m4a).
    ///   - userId: Identifier for the current user (used to namespace storage paths).
    ///   - fileName: Optional custom file name. Defaults to a UUID with .m4a extension.
    ///   - contentType: MIME type. Defaults to "audio/m4a".
    /// - Returns: Tuple of (downloadURL, storagePath).
    public static func uploadToStorage(fileURL: URL,
                                       userId: String,
                                       fileName: String? = nil,
                                       contentType: String = "audio/m4a") async throws -> (URL, String) {
        // Verify the file exists before attempting upload
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw NSError(domain: "RecordingUploader",
                         code: -2,
                         userInfo: [NSLocalizedDescriptionKey: "Local file does not exist at path: \(fileURL.path)"])
        }
        
        let storage = Storage.storage()
        let name = fileName ?? UUID().uuidString + ".m4a"
        let storagePath = "recordings/\(userId)/\(name)"
        let ref = storage.reference(withPath: storagePath)

        let metadata = StorageMetadata()
        metadata.contentType = contentType

        // Upload the file and wait for completion, then get download URL
        print("📤 Starting upload to: \(storagePath)")
        var uploadMetadata: StorageMetadata?
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let uploadTask = ref.putFile(from: fileURL, metadata: metadata) { metadata, error in
                if let error = error {
                    print("❌ Upload error: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                } else if let metadata = metadata {
                    uploadMetadata = metadata
                    print("✅ Upload completed successfully. Size: \(metadata.size) bytes")
                    continuation.resume(returning: ())
                } else {
                    print("⚠️ Upload completed but no metadata returned")
                    continuation.resume(returning: ())
                }
            }
            
            // Monitor upload progress
            uploadTask.observe(.progress) { snapshot in
                if let progress = snapshot.progress {
                    let percentComplete = 100.0 * Double(progress.completedUnitCount) / Double(progress.totalUnitCount)
                    print("📊 Upload progress: \(String(format: "%.1f", percentComplete))%")
                }
            }
        }

        // Try to get download URL from upload metadata first, then fallback to ref.downloadURL
        print("🔗 Getting download URL...")
        var downloadURL: URL?
        
        // First, try to get URL from upload metadata if available
        if let metadata = uploadMetadata, let path = metadata.path {
            // Construct download URL from the path
            let downloadRef = storage.reference(withPath: path)
            do {
                downloadURL = try await withCheckedThrowingContinuation { continuation in
                    downloadRef.downloadURL { url, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else if let url = url {
                            continuation.resume(returning: url)
                        } else {
                            continuation.resume(throwing: NSError(domain: "RecordingUploader",
                                                                  code: -1,
                                                                  userInfo: [NSLocalizedDescriptionKey: "Missing download URL"]))
                        }
                    }
                }
            } catch {
                print("⚠️ Failed to get download URL from metadata path: \(error.localizedDescription)")
            }
        }
        
        // If that didn't work, try using the original reference
        if downloadURL == nil {
            do {
                downloadURL = try await withCheckedThrowingContinuation { continuation in
                    ref.downloadURL { url, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else if let url = url {
                            continuation.resume(returning: url)
                        } else {
                            continuation.resume(throwing: NSError(domain: "RecordingUploader",
                                                                  code: -1,
                                                                  userInfo: [NSLocalizedDescriptionKey: "Missing download URL"]))
                        }
                    }
                }
            } catch {
                print("⚠️ Failed to get download URL from reference: \(error.localizedDescription)")
                // If download URL fails, we can still proceed with just the storage path
                // The download URL can be constructed later if needed
                // For now, construct a placeholder URL or throw a more helpful error
                throw NSError(domain: "RecordingUploader",
                             code: -3,
                             userInfo: [NSLocalizedDescriptionKey: "Upload succeeded but could not get download URL. The file is stored at: \(storagePath). Error: \(error.localizedDescription)"])
            }
        }
        
        guard let downloadURL = downloadURL else {
            throw NSError(domain: "RecordingUploader",
                         code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to get download URL. File uploaded to: \(storagePath)"])
        }
        
        print("✅ Download URL obtained: \(downloadURL.absoluteString)")
        return (downloadURL, storagePath)
    }

    /// Saves a RecordingMeta document to Firestore under users/{userId}/recordings/{id}.
    /// - Parameter meta: The metadata to save.
    /// - Returns: The document ID of the saved metadata.
    @discardableResult
    public static func saveMetadata(_ meta: RecordingMeta) async throws -> String {
        let db = Firestore.firestore()
        try await db.collection("users")
            .document(meta.userId)
            .collection("recordings")
            .document(meta.id)
            .setData([
                "title": meta.title,
                "duration": meta.duration,
                "createdAt": Timestamp(date: meta.createdAt),
                "storagePath": meta.storagePath,
                "downloadURL": meta.downloadURL,
                "userId": meta.userId
            ])
        return meta.id
    }

    /// Convenience method: uploads the file and writes its metadata.
    /// - Parameters:
    ///   - fileURL: Local URL of the recording file.
    ///   - title: Title of the recording.
    ///   - duration: Duration in seconds.
    ///   - userId: User identifier.
    /// - Returns: The Firestore document ID that was written.
    @discardableResult
    public static func uploadAndSave(fileURL: URL,
                                     title: String,
                                     duration: TimeInterval,
                                     userId: String) async throws -> String {
        let (downloadURL, storagePath) = try await uploadToStorage(fileURL: fileURL, userId: userId)
        let meta = RecordingMeta(
            id: UUID().uuidString,
            title: title,
            duration: duration,
            createdAt: Date(),
            storagePath: storagePath,
            downloadURL: downloadURL.absoluteString,
            userId: userId
        )
        return try await saveMetadata(meta)
    }
}

#else

/// Fallback stub when Firebase modules are unavailable at compile time.
public enum RecordingUploader {
    public enum MissingFirebaseError: Error, LocalizedError {
        case firebaseModulesUnavailable
        public var errorDescription: String? {
            "FirebaseStorage/Firestore not available. Ensure dependencies are added to the Xcode project or compile with Firebase present."
        }
    }

    public static func uploadToStorage(fileURL: URL,
                                       userId: String,
                                       fileName: String? = nil,
                                       contentType: String = "audio/m4a") async throws -> (URL, String) {
        throw MissingFirebaseError.firebaseModulesUnavailable
    }

    @discardableResult
    public static func saveMetadata(_ meta: RecordingMeta) async throws -> String {
        throw MissingFirebaseError.firebaseModulesUnavailable
    }

    @discardableResult
    public static func uploadAndSave(fileURL: URL,
                                     title: String,
                                     duration: TimeInterval,
                                     userId: String) async throws -> String {
        throw MissingFirebaseError.firebaseModulesUnavailable
    }
}
#endif

