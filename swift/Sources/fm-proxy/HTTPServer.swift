import Foundation
import FoundationModels

final class HTTPServer: @unchecked Sendable {
    let port: UInt16
    let authToken: String?
    private let acceptQueue = DispatchQueue(label: "fm-proxy.http.accept", qos: .userInitiated)
    private let clientQueue = DispatchQueue(label: "fm-proxy.http.client", qos: .userInitiated, attributes: .concurrent)
    
    init(port: UInt16 = 8080, authToken: String? = nil) {
        self.port = port
        self.authToken = authToken
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
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")  // Loopback only
        
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
        
        print("Server running at http://127.0.0.1:\(port)")
        print("Endpoints:")
        print("  GET  /health     - Health check")
        print("  POST /generate   - Text generation")
        if authToken != nil {
            print("Authentication: Required (Bearer token)")
        }
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
        guard let (method, path, body, authHeader) = await withCheckedContinuation({ (continuation: CheckedContinuation<(String, String, String, String?)?, Never>) in
            clientQueue.async {
                continuation.resume(returning: self.readHTTPRequest(socket: socket))
            }
        }) else { return }
        
        // Strip query string from path for routing
        let routePath = path.split(separator: "?").first.map(String.init) ?? path
        
        // Handle OPTIONS preflight without auth
        if method == "OPTIONS" {
            writeToSocket(socket, string: handleCORS())
            return
        }
        
        // Route request
        let response: String
        if method == "GET" && routePath == "/health" {
            response = handleHealth()
        } else if method == "POST" && routePath == "/generate" {
            // Check auth only for /generate
            if let requiredToken = authToken {
                let trimmed = authHeader?.trimmingCharacters(in: .whitespacesAndNewlines)
                let providedToken: String?
                if let trimmed, trimmed.lowercased().hasPrefix("bearer ") {
                    providedToken = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    providedToken = nil
                }
                guard let providedToken, !providedToken.isEmpty, providedToken == requiredToken else {
                    let response = makeResponse(status: "401 Unauthorized", body: #"{"error":"Unauthorized"}"#)
                    writeToSocket(socket, string: response)
                    return
                }
            }
            // Check if streaming requested
            if let data = body.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let stream = json["stream"] as? Bool, stream {
                await handleGenerateStream(socket: socket, body: body)
                return // Already wrote response
            }
            response = await handleGenerate(body: body)
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
              let input = json["input"] as? String else {
            return makeResponse(status: "400 Bad Request", body: #"{"error":"Missing input field"}"#)
        }
        
        // Parse max_output_tokens if provided
        var options: GenerationOptions? = nil
        if let maxTokens = json["max_output_tokens"] as? Int {
            options = GenerationOptions(maximumResponseTokens: maxTokens)
        }
        
        // Parse response_format if provided
        var dynamicSchema: DynamicGenerationSchema? = nil
        if let responseFormat = json["response_format"] as? [String: Any],
           let formatType = responseFormat["type"] as? String,
           formatType == "json_schema",
           let jsonSchema = responseFormat["json_schema"] as? [String: Any],
           let schemaName = jsonSchema["name"] as? String,
           let schema = jsonSchema["schema"] as? [String: Any] {
            let schemaDesc = jsonSchema["description"] as? String
            if let node = parseJSONSchemaNode(schema) {
                dynamicSchema = buildDynamicSchema(from: node, name: schemaName, description: schemaDesc)
            }
        }
        
        do {
            let session = LanguageModelSession()
            if let schema = dynamicSchema {
                let generationSchema = try GenerationSchema(root: schema, dependencies: [])
                let response = options != nil
                    ? try await session.respond(to: input, schema: generationSchema, options: options!)
                    : try await session.respond(to: input, schema: generationSchema)
                let jsonText = generatedContentToJSON(response.content)
                return makeResponse(status: "200 OK", body: #"{"text":\#(jsonText)}"#)
            } else {
                let response = options != nil
                    ? try await session.respond(to: input, options: options!)
                    : try await session.respond(to: input)
                let escaped = escapeJSON(response.content)
                return makeResponse(status: "200 OK", body: #"{"text":"\#(escaped)"}"#)
            }
        } catch {
            let msg = escapeJSON(error.localizedDescription)
            return makeResponse(status: "500 Internal Server Error", body: #"{"error":"\#(msg)"}"#)
        }
    }
    
    private func handleGenerateStream(socket: Int32, body: String) async {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let input = json["input"] as? String else {
            let errorResponse = makeResponse(status: "400 Bad Request", body: #"{"error":"Missing input field"}"#)
            writeToSocket(socket, string: errorResponse)
            return
        }
        
        // Parse max_output_tokens if provided
        var options: GenerationOptions? = nil
        if let maxTokens = json["max_output_tokens"] as? Int {
            options = GenerationOptions(maximumResponseTokens: maxTokens)
        }
        
        // Write SSE headers
        let headers = "HTTP/1.1 200 OK\r\n" +
                      "Content-Type: text/event-stream; charset=utf-8\r\n" +
                      "Cache-Control: no-cache\r\n" +
                      "Connection: keep-alive\r\n" +
                      "X-Accel-Buffering: no\r\n" +
                      "Access-Control-Allow-Origin: *\r\n" +
                      "Access-Control-Allow-Headers: Content-Type\(authToken != nil ? ", Authorization" : "")\r\n\r\n"
        guard writeToSocket(socket, string: headers) else { return }
        
        do {
            let session = LanguageModelSession()
            var previousContent = ""
            let requestId = UUID().uuidString
            let created = Int(Date().timeIntervalSince1970)
            
            // Initial chunk with role
            let roleChunk = #"data: {"id":"\#(requestId)","object":"chat.completion.chunk","created":\#(created),"model":"apple-on-device","choices":[{"index":0,"delta":{"role":"assistant"}}]}"# + "\n\n"
            guard writeToSocket(socket, string: roleChunk) else { return }
            
            let stream = options != nil
                ? session.streamResponse(to: input, options: options!)
                : session.streamResponse(to: input)
            for try await partial in stream {
                let newContent = partial.content
                // Only emit delta if content grew by appending (standard OpenAI behavior)
                if newContent.count > previousContent.count && newContent.hasPrefix(previousContent) {
                    let delta = String(newContent.dropFirst(previousContent.count))
                    let escaped = escapeJSON(delta)
                    let event = #"data: {"id":"\#(requestId)","object":"chat.completion.chunk","created":\#(created),"model":"apple-on-device","choices":[{"index":0,"delta":{"content":"\#(escaped)"}}]}"# + "\n\n"
                    guard writeToSocket(socket, string: event) else { return }
                }
                previousContent = newContent
            }
            
            // Final chunk with finish_reason
            let finishChunk = #"data: {"id":"\#(requestId)","object":"chat.completion.chunk","created":\#(created),"model":"apple-on-device","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"# + "\n\n"
            _ = writeToSocket(socket, string: finishChunk)
            _ = writeToSocket(socket, string: "data: [DONE]\n\n")
        } catch {
            let msg = escapeJSON(error.localizedDescription)
            let errorEvent = #"data: {"error":{"message":"\#(msg)","type":"server_error"}}"# + "\n\n"
            _ = writeToSocket(socket, string: errorEvent)
        }
    }
    
    @discardableResult
    private func writeToSocket(_ socket: Int32, string: String) -> Bool {
        let data = Data(string.utf8)
        return data.withUnsafeBytes { ptr -> Bool in
            var remaining = data.count
            var offset = 0
            while remaining > 0 {
                let written = write(socket, ptr.baseAddress! + offset, remaining)
                if written <= 0 { return false }
                offset += written
                remaining -= written
            }
            return true
        }
    }
    
    private func handleCORS() -> String {
        return "HTTP/1.1 204 No Content\r\n" +
               "Access-Control-Allow-Origin: *\r\n" +
               "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" +
               "Access-Control-Allow-Headers: Content-Type\(authToken != nil ? ", Authorization" : "")\r\n" +
               "Access-Control-Max-Age: 600\r\n" +
               "Content-Length: 0\r\n\r\n"
    }
    
    private func makeResponse(status: String, body: String) -> String {
        return "HTTP/1.1 \(status)\r\n" +
               "Content-Type: application/json\r\n" +
               "Access-Control-Allow-Origin: *\r\n" +
               "Access-Control-Allow-Headers: Content-Type\(authToken != nil ? ", Authorization" : "")\r\n" +
               "Content-Length: \(body.utf8.count)\r\n\r\n" +
               body
    }
    
    private func readHTTPRequest(socket: Int32) -> (method: String, path: String, body: String, authorization: String?)? {
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
        
        // Parse headers
        var contentLength = 0
        var authorization: String? = nil
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(value) ?? 0
            } else if lower.hasPrefix("authorization:") {
                authorization = String(line.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces)
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
        
        return (method, path, body, authorization)
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
    
    // MARK: - Schema Helpers
    
    private func parseJSONSchemaNode(_ dict: [String: Any]) -> JSONSchemaNode? {
        guard let type = dict["type"] as? String else { return nil }
        let description = dict["description"] as? String
        
        switch type {
        case "object":
            let props = dict["properties"] as? [String: [String: Any]] ?? [:]
            var parsedProps: [String: JSONSchemaNode] = [:]
            for (key, value) in props {
                if let node = parseJSONSchemaNode(value) {
                    parsedProps[key] = node
                }
            }
            let required = dict["required"] as? [String]
            return .object(properties: parsedProps, required: required, description: description)
        case "array":
            if let items = dict["items"] as? [String: Any], let itemNode = parseJSONSchemaNode(items) {
                return .array(items: itemNode, description: description)
            }
            return .array(items: .string(description: nil, enumValues: nil), description: description)
        case "string":
            let enumVals = dict["enum"] as? [String]
            return .string(description: description, enumValues: enumVals)
        case "number":
            return .number(description: description)
        case "integer":
            return .integer(description: description)
        case "boolean":
            return .boolean(description: description)
        default:
            return .string(description: description, enumValues: nil)
        }
    }
    
    private func buildDynamicSchema(from node: JSONSchemaNode, name: String, description: String?) -> DynamicGenerationSchema {
        switch node {
        case .object(let properties, _, let desc):
            let schemaProperties = properties.map { (key, value) in
                DynamicGenerationSchema.Property(
                    name: key,
                    description: getDescription(from: value),
                    schema: buildDynamicSchema(from: value, name: key, description: nil)
                )
            }
            return DynamicGenerationSchema(name: name, description: description ?? desc, properties: schemaProperties)
        case .array(let items, _):
            switch items {
            case .string(_, _): return DynamicGenerationSchema(type: [String].self)
            case .integer(_): return DynamicGenerationSchema(type: [Int].self)
            case .number(_): return DynamicGenerationSchema(type: [Double].self)
            case .boolean(_): return DynamicGenerationSchema(type: [Bool].self)
            default: return DynamicGenerationSchema(type: [String].self)
            }
        case .string(let desc, let enumValues):
            if let enumVals = enumValues, !enumVals.isEmpty {
                return DynamicGenerationSchema(name: name, description: description ?? desc, anyOf: enumVals)
            }
            return DynamicGenerationSchema(type: String.self)
        case .number(_):
            return DynamicGenerationSchema(type: Double.self)
        case .integer(_):
            return DynamicGenerationSchema(type: Int.self)
        case .boolean(_):
            return DynamicGenerationSchema(type: Bool.self)
        }
    }
    
    private func getDescription(from node: JSONSchemaNode) -> String? {
        switch node {
        case .object(_, _, let desc): return desc
        case .array(_, let desc): return desc
        case .string(let desc, _): return desc
        case .number(let desc): return desc
        case .integer(let desc): return desc
        case .boolean(let desc): return desc
        }
    }
    
    private func generatedContentToJSON(_ content: GeneratedContent) -> String {
        let jsonValue = contentToJSONValue(content)
        if let data = try? JSONSerialization.data(withJSONObject: jsonValue, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }
    
    private func contentToJSONValue(_ content: GeneratedContent) -> Any {
        switch content.kind {
        case .structure(let properties, _):
            var dict: [String: Any] = [:]
            for (key, value) in properties {
                dict[key] = contentToJSONValue(value)
            }
            return dict
        case .string(let value):
            return value
        default:
            if let arrayVal = try? content.value([String].self) { return arrayVal }
            else if let arrayVal = try? content.value([Int].self) { return arrayVal }
            else if let arrayVal = try? content.value([Double].self) { return arrayVal }
            else if let arrayVal = try? content.value([Bool].self) { return arrayVal }
            if let intVal = try? content.value(Int.self) { return intVal }
            else if let doubleVal = try? content.value(Double.self) { return doubleVal }
            else if let boolVal = try? content.value(Bool.self) { return boolVal }
            else if let stringVal = try? content.value(String.self) { return stringVal }
            return NSNull()
        }
    }
}
