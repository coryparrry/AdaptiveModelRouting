import Foundation
import XCTest
import AdaptiveModelRouting
#if os(macOS)
import Darwin
#endif

/// Reads stored backup metadata because the macOS 27.3 Foundation getter can return false after setting it.
func hasBackupExclusion(at url: URL) throws -> Bool {
    #if os(macOS)
    let key = "com.apple.metadata:com_apple_backup_excludeItem"
    let size = url.withUnsafeFileSystemRepresentation { getxattr($0!, key, nil, 0, 0, 0) }
    if size < 0 {
        if errno == ENOATTR { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var data = Data(count: size)
    let read = data.withUnsafeMutableBytes { bytes in
        url.withUnsafeFileSystemRepresentation { getxattr($0!, key, bytes.baseAddress, size, 0, 0) }
    }
    guard read == size else { throw POSIXError(.EIO) }
    let marker = try PropertyListSerialization.propertyList(from: data, format: nil) as? String
    return marker == "com.apple.backupd"
    #else
    var fresh = URL(fileURLWithPath: url.path, isDirectory: url.hasDirectoryPath)
    fresh.removeAllCachedResourceValues()
    return try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    #endif
}

/// Verifies actual exclusion metadata rather than accepting a successful setter call alone.
final class BackupExclusionTests: XCTestCase {
    /// Each atomic replacement excludes the owned file while sibling data and its parent remain backup eligible.
    @MainActor
    func testBackupExclusionPersistsAcrossSaves() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sibling = directory.appendingPathComponent("documents.sqlite")
        let cacheFile = directory.appendingPathComponent("latency.json")
        try Data("user data".utf8).write(to: sibling)
        let router = singleProviderRouter(directory: directory, monitorConnection: false)
        for _ in 0..<2 {
            _ = try await router.measure(model: .cloud, inputTokens: 100, snapshot: router.snapshot()) { 1 }
            XCTAssertTrue(try hasBackupExclusion(at: cacheFile))
            XCTAssertFalse(try hasBackupExclusion(at: directory))
            XCTAssertFalse(try hasBackupExclusion(at: sibling))
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                ["documents.sqlite", "latency.json"])
        }
    }
}
