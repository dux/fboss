import Darwin
import Foundation

/// Finds the other paths of a hard-linked file. macOS keeps no inode -> paths index
/// (`fsgetpath` returns a single path and APFS link ids cannot be enumerated), so this
/// walks the volume with `getattrlistbulk`, nearest folders first: the file's own folder,
/// then each ancestor's remaining subtree, never leaving the file's volume.
/// Measured at about 80k entries/s on an APFS home volume, so the walk is time-bounded.
enum HardLinkFinder {
    struct Result: Sendable, Equatable {
        var paths: [String]
        /// Seconds after which the walk gave up; nil when it finished or found every link.
        var stoppedAfter: TimeInterval?
        var scanned: Int
    }

    /// Runs on the caller's thread; checks `Task.isCancelled` between folders.
    static func find(path: String, inode: UInt64, device: Int32, linkCount: Int,
                     timeLimit: TimeInterval = 10, cap: Int = 50) -> Result {
        let start = Date()
        var result = Result(paths: [], stoppedAfter: nil, scanned: 0)
        let wanted = min(linkCount - 1, cap)
        var searched: String?
        var folder = (path as NSString).deletingLastPathComponent
        while true {
            var stack = [folder]
            while let dir = stack.popLast() {
                if Task.isCancelled { return result }
                if Date().timeIntervalSince(start) > timeLimit {
                    result.stoppedAfter = timeLimit
                    return result
                }
                scan(dir, device: device) { entry in
                    result.scanned += 1
                    if entry.isDirectory {
                        if entry.path != searched { stack.append(entry.path) }
                    } else if entry.fileID == inode, entry.path != path {
                        result.paths.append(entry.path)
                    }
                }
                if result.paths.count >= wanted { return result }
            }
            let parent = (folder as NSString).deletingLastPathComponent
            guard parent != folder, deviceID(parent) == device else { return result }
            searched = folder
            folder = parent
        }
    }

    private struct Entry {
        let path: String
        let isDirectory: Bool
        let fileID: UInt64
    }

    private static func deviceID(_ path: String) -> Int32? {
        var st = stat()
        return lstat(path, &st) == 0 ? st.st_dev : nil
    }

    /// One folder's direct children; subfolders on other volumes are skipped.
    private static func scan(_ dir: String, device: Int32, _ visit: (Entry) -> Void) {
        let fd = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var attrs = attrlist(
            bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0,
            commonattr: attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_DEVID)
                | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FILEID),
            volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0)
        let size = 128 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buffer.deallocate() }
        while true {
            let count = getattrlistbulk(fd, &attrs, buffer, size, 0)
            guard count > 0 else { return }
            var record = buffer
            for _ in 0..<count {
                let length = record.load(as: UInt32.self)
                // Fields follow in attribute bit order, each 4-byte aligned.
                var field = record + 4 + MemoryLayout<attribute_set_t>.size
                let nameRef = field.load(as: attrreference_t.self)
                let name = String(cString: (field + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                field += MemoryLayout<attrreference_t>.size
                let dev = field.load(as: dev_t.self)
                field += MemoryLayout<dev_t>.size
                let type = field.load(as: fsobj_type_t.self)
                field += MemoryLayout<fsobj_type_t>.size
                let fileID = field.loadUnaligned(as: UInt64.self)
                record += Int(length)
                guard dev == device else { continue }
                let child = dir == "/" ? "/" + name : dir + "/" + name
                visit(Entry(path: child, isDirectory: type == VDIR.rawValue, fileID: fileID))
            }
        }
    }
}
