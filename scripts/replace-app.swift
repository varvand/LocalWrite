import Foundation

// Replace the whole bundle with the new bundle's metadata; copying over an app
// can retain obsolete resources and the previous copy's quarantine attributes.
let manager = FileManager.default
var backup: URL?
var original: URL?
do {
    guard CommandLine.arguments.count == 3 else {
        throw NSError(domain: "LocalWriteInstall", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Expected a staged app and its destination."])
    }
    let source = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let destination = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
    let sourceValues = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard source.lastPathComponent == "LocalWrite.app",
          destination.lastPathComponent == "LocalWrite.app",
          source != destination,
          !source.path.hasPrefix(destination.path + "/"),
          !destination.path.hasPrefix(source.path + "/"),
          sourceValues.isDirectory == true,
          sourceValues.isSymbolicLink != true else {
        throw NSError(domain: "LocalWriteInstall", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Expected a real staged LocalWrite.app and a separate destination."])
    }
    if manager.fileExists(atPath: destination.path) {
        let values = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw NSError(domain: "LocalWriteInstall", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "The destination is not a real app directory."])
        }
        let backupName = ".LocalWrite-previous-\(UUID().uuidString).app"
        backup = destination.deletingLastPathComponent().appendingPathComponent(backupName)
        original = destination
        _ = try manager.replaceItemAt(destination, withItemAt: source, backupItemName: backupName,
                                      options: [.usingNewMetadataOnly, .withoutDeletingBackupItem])
        // A cleanup failure must not turn a successful install into a rollback.
        if let backup { try? manager.removeItem(at: backup) }
        backup = nil
    } else {
        try manager.moveItem(at: source, to: destination)
    }
} catch {
    if let backup, let original, manager.fileExists(atPath: backup.path) {
        let failed = original.deletingLastPathComponent().appendingPathComponent(".LocalWrite-failed-\(UUID().uuidString).app")
        do {
            if manager.fileExists(atPath: original.path) { try manager.moveItem(at: original, to: failed) }
            try manager.moveItem(at: backup, to: original)
            try? manager.removeItem(at: failed)
        } catch {
            FileHandle.standardError.write(Data("The previous app is preserved at: \(backup.path)\n".utf8))
        }
    }
    FileHandle.standardError.write(Data("Could not replace LocalWrite: \(error.localizedDescription)\n".utf8))
    exit(1)
}
