import CryptoKit
import Foundation
import Network

/// Receives footage from the iPhone over the local network and serves the
/// labelled road-memory file back to it.
///
/// Every upload is SHA-256 verified before the phone is told it may delete
/// its copy — the phone never removes anything the Mac hasn't proven it has.
public final class OffloadReceiver: @unchecked Sendable {
    public struct Event: Sendable {
        public enum Kind: Sendable { case started, received, rejected, failed, info }
        public var kind: Kind
        public var message: String
        public var date: Date = Date()
    }

    public let workspace: Workspace
    public let port: UInt16

    /// One file arriving right now.
    public struct Progress: Sendable, Identifiable, Equatable {
        public var id: String { fileName }
        public var fileName: String
        public var received: Int64
        public var total: Int64
        public var finished: Bool

        public var fraction: Double {
            total > 0 ? min(1, Double(received) / Double(total)) : 0
        }
    }

    /// Called on the main queue for UI updates and logging.
    public var onEvent: (@Sendable (Event) -> Void)?
    /// Fired for every exchange with the phone, so the training console can
    /// show the loop working rather than assert that it does.
    public var onSync: (@Sendable (SyncEvent) -> Void)?
    public lazy var syncLog = SyncLogStore(workspace: workspace)
    /// Live byte progress per incoming file, on the main queue.
    public var onProgress: (@Sendable (Progress) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dashcam.receiver")

    public init(workspace: Workspace, port: UInt16 = 42841) {
        self.workspace = workspace
        self.port = port
    }

    /// Removes half-finished uploads left behind when a transfer was cut off
    /// (app relaunch, network drop). They're never usable — the phone
    /// re-sends the whole file — and they'd otherwise accumulate.
    private func cleanUpStaleTransfers() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: workspace.root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else { return }

        var removed = 0
        var bytes: Int64 = 0
        for file in files where file.lastPathComponent.hasPrefix(".incoming-") {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            // Anything untouched for 5 minutes is abandoned, not in flight.
            if let modified = values?.contentModificationDate,
               Date().timeIntervalSince(modified) < 300 { continue }
            bytes += Int64(values?.fileSize ?? 0)
            try? fm.removeItem(at: file)
            removed += 1
        }
        if removed > 0 {
            emit(.info, "Cleared \(removed) interrupted transfer(s), \(bytes / 1_000_000) MB")
        }
    }

    public func start() throws {
        guard listener == nil else { return }
        cleanUpStaleTransfers()
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.service = NWListener.Service(
            name: Host.current().localizedName ?? "Mac",
            type: "_dashcam-offload._tcp"
        )
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Handler(connection: connection, receiver: self).start()
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.emit(.info, "Ready on port \(self.port) — saving to \(self.workspace.root.path)")
            case .failed(let error):
                self.emit(.failed, "Listener failed: \(error.localizedDescription)")
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        emit(.info, "Stopped")
    }

    fileprivate func record(
        _ direction: SyncEvent.Direction, _ action: String, _ summary: String,
        _ outcome: SyncEvent.Outcome, _ detail: [String: String] = [:]
    ) {
        let event = SyncEvent(
            at: Date(), direction: direction, action: action,
            summary: summary, outcome: outcome, detail: detail
        )
        syncLog.append(event)
        DispatchQueue.main.async { [weak self] in self?.onSync?(event) }
    }

    fileprivate func emit(_ kind: Event.Kind, _ message: String) {
        let event = Event(kind: kind, message: message)
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }

    fileprivate func emitProgress(_ progress: Progress) {
        DispatchQueue.main.async { [weak self] in
            self?.onProgress?(progress)
        }
    }

    // MARK: - One connection

    private final class Handler {
        private let connection: NWConnection
        private unowned let receiver: OffloadReceiver
        private let queue = DispatchQueue(label: "dashcam.receiver.connection")

        private var headerData = Data()
        private var headersParsed = false
        private var contentLength = 0
        /// Non-nil while a JSON request body is being buffered.
        private var jsonBody: Data?
        private enum JSONKind { case forget, syncReport }
        private var jsonKind: JSONKind = .forget
        private var received = 0
        private var fileName = ""
        private var expectedHash = ""
        private var tempURL: URL?
        private var fileHandle: FileHandle?
        private var hasher = SHA256()
        private var finished = false
        private var lastReportedBytes = 0

        init(connection: NWConnection, receiver: OffloadReceiver) {
            self.connection = connection
            self.receiver = receiver
        }

        func start() {
            connection.start(queue: queue)
            receive()
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [self] data, _, isComplete, error in
                if let data, !data.isEmpty { process(data) }
                if finished { return }
                if error != nil || isComplete {
                    cleanupPartial("connection closed early")
                    return
                }
                receive()
            }
        }

        private func process(_ data: Data) {
            if headersParsed {
                consumeBody(data)
                return
            }
            headerData.append(data)
            guard let headerEnd = headerData.range(of: Data("\r\n\r\n".utf8)) else { return }

            let headerText = String(decoding: headerData[..<headerEnd.lowerBound], as: UTF8.self)
            let bodyStart = headerData[headerEnd.upperBound...]
            headersParsed = true

            var headers: [String: String] = [:]
            let lines = headerText.components(separatedBy: "\r\n")
            let requestParts = (lines.first ?? "").components(separatedBy: " ")
            let method = requestParts.first ?? ""
            let path = requestParts.count > 1 ? requestParts[1] : ""
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()] =
                    String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }

            if method == "GET", path.hasPrefix("/ping") {
                receiver.record(.phoneToMac, "GET /ping", "Phone checked in", .ok)
                respond(status: "200 OK", json: [
                    "service": "dashcam-offload",
                    "version": "2",
                    "destination": receiver.workspace.root.path,
                ])
                return
            }

            // The phone pulls labelled road memory from here.
            if method == "GET", path.hasPrefix("/memory") {
                let url = receiver.workspace.roadMemoryFile
                if let data = try? Data(contentsOf: url) {
                    let count = (try? JSONSerialization.jsonObject(with: data))
                        .flatMap { ($0 as? [String: Any])?["features"] as? [Any] }?.count ?? 0
                    receiver.emit(.info, "Served road memory (\(data.count) bytes)")
                    receiver.record(
                        .macToPhone, "GET /memory",
                        "Phone pulled \(count) corrected feature(s)", .ok,
                        ["features": "\(count)", "bytes": "\(data.count)"]
                    )
                    respondRaw(status: "200 OK", contentType: "application/json", body: data)
                } else {
                    receiver.record(
                        .macToPhone, "GET /memory",
                        "Phone asked for corrections, but none have been exported yet",
                        .rejected
                    )
                    respond(status: "404 Not Found", json: ["error": "no road memory exported yet"])
                }
                return
            }

            // The phone pushes signs the driver removed by long-pressing them
            // on the live view. Recording them here is what stops the next
            // export from handing the same wrong sign straight back.
            if method == "POST", path.hasPrefix("/sync-report") {
                guard let lengthText = headers["content-length"],
                      let length = Int(lengthText), length > 0, length < 100_000 else {
                    respond(status: "400 Bad Request", json: ["error": "bad content-length"])
                    return
                }
                contentLength = length
                jsonBody = Data()
                jsonKind = .syncReport
                if !bodyStart.isEmpty { consumeBody(Data(bodyStart)) }
                return
            }

            if method == "POST", path.hasPrefix("/forget") {
                guard let lengthText = headers["content-length"],
                      let length = Int(lengthText), length > 0, length < 1_000_000 else {
                    respond(status: "400 Bad Request", json: ["error": "missing or unreasonable content-length"])
                    return
                }
                contentLength = length
                jsonBody = Data()
                jsonKind = .forget
                if !bodyStart.isEmpty { consumeBody(Data(bodyStart)) }
                return
            }

            guard method == "POST", path.hasPrefix("/upload") else {
                respond(status: "404 Not Found", json: ["error": "unknown endpoint"])
                return
            }
            guard let rawName = headers["x-file-name"], !rawName.isEmpty,
                  let hash = headers["x-sha256"], !hash.isEmpty,
                  let lengthText = headers["content-length"], let length = Int(lengthText), length > 0 else {
                respond(status: "400 Bad Request", json: ["error": "missing upload headers"])
                return
            }

            fileName = (rawName as NSString).lastPathComponent
            expectedHash = hash.lowercased()
            contentLength = length

            let temp = receiver.workspace.root
                .appendingPathComponent(".incoming-\(UUID().uuidString)-\(fileName)")
            FileManager.default.createFile(atPath: temp.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: temp) else {
                respond(status: "500 Internal Server Error", json: ["error": "cannot open destination"])
                return
            }
            tempURL = temp
            fileHandle = handle
            receiver.emit(.started, "Receiving \(fileName)…")

            if !bodyStart.isEmpty { consumeBody(Data(bodyStart)) }
        }

        /// The phone telling the Mac what it did with the last export. This
        /// is the only way to know corrections actually landed.
        private func handleSyncReport(_ data: Data) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let report = try decoder.decode(PhoneReport.self, from: data)
                receiver.syncLog.save(report)
                receiver.emit(.info, "Phone imported \(report.imported) correction(s)")
                receiver.record(
                    .phoneToMac, "POST /sync-report",
                    "Phone accepted \(report.imported) correction(s); now holds \(report.featuresHeld)",
                    report.imported > 0 ? .ok : .info,
                    [
                        "imported": "\(report.imported)",
                        "already known": "\(report.skippedAlreadyKnown)",
                        "refused (removed)": "\(report.refusedForgotten)",
                        "unsupported": "\(report.unsupported)",
                        "features held": "\(report.featuresHeld)",
                        "device": report.deviceName,
                        "app": report.appVersion,
                    ]
                )
                respond(status: "200 OK", json: ["ok": "1"])
            } catch {
                receiver.record(
                    .phoneToMac, "POST /sync-report",
                    "Could not read the phone's report: \(error.localizedDescription)", .failed
                )
                respond(status: "400 Bad Request", json: ["error": "bad report"])
            }
        }

        /// Merges the phone's removals into the workspace's tombstone file.
        private func handleForgetPayload(_ data: Data) {
            do {
                let incoming = try ForgottenStore.decoder().decode([ForgottenFeatureRecord].self, from: data)
                let total = try ForgottenStore.merge(incoming, in: receiver.workspace)
                receiver.emit(.info, "Phone removed \(incoming.count) sign(s) from memory (\(total) total)")
                receiver.record(
                    .phoneToMac, "POST /forget",
                    "Phone removed \(incoming.count) sign(s); \(total) removal(s) on record", .ok,
                    ["removed now": "\(incoming.count)", "total removals": "\(total)",
                     "types": incoming.map(\.type).joined(separator: ", ")]
                )
                respond(status: "200 OK", json: ["accepted": "\(incoming.count)", "total": "\(total)"])
            } catch {
                receiver.emit(.failed, "Could not read removals from phone: \(error.localizedDescription)")
                receiver.record(.phoneToMac, "POST /forget",
                                "Removals payload was unreadable", .failed)
                respond(status: "400 Bad Request", json: ["error": "bad payload"])
            }
        }

        private func consumeBody(_ data: Data) {
            // A JSON request (currently only /forget) buffers in memory
            // rather than streaming to a file.
            if jsonBody != nil {
                jsonBody?.append(data)
                received += data.count
                if received >= contentLength {
                    let body = jsonBody ?? Data()
                    jsonBody = nil
                    switch jsonKind {
                    case .forget: handleForgetPayload(body)
                    case .syncReport: handleSyncReport(body)
                    }
                }
                return
            }
            guard let handle = fileHandle else { return }
            let remaining = contentLength - received
            let chunk = data.count > remaining ? data.prefix(remaining) : data[...]
            do {
                try handle.write(contentsOf: chunk)
            } catch {
                cleanupPartial("write failed: \(error.localizedDescription)")
                return
            }
            hasher.update(data: chunk)
            received += chunk.count

            // Report progress every megabyte — enough for a smooth bar
            // without flooding the main queue.
            if received - lastReportedBytes >= 1_000_000 || received >= contentLength {
                lastReportedBytes = received
                receiver.emitProgress(OffloadReceiver.Progress(
                    fileName: fileName,
                    received: Int64(received),
                    total: Int64(contentLength),
                    finished: false
                ))
            }

            if received >= contentLength { finalize() }
        }

        private func finalize() {
            try? fileHandle?.close()
            fileHandle = nil
            guard let temp = tempURL else { return }

            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == expectedHash else {
                try? FileManager.default.removeItem(at: temp)
                receiver.emit(.rejected, "\(fileName): checksum mismatch — kept on phone")
                respond(status: "409 Conflict", json: ["verified": false, "error": "checksum mismatch"])
                return
            }

            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "yyyy-MM-dd"
            dayFormatter.locale = Locale(identifier: "en_US_POSIX")
            let dayFolder = receiver.workspace.root
                .appendingPathComponent(dayFormatter.string(from: Date()), isDirectory: true)
            try? FileManager.default.createDirectory(at: dayFolder, withIntermediateDirectories: true)

            let destination = dayFolder.appendingPathComponent(fileName)
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
                } else {
                    try FileManager.default.moveItem(at: temp, to: destination)
                }
            } catch {
                try? FileManager.default.removeItem(at: temp)
                receiver.emit(.failed, "\(fileName): \(error.localizedDescription)")
                respond(status: "500 Internal Server Error", json: ["verified": false])
                return
            }

            let mb = Double(contentLength) / 1_000_000
            receiver.emitProgress(OffloadReceiver.Progress(
                fileName: fileName, received: Int64(contentLength),
                total: Int64(contentLength), finished: true
            ))
            receiver.emit(.received, String(format: "%@ (%.1f MB) verified", fileName, mb))
            respond(status: "200 OK", json: ["verified": true])
        }

        private func cleanupPartial(_ reason: String) {
            guard !finished else { return }
            finished = true
            try? fileHandle?.close()
            if let temp = tempURL { try? FileManager.default.removeItem(at: temp) }
            if !fileName.isEmpty {
                receiver.emitProgress(OffloadReceiver.Progress(
                    fileName: fileName, received: Int64(received),
                    total: Int64(contentLength), finished: true
                ))
                receiver.emit(.failed, "\(fileName): \(reason)")
            }
            connection.cancel()
        }

        private func respond(status: String, json: [String: Any]) {
            let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
            respondRaw(status: status, contentType: "application/json", body: body)
        }

        private func respondRaw(status: String, contentType: String, body: Data) {
            guard !finished else { return }
            finished = true
            var response = "HTTP/1.1 \(status)\r\n"
            response += "Content-Type: \(contentType)\r\n"
            response += "Content-Length: \(body.count)\r\n"
            response += "Connection: close\r\n\r\n"
            var payload = Data(response.utf8)
            payload.append(body)
            connection.send(content: payload, completion: .contentProcessed { [self] _ in
                connection.cancel()
            })
        }
    }
}
