import Foundation
import FoundationModels

final class HTTPServer: Sendable {
    let port: UInt16
    private let acceptQueue = DispatchQueue(label: "fm-proxy.http.accept", qos: .userInitiated)
    private let clientQueue = DispatchQueue(label: "fm-proxy.http.client", qos: .userInitiated, attributes: .concurrent)
    
    init(port: UInt16 = 8080) {
        self.port = port
    }
    
    func start() async {
        let serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            fputs("Error: Could not create socket\n", stderr)
            exit(1)
        }
        
        var reuse: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        guard bindResult >= 0 else {
            fputs("Error: Could not bind to port \(port)\n", stderr)
            exit(1)
        }
        
        guard listen(serverSocket, 10) >= 0 else {
            fputs("Error: Could not listen on socket\n", stderr)
            exit(1)
        }
        
        print("Server running at http://localhost:\(port)")
        print("Endpoints:")
        print("  GET  /health     - Health check")
        print("  POST /generate   - Text generation")
        print("")
        
        // Run blocking accept loop on dedicated thread
        acceptQueue.async {
            while true {
                var clientAddr = sockaddr_in()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                
                let clientSocket = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        accept(serverSocket, $0, &clientAddrLen)
                    }
                }
                
                if clientSocket >= 0 {
                    // Prevent SIGPIPE crash when client disconnects
                    var nosigpipe: Int32 = 1
                    setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
                    
                    Task {
                        await self.handleClient(clientSocket)
                    }
                } else {
                    // Handle accept errors - sleep briefly to avoid hot-spin
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
        }
        
        // Keep the async context alive forever (server runs until process exits)
        while true {
            try? await Task.sleep(for: .seconds(86400))
        }
    }
    
    private func handleClient(_ socket: Int32) async {
        defer { close(socket) }
        
        // Read HTTP request on dedicated queue to avoid blocking async executor
        guard let (method, path, body) = await withCheckedContinuation({ (continuation: CheckedContinuation<(String, String, String)?, Never>) in
            clientQueue.async {
                continuation.resume(returning: self.readHTTPRequest(socket: socket))
            }
        }) else { return }
        
        
        // Route request
        let response: String
        // Strip query string from path for routing
        let routePath = path.split(separator: "?").first.map(String.init) ?? path
        
        if method == "GET" && routePath == "/health" {
            response = handleHealth()
        } else if method == "POST" && routePath == "/generate" {
            response = await handleGenerate(body: body)
        } else if method == "OPTIONS" {
            response = handleCORS()
        } else {
            response = makeResponse(status: "404 Not Found", body: #"{"error":"Not found"}"#)
        }
        
        // Write response, handling partial writes
        let responseData = Data(response.utf8)
        responseData.withUnsafeBytes { ptr in
            var remaining = responseData.count
            var offset = 0
            while remaining > 0 {
                let written = write(socket, ptr.baseAddress! + offset, remaining)
                if written <= 0 { break }
                offset += written
                remaining -= written
            }
        }
    }
    
    private func handleHealth() -> String {
        let available = SystemLanguageModel.default.availability
        let status: String
        switch available {
        case .available:
            status = #"{"status":"ok","model":"apple-on-device","available":true}"#
        default:
            status = #"{"status":"ok","model":"apple-on-device","available":false}"#
        }
        return makeResponse(status: "200 OK", body: status)
    }
    
    private func handleGenerate(body: String) async -> String {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prompt = json["prompt"] as? String else {
            return makeResponse(status: "400 Bad Request", body: #"{"error":"Missing prompt field"}"#)
        }
        
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            let escaped = escapeJSON(response.content)
            return makeResponse(status: "200 OK", body: #"{"text":"\#(escaped)"}"#)
        } catch {
            let msg = escapeJSON(error.localizedDescription)
            return makeResponse(status: "500 Internal Server Error", body: #"{"error":"\#(msg)"}"#)
        }
    }
    
    private func handleCORS() -> String {
        return "HTTP/1.1 204 No Content\r\n" +
               "Access-Control-Allow-Origin: *\r\n" +
               "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" +
               "Access-Control-Allow-Headers: Content-Type\r\n" +
               "Content-Length: 0\r\n\r\n"
    }
    
    private func makeResponse(status: String, body: String) -> String {
        return "HTTP/1.1 \(status)\r\n" +
               "Content-Type: application/json\r\n" +
               "Access-Control-Allow-Origin: *\r\n" +
               "Content-Length: \(body.utf8.count)\r\n\r\n" +
               body
    }
    
    private func readHTTPRequest(socket: Int32) -> (method: String, path: String, body: String)? {
        var headerData = Data()
        var buffer = [UInt8](repeating: 0, count: 1)
        
        // Read headers byte by byte until \r\n\r\n
        while headerData.count < 65536 { // 64KB max headers
            let bytesRead = read(socket, &buffer, 1)
            guard bytesRead == 1 else { return nil }
            headerData.append(buffer[0])
            
            if headerData.count >= 4 {
                let suffix = headerData.suffix(4)
                if suffix.elementsEqual([0x0D, 0x0A, 0x0D, 0x0A]) { // \r\n\r\n
                    break
                }
            }
        }
        
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        
        let method = String(parts[0])
        let path = String(parts[1])
        
        // Parse Content-Length
        var contentLength = 0
        for line in lines {
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(value) ?? 0
                break
            }
        }
        
        // Read body if present
        var body = ""
        if contentLength > 0 && contentLength <= 10_000_000 { // 10MB max
            var bodyBuffer = [UInt8](repeating: 0, count: contentLength)
            var totalRead = 0
            while totalRead < contentLength {
                let bytesRead = read(socket, &bodyBuffer[totalRead], contentLength - totalRead)
                if bytesRead <= 0 { break }
                totalRead += bytesRead
            }
            body = String(bytes: bodyBuffer[0..<totalRead], encoding: .utf8) ?? ""
        }
        
        return (method, path, body)
    }
    
    private func escapeJSON(_ str: String) -> String {
        var result = ""
        result.reserveCapacity(str.count)
        for scalar in str.unicodeScalars {
            switch scalar {
            case "\\":
                result += "\\\\"
            case "\"":
                result += "\\\""
            case "\n":
                result += "\\n"
            case "\r":
                result += "\\r"
            case "\t":
                result += "\\t"
            case "\u{08}":
                result += "\\b"
            case "\u{0C}":
                result += "\\f"
            case let s where s.value < 0x20:
                result += String(format: "\\u%04x", s.value)
            default:
                result += String(scalar)
            }
        }
        return result
    }
}
