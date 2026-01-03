import Foundation

/// LSP-style stdio transport with Content-Length framing
/// Uses a dedicated thread for blocking stdin reads to avoid starving the cooperative thread pool
final class StdioTransport: @unchecked Sendable {
    private let stdin = FileHandle.standardInput
    private let stdout = FileHandle.standardOutput
    private let stderr = FileHandle.standardError
    private let writeLock = NSLock()
    private let readQueue = DispatchQueue(label: "fm-proxy.stdin", qos: .userInitiated)
    
    func run(handler: RPCHandler) async {
        log("fm-proxy started")
        
        while true {
            do {
                guard let message = try await readMessageAsync() else {
                    log("stdin closed, exiting")
                    break
                }
                
                await handler.handle(message, transport: self)
            } catch {
                log("error: \(error)")
                let errorResponse = RPCResponse.error(
                    id: nil,
                    code: "INTERNAL",
                    detail: error.localizedDescription
                )
                if let data = try? JSONEncoder().encode(errorResponse) {
                    try? writeRaw(data)
                }
            }
        }
    }
    
    private func readMessageAsync() async throws -> RPCRequest? {
        try await withCheckedThrowingContinuation { continuation in
            readQueue.async {
                do {
                    let result = try self.readMessage()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func send(_ response: RPCResponse) {
        do {
            try writeMessage(response)
        } catch {
            log("failed to send response: \(error)")
        }
    }
    
    private func readMessage() throws -> RPCRequest? {
        // Read headers until empty line
        var contentLength: Int?
        
        while true {
            guard let line = readHeaderLine() else {
                return nil
            }
            
            if line.isEmpty {
                break
            }
            
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(value)
            }
        }
        
        guard let length = contentLength, length > 0 else {
            throw TransportError.missingContentLength
        }
        
        guard length <= 10_000_000 else { // 10MB max
            throw TransportError.messageTooLarge(length)
        }
        
        // Read body - loop to handle partial reads on pipes
        var data = Data()
        data.reserveCapacity(length)
        while data.count < length {
            let chunk = stdin.readData(ofLength: length - data.count)
            if chunk.isEmpty {
                throw TransportError.unexpectedEOF
            }
            data.append(chunk)
        }
        
        return try JSONDecoder().decode(RPCRequest.self, from: data)
    }
    
    private func writeMessage(_ response: RPCResponse) throws {
        let data = try JSONEncoder().encode(response)
        try writeRaw(data)
    }
    
    private func writeRaw(_ data: Data) throws {
        let header = "Content-Length: \(data.count)\r\n\r\n"
        guard let headerData = header.data(using: .utf8) else {
            throw TransportError.encodingError
        }
        
        // Combine header and body into single write to ensure atomicity
        var combined = headerData
        combined.append(data)
        
        // Synchronize writes to prevent interleaving from concurrent sends
        writeLock.lock()
        defer { writeLock.unlock() }
        stdout.write(combined)
    }
    
    private func readHeaderLine() -> String? {
        var line = ""
        while true {
            let data = stdin.readData(ofLength: 1)
            guard data.count == 1, let char = String(data: data, encoding: .utf8) else {
                return line.isEmpty ? nil : line
            }
            if char == "\n" {
                // Strip trailing \r if present
                if line.hasSuffix("\r") {
                    line.removeLast()
                }
                return line
            }
            line += char
        }
    }
    
    func log(_ message: String) {
        let formatted = "[fm-proxy] \(message)\n"
        if let data = formatted.data(using: .utf8) {
            stderr.write(data)
        }
    }
}

enum TransportError: Error {
    case missingContentLength
    case messageTooLarge(Int)
    case unexpectedEOF
    case encodingError
}
