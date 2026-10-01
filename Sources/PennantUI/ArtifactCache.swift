import PennantClientKit
import PennantCore
import Foundation
import Observation

/// In-memory cache of artifact bytes (screenshots and images shown in conversations), plus raw bytes for
/// shared files so a card can save, open, or preview without refetching.
@MainActor
@Observable
public final class ArtifactCache {
    public static let shared = ArtifactCache()
    private var images: [ArtifactID: PlatformImage] = [:]
    private var inFlight: Set<ArtifactID> = []
    private var order: [ArtifactID] = []
    private let limit = 80

    /// What the cache knows about a file artifact's bytes.
    public enum FileState: Sendable {
        case loading
        case loaded(Data)
        case failed(String)
    }
    private var files: [ArtifactID: FileState] = [:]
    private var fileOrder: [ArtifactID] = []
    private var fileBytes = 0
    /// Shared files are at most 50 MB each; keep a few of them around.
    private let fileByteLimit = 256 * 1024 * 1024

    public init() {}

    public func image(for id: ArtifactID) -> PlatformImage? { images[id] }

    public func load(_ id: ArtifactID, using session: HostSession) {
        guard images[id] == nil, !inFlight.contains(id) else { return }
        inFlight.insert(id)
        Task {
            defer { inFlight.remove(id) }
            guard let (_, data) = try? await session.artifact(id), let img = PlatformImage(data: data) else { return }
            images[id] = img
            order.append(id)
            if order.count > limit {
                let evict = order.removeFirst()
                images[evict] = nil
            }
        }
    }

    // MARK: Files

    public func file(for id: ArtifactID) -> FileState? { files[id] }

    public func fileData(for id: ArtifactID) -> Data? {
        if case .loaded(let data)? = files[id] { return data }
        return nil
    }

    /// Fetches the bytes once; a failed fetch stays failed until `reloadFile` so the card can show Retry.
    public func loadFile(_ id: ArtifactID, using session: HostSession) {
        guard files[id] == nil else { return }
        files[id] = .loading
        Task {
            do {
                let (_, data) = try await session.artifact(id)
                files[id] = .loaded(data)
                fileOrder.append(id)
                fileBytes += data.count
                while fileBytes > fileByteLimit, fileOrder.count > 1 {
                    let evict = fileOrder.removeFirst()
                    if case .loaded(let old)? = files[evict] { fileBytes -= old.count }
                    files[evict] = nil
                }
            } catch {
                files[id] = .failed(String(describing: error))
            }
        }
    }

    public func reloadFile(_ id: ArtifactID, using session: HostSession) {
        if case .loading? = files[id] { return }
        files[id] = nil
        loadFile(id, using: session)
    }
}
