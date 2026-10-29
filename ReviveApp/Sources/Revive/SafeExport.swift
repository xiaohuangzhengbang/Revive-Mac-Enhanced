import Foundation
import CryptoKit
import Darwin

/// Copies to a newly created directory without replacing existing user files.
/// Open descriptors bind all writes to the checked directory; O_EXCL and
/// O_NOFOLLOW protect the final file names even if a collision appears later.
enum SafeExport {
    enum ExportError: LocalizedError {
        case unsafePath(String)
        case changedResource(String)
        case nonemptyDirectory
        case sameSource

        var errorDescription: String? {
            switch self {
            case .unsafePath(let path): return "不安全的文件路径（须为普通文件或真实目录）：\(path)"
            case .changedResource(let path): return "操作期间文件或目录已改变：\(path)"
            case .nonemptyDirectory: return "导出目录已有内容，请创建新的专用目录。"
            case .sameSource: return "照片与视频指向同一个文件，已停止导出。"
            }
        }
    }

    static func sha256(_ url: URL) throws -> String {
        let source = try openFile(url)
        defer { Darwin.close(source.fd) }
        var digest = SHA256()
        var total: Int64 = 0
        try readChunks(source.fd, byteLimit: Int64(source.info.st_size)) { buffer, count in
            digest.update(data: Data(buffer.prefix(count)))
            total += Int64(count)
        }
        try requireUnchanged(source, url: url, bytesRead: total)
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func createOutputDirectory(parent: URL, baseName: String = "Revive_Live") throws -> URL {
        guard validName(baseName) else { throw ExportError.unsafePath(baseName) }
        let directory = try openDirectory(parent)
        defer { Darwin.close(directory.fd) }
        for _ in 0..<16 {
            let name = "\(baseName)_\(UUID().uuidString)"
            try requireBound(directory, url: parent)
            if Darwin.mkdirat(directory.fd, name, mode_t(0o700)) == 0 {
                try requireBound(directory, url: parent)
                return parent.appendingPathComponent(name, isDirectory: true)
            }
            if errno != EEXIST { throw posixError() }
        }
        throw POSIXError(.EEXIST)
    }

    static func copyPair(_ result: ConversionResult, to directoryURL: URL) throws -> (image: URL, mov: URL) {
        let directory = try openDirectory(directoryURL)
        defer { Darwin.close(directory.fd) }
        guard try isEmpty(directory.fd) else { throw ExportError.nonemptyDirectory }
        let image = try openFile(result.imageURL)
        defer { Darwin.close(image.fd) }
        let movie = try openFile(result.movURL)
        defer { Darwin.close(movie.fd) }
        guard !sameIdentity(image.info, movie.info) else { throw ExportError.sameSource }
        let imageName = result.imageURL.lastPathComponent
        let movieName = result.movURL.lastPathComponent
        guard validName(imageName), validName(movieName), imageName != movieName else {
            throw ExportError.unsafePath("输出文件名")
        }
        var created: [(name: String, identity: stat)] = []
        do {
            let imageIdentity = try copy(image, sourceURL: result.imageURL, name: imageName,
                                         directory: directory, directoryURL: directoryURL)
            created.append((imageName, imageIdentity))
            let movieIdentity = try copy(movie, sourceURL: result.movURL, name: movieName,
                                         directory: directory, directoryURL: directoryURL)
            created.append((movieName, movieIdentity))
            try requireUnchanged(image, url: result.imageURL, bytesRead: Int64(image.info.st_size))
            try requireUnchanged(movie, url: result.movURL, bytesRead: Int64(movie.info.st_size))
            try requireBound(directory, url: directoryURL)
            return (directoryURL.appendingPathComponent(imageName), directoryURL.appendingPathComponent(movieName))
        } catch {
            // Remove only files created by this invocation, and only while the
            // directory entry still points at our own inode. Never remove a collision.
            for file in created { removeOwned(file.name, identity: file.identity, directoryFD: directory.fd) }
            throw error
        }
    }

    static func writeReport(_ data: Data, to directoryURL: URL) throws -> URL {
        let directory = try openDirectory(directoryURL)
        defer { Darwin.close(directory.fd) }
        try requireBound(directory, url: directoryURL)
        let name = "检查报告.json"
        let output = Darwin.openat(directory.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard output >= 0 else { throw posixError() }
        defer { Darwin.close(output) }
        let identity = try snapshot(output)
        do {
            try data.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { try writeAll(output, base: base, count: bytes.count) }
            }
            guard Darwin.fsync(output) == 0 else { throw posixError() }
            try requireBound(directory, url: directoryURL)
            try requireEntry(name, identity: identity, directoryFD: directory.fd)
            return directoryURL.appendingPathComponent(name)
        } catch {
            removeOwned(name, identity: identity, directoryFD: directory.fd)
            throw error
        }
    }

    private struct Opened {
        let fd: Int32
        let info: stat
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") &&
            !name.contains("\\") && !name.utf8.contains(0)
    }

    private static func openFile(_ url: URL) throws -> Opened {
        let path = try checkedPath(url)
        let before = try pathSnapshot(url)
        guard before.st_mode & S_IFMT == S_IFREG else { throw ExportError.unsafePath(url.path) }
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw posixError() }
        do {
            let info = try snapshot(fd)
            guard info.st_mode & S_IFMT == S_IFREG, sameIdentity(before, info) else {
                throw ExportError.changedResource(url.path)
            }
            return Opened(fd: fd, info: info)
        } catch { Darwin.close(fd); throw error }
    }

    private static func openDirectory(_ url: URL) throws -> Opened {
        let path = try checkedPath(url)
        let before = try pathSnapshot(url)
        guard before.st_mode & S_IFMT == S_IFDIR else { throw ExportError.unsafePath(url.path) }
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        do {
            let info = try snapshot(fd)
            guard info.st_mode & S_IFMT == S_IFDIR, sameIdentity(before, info) else {
                throw ExportError.changedResource(url.path)
            }
            return Opened(fd: fd, info: info)
        } catch { Darwin.close(fd); throw error }
    }

    private static func copy(_ source: Opened, sourceURL: URL, name: String,
                             directory: Opened, directoryURL: URL) throws -> stat {
        try requireBound(directory, url: directoryURL)
        let output = Darwin.openat(directory.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard output >= 0 else { throw posixError() }
        defer { Darwin.close(output) }
        let identity = try snapshot(output)
        do {
            var total: Int64 = 0
            try readChunks(source.fd, byteLimit: Int64(source.info.st_size)) { buffer, count in
                try buffer.withUnsafeBytes { bytes in
                    if let base = bytes.baseAddress { try writeAll(output, base: base, count: count) }
                }
                total += Int64(count)
            }
            try requireUnchanged(source, url: sourceURL, bytesRead: total)
            guard Darwin.fsync(output) == 0 else { throw posixError() }
            try requireBound(directory, url: directoryURL)
            try requireEntry(name, identity: identity, directoryFD: directory.fd)
            return identity
        } catch {
            removeOwned(name, identity: identity, directoryFD: directory.fd)
            throw error
        }
    }

    private static func readChunks(_ fd: Int32, byteLimit: Int64, consume: ([UInt8], Int) throws -> Void) throws {
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        var remaining = byteLimit
        while remaining > 0 {
            let request = Int(min(remaining, Int64(buffer.count)))
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, request) }
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            try consume(buffer, count)
            remaining -= Int64(count)
        }
    }

    private static func writeAll(_ fd: Int32, base: UnsafeRawPointer, count: Int) throws {
        var written = 0
        while written < count {
            let amount = Darwin.write(fd, base.advanced(by: written), count - written)
            if amount < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            guard amount > 0 else { throw POSIXError(.EIO) }
            written += amount
        }
    }

    private static func isEmpty(_ fd: Int32) throws -> Bool {
        let duplicate = Darwin.dup(fd)
        guard duplicate >= 0 else { throw posixError() }
        guard let stream = Darwin.fdopendir(duplicate) else {
            let error = posixError()
            Darwin.close(duplicate)
            throw error
        }
        defer { Darwin.closedir(stream) }
        while true {
            errno = 0
            guard let entry = Darwin.readdir(stream) else {
                if errno != 0 { throw posixError() }
                return true
            }
            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name != ".", name != ".." { return false }
        }
    }

    private static func snapshot(_ fd: Int32) throws -> stat {
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0 else { throw posixError() }
        return info
    }

    private static func pathSnapshot(_ url: URL) throws -> stat {
        var info = stat()
        guard Darwin.lstat(try checkedPath(url), &info) == 0 else { throw posixError() }
        return info
    }

    private static func checkedPath(_ url: URL) throws -> String {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw ExportError.unsafePath(url.path) }
        var path = url.path
        // A trailing slash can cause POSIX to follow a final directory symlink.
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func sameIdentity(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    private static func requireUnchanged(_ source: Opened, url: URL, bytesRead: Int64) throws {
        let after = try snapshot(source.fd)
        let path = try pathSnapshot(url)
        guard sameIdentity(source.info, after), sameIdentity(after, path),
              path.st_mode & S_IFMT == S_IFREG, bytesRead == Int64(source.info.st_size),
              source.info.st_size == after.st_size,
              source.info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              source.info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              source.info.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              source.info.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw ExportError.changedResource(url.path)
        }
    }

    private static func requireBound(_ directory: Opened, url: URL) throws {
        let current = try pathSnapshot(url)
        guard current.st_mode & S_IFMT == S_IFDIR, sameIdentity(directory.info, current) else {
            throw ExportError.changedResource(url.path)
        }
    }

    private static func requireEntry(_ name: String, identity: stat, directoryFD: Int32) throws {
        var current = stat()
        guard Darwin.fstatat(directoryFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_mode & S_IFMT == S_IFREG, sameIdentity(identity, current) else {
            throw ExportError.changedResource(name)
        }
    }

    private static func removeOwned(_ name: String, identity: stat, directoryFD: Int32) {
        var current = stat()
        guard Darwin.fstatat(directoryFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_mode & S_IFMT == S_IFREG, sameIdentity(identity, current) else { return }
        _ = Darwin.unlinkat(directoryFD, name, 0)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
