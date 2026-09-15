import Foundation

// MARK: - Filtered Directory Copy

/// Copies a file or directory, skipping subdirectories whose names match the skip set.
/// Regular files are always copied, even if their name matches a skip entry.
/// Calls onFile with the name of each item as it's copied.
func copyItemFiltered(at src: URL, to dst: URL, skipping: Set<String>, onFile: ((String) -> Void)? = nil) throws {
    if Task.isCancelled { throw CancellationError() }

    let fm = FileManager.default
    let values = try src.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
        try fm.copyItem(at: src, to: dst)
        onFile?(src.lastPathComponent)
        return
    }

    try fm.createDirectory(at: dst, withIntermediateDirectories: true, attributes: nil)

    for child in try fm.contentsOfDirectory(atPath: src.path) {
        if Task.isCancelled { throw CancellationError() }

        let childSrc = src.appendingPathComponent(child)
        var childIsDir: ObjCBool = false
        fm.fileExists(atPath: childSrc.path, isDirectory: &childIsDir)

        if childIsDir.boolValue && skipping.contains(child) { continue }

        try copyItemFiltered(
            at: childSrc,
            to: dst.appendingPathComponent(child),
            skipping: skipping,
            onFile: onFile
        )
    }
    let attributes = try fm.attributesOfItem(atPath: src.path)
    var preserved: [FileAttributeKey: Any] = [:]
    for key in [FileAttributeKey.posixPermissions, .modificationDate] { preserved[key] = attributes[key] }
    try fm.setAttributes(preserved, ofItemAtPath: dst.path)
}
