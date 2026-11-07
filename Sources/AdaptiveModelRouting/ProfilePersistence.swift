import Foundation
import CryptoKit

/// Controls whether calibration metadata survives the current router instance.
public nonisolated enum RoutingPersistence: Equatable, Sendable {
    case disk
    case memoryOnly
}

/// Reports optional calibration storage health without exposing file paths or underlying errors.
public nonisolated enum RoutingStorageStatus: String, Sendable {
    case memoryOnly, notPersisted, persisted, unavailable, preservedCache
}

/// Produces a deterministic digest without storing instructions, model names or generation settings verbatim.
nonisolated enum RoutingFingerprint {
    /// Separates unsandboxed host apps as well as workloads without writing the app identifier into a path.
    static func cacheDirectory(application: String, root: URL) -> URL {
        root.appendingPathComponent("app-" + make([application]), isDirectory: true)
    }

    /// Length-prefixes each part to avoid ambiguous concatenations before hashing.
    static func make(_ parts: [String]) -> String {
        var data = Data()
        for part in parts {
            let bytes = Data(part.utf8)
            data.append(contentsOf: "\(bytes.count):".utf8)
            data.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
