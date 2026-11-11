import Foundation

/// Thin wrappers over POSIX Unix-domain sockets. Local only: there is no network code in Perch.
public enum UnixSocket {
    public static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, len) }
        }
    }

    public static func setTimeout(_ fd: Int32, _ option: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    public static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    @discardableResult
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        let total = data.count
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return true }
            while sent < total {
                let n = write(fd, base + sent, total - sent)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if n == 0 { return false }
                sent += n
            }
            return true
        }
    }

    /// Reads up to the first newline. Returns nil if the peer closed before sending one.
    public static func readLine(_ fd: Int32, limit: Int) -> Data? {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65_536)
        while out.count < limit {
            let n = read(fd, &buf, buf.count)
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { return nil }
            if let nl = buf[0..<n].firstIndex(of: 0x0A) {
                out.append(contentsOf: buf[0..<nl])
                return out
            }
            out.append(contentsOf: buf[0..<n])
        }
        return nil
    }

    public static func readToEnd(_ fd: Int32, limit: Int) -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 16_384)
        while out.count < limit {
            let n = read(fd, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }
}

/// Listens on the local socket. Each connection sends one line of JSON; the handler then owns
/// the connection and must close it (after replying, for permission requests).
public final class SocketServer {
    public typealias Handler = (_ message: Data, _ fd: Int32) -> Void

    public enum ServerError: Error { case cannotCreate, cannotBind, cannotListen }

    private let path: String
    private let handler: Handler
    private var listenFD: Int32 = -1

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.cannotCreate }
        let bound = UnixSocket.withAddress(path) { addr, len in bind(fd, addr, len) == 0 } ?? false
        guard bound else {
            close(fd)
            throw ServerError.cannotBind
        }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else {
            close(fd)
            throw ServerError.cannotListen
        }
        listenFD = fd
        let handler = self.handler
        let thread = Thread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    break
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    UnixSocket.noSigPipe(client)
                    UnixSocket.setTimeout(client, SO_RCVTIMEO, seconds: 5)
                    guard let line = UnixSocket.readLine(client, limit: 32 << 20) else {
                        close(client)
                        return
                    }
                    UnixSocket.setTimeout(client, SO_RCVTIMEO, seconds: 0)
                    handler(line, client)
                }
            }
        }
        thread.name = "perch.socket"
        thread.start()
    }

    public func stop() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(path)
    }
}

/// What the hook helper does: forward the event, and for a permission request wait for the answer.
public enum HookClient {
    public static func isPermissionRequest(_ input: Data) -> Bool {
        guard let obj = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { return false }
        return obj["hook_event_name"] as? String == HookEvent.Kind.permissionRequest.rawValue
    }

    /// Returns the bytes to print on stdout, or nil for "say nothing" (Claude then behaves as if
    /// Perch were not installed). Never throws: if the app is not running this returns nil at once.
    public static func send(input: Data, socketPath: String, waitForReply: Bool, replyTimeout: Int = 300) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        UnixSocket.noSigPipe(fd)
        UnixSocket.setTimeout(fd, SO_SNDTIMEO, seconds: 3)
        let connected = UnixSocket.withAddress(socketPath) { addr, len in connect(fd, addr, len) == 0 } ?? false
        guard connected else { return nil }
        // JSON never has raw line breaks inside strings, so stripping them keeps it valid
        // and lets a single newline mark the end of the message.
        var line = Data(input.filter { $0 != 0x0A && $0 != 0x0D })
        line.append(0x0A)
        guard UnixSocket.writeAll(fd, line), waitForReply else { return nil }
        UnixSocket.setTimeout(fd, SO_RCVTIMEO, seconds: replyTimeout)
        let reply = UnixSocket.readToEnd(fd, limit: 1 << 20)
        return reply.isEmpty ? nil : reply
    }
}
