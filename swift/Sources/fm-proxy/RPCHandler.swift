import Foundation
import FoundationModels

actor RPCHandler {
    private let protocolVersion = 1
    private var activeRequests: [String: Task<Void, Never>?] = [:]
    private var requestCounter = 0
    
    func handle(_ request: RPCRequest, transport: StdioTransport) async {
        let response: RPCResponse
        
        switch request.method {
        case "health.ping":
            response = handlePing(request)
            
        case "capabilities.get":
            response = handleCapabilities(request)
            
        case "responses.create":
            await handleResponsesCreate(request, transport: transport)
            return
            
        case "responses.cancel":
            response = await handleResponsesCancel(request)
            
        case "process.shutdown":
            response = handleShutdown(request)
            
        default:
            response = .error(id: request.id, code: "INVALID_METHOD", detail: "Unknown method: \(request.method)")
        }
        
        transport.send(response)
    }
    
    // MARK: - health.ping
    
    private func handlePing(_ request: RPCRequest) -> RPCResponse {
        let result = PingResult(ok: true, protocolVersion: protocolVersion)
        return .success(id: request.id, result: .ping(result))
    }
    
    // MARK: - capabilities.get
    
    private func handleCapabilities(_ request: RPCRequest) -> RPCResponse {
        let model = SystemLanguageModel.default
        
        switch model.availability {
        case .available:
            let result = CapabilitiesResult(
                available: true,
                reasonCode: nil,
                model: "apple-on-device"
            )
            return .success(id: request.id, result: .capabilities(result))
            
        case .unavailable(let reason):
            let reasonCode: String
            switch reason {
            case .appleIntelligenceNotEnabled:
                reasonCode = "AI_DISABLED"
            case .deviceNotEligible:
                reasonCode = "UNSUPPORTED_HARDWARE"
            case .modelNotReady:
                reasonCode = "MODEL_NOT_READY"
            @unknown default:
                reasonCode = "AI_DISABLED"
            }
            
            let result = CapabilitiesResult(
                available: false,
                reasonCode: reasonCode,
                model: nil
            )
            return .success(id: request.id, result: .capabilities(result))
            
        @unknown default:
            let result = CapabilitiesResult(
                available: false,
                reasonCode: "UNKNOWN",
                model: nil
            )
            return .success(id: request.id, result: .capabilities(result))
        }
    }
    
    // MARK: - responses.create
    
    private func handleResponsesCreate(_ request: RPCRequest, transport: StdioTransport) async {
        guard case .responsesCreate(let params) = request.params else {
            transport.send(.error(id: request.id, code: "INVALID_PARAMS", detail: "Missing or invalid params for responses.create"))
            return
        }
        
        requestCounter += 1
        let requestId = request.id ?? "req_\(requestCounter)"
        let shouldStream = params.stream ?? false
        
        // Build schema if response_format is provided
        var dynamicSchema: DynamicGenerationSchema? = nil
        if let responseFormat = params.responseFormat,
           responseFormat.type == "json_schema",
           let jsonSchema = responseFormat.jsonSchema {
            dynamicSchema = buildDynamicSchema(from: jsonSchema.schema, name: jsonSchema.name, description: jsonSchema.description)
        }
        
        // Store placeholder before creating task to avoid race condition
        activeRequests[requestId] = .some(nil)
        
        let task = Task {
            defer { self.removeActiveRequest(requestId) }
            
            do {
                let session = LanguageModelSession()
                let prompt = params.input
                
                // Build generation options if max_output_tokens is specified
                var options: GenerationOptions? = nil
                if let maxTokens = params.maxOutputTokens {
                    options = GenerationOptions(maximumResponseTokens: maxTokens)
                }
                
                if shouldStream {
                    // Streaming response (structured output not supported for streaming)
                    if dynamicSchema != nil {
                        let errorEvent = StreamEvent(
                            requestId: requestId,
                            event: "error",
                            delta: nil,
                            text: nil,
                            error: RPCError(code: "INVALID_PARAMS", detail: "response_format is not supported with streaming")
                        )
                        transport.send(.success(id: request.id, result: .streamEvent(errorEvent)))
                        return
                    }
                    
                    var fullText = ""
                    let stream = options != nil 
                        ? session.streamResponse(to: prompt, options: options!)
                        : session.streamResponse(to: prompt)
                    
                    for try await partial in stream {
                        // Check for cancellation
                        if Task.isCancelled {
                            let cancelEvent = StreamEvent(
                                requestId: requestId,
                                event: "error",
                                delta: nil,
                                text: nil,
                                error: RPCError(code: "CANCELLED", detail: "Request was cancelled")
                            )
                            transport.send(.success(id: request.id, result: .streamEvent(cancelEvent)))
                            return
                        }
                        
                        let newContent = partial.content
                        let delta: String
                        if newContent.count > fullText.count && newContent.hasPrefix(fullText) {
                            delta = String(newContent.dropFirst(fullText.count))
                        } else if newContent != fullText {
                            delta = newContent
                        } else {
                            continue
                        }
                        if !delta.isEmpty {
                            fullText = partial.content
                            let event = StreamEvent(
                                requestId: requestId,
                                event: "delta",
                                delta: delta,
                                text: nil,
                                error: nil
                            )
                            transport.send(.success(id: nil, result: .streamEvent(event)))
                        }
                    }
                
                    // Send done event
                    let doneEvent = StreamEvent(
                        requestId: requestId,
                        event: "done",
                        delta: nil,
                        text: fullText,
                        error: nil
                    )
                    transport.send(.success(id: request.id, result: .streamEvent(doneEvent)))
                } else if let schema = dynamicSchema {
                    // Non-streaming with structured output
                    let generationSchema = try GenerationSchema(root: schema, dependencies: [])
                    let response = options != nil
                        ? try await session.respond(to: prompt, schema: generationSchema, options: options!)
                        : try await session.respond(to: prompt, schema: generationSchema)
                    let jsonText = self.generatedContentToJSON(response.content)
                    let result = ResponseResult(requestId: requestId, text: jsonText)
                    transport.send(.success(id: request.id, result: .response(result)))
                } else {
                    // Non-streaming plain text response
                    let response = options != nil
                        ? try await session.respond(to: prompt, options: options!)
                        : try await session.respond(to: prompt)
                    let result = ResponseResult(requestId: requestId, text: response.content)
                    transport.send(.success(id: request.id, result: .response(result)))
                }
            } catch let error as LanguageModelSession.GenerationError {
                let (code, detail) = self.mapGenerationError(error)
                if shouldStream {
                    // Send error as StreamEvent so JS client can match by request_id
                    let errorEvent = StreamEvent(
                        requestId: requestId,
                        event: "error",
                        delta: nil,
                        text: nil,
                        error: RPCError(code: code, detail: detail)
                    )
                    transport.send(.success(id: request.id, result: .streamEvent(errorEvent)))
                } else {
                    transport.send(.error(id: request.id, code: code, detail: detail))
                }
            } catch {
                if shouldStream {
                    let errorEvent = StreamEvent(
                        requestId: requestId,
                        event: "error",
                        delta: nil,
                        text: nil,
                        error: RPCError(code: "INTERNAL", detail: error.localizedDescription)
                    )
                    transport.send(.success(id: request.id, result: .streamEvent(errorEvent)))
                } else {
                    transport.send(.error(id: request.id, code: "INTERNAL", detail: error.localizedDescription))
                }
            }
        }
        
        // Update with actual task (placeholder was set above)
        activeRequests[requestId] = task
    }
    
    // MARK: - Schema Helpers
    
    nonisolated private func buildDynamicSchema(from node: JSONSchemaNode, name: String, description: String?) -> DynamicGenerationSchema {
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
            // Use native array type for simple item types
            switch items {
            case .string(_, _):
                return DynamicGenerationSchema(type: [String].self)
            case .integer(_):
                return DynamicGenerationSchema(type: [Int].self)
            case .number(_):
                return DynamicGenerationSchema(type: [Double].self)
            case .boolean(_):
                return DynamicGenerationSchema(type: [Bool].self)
            default:
                // For complex items (objects/arrays), fall back to array of strings
                return DynamicGenerationSchema(type: [String].self)
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
    
    nonisolated private func getDescription(from node: JSONSchemaNode) -> String? {
        switch node {
        case .object(_, _, let desc): return desc
        case .array(_, let desc): return desc
        case .string(let desc, _): return desc
        case .number(let desc): return desc
        case .integer(let desc): return desc
        case .boolean(let desc): return desc
        }
    }
    
    nonisolated private func generatedContentToJSON(_ content: GeneratedContent) -> String {
        let jsonValue = contentToJSONValue(content)
        if let data = try? JSONSerialization.data(withJSONObject: jsonValue, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }
    
    nonisolated private func contentToJSONValue(_ content: GeneratedContent) -> Any {
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
            // Try array extraction first
            if let arrayVal = try? content.value([String].self) {
                return arrayVal
            } else if let arrayVal = try? content.value([Int].self) {
                return arrayVal
            } else if let arrayVal = try? content.value([Double].self) {
                return arrayVal
            } else if let arrayVal = try? content.value([Bool].self) {
                return arrayVal
            }
            // Handle primitive types
            if let intVal = try? content.value(Int.self) {
                return intVal
            } else if let doubleVal = try? content.value(Double.self) {
                return doubleVal
            } else if let boolVal = try? content.value(Bool.self) {
                return boolVal
            } else if let stringVal = try? content.value(String.self) {
                return stringVal
            }
            return NSNull()
        }
    }
    
    private func removeActiveRequest(_ id: String) {
        activeRequests.removeValue(forKey: id)
    }
    
    nonisolated private func mapGenerationError(_ error: LanguageModelSession.GenerationError) -> (code: String, detail: String) {
        let desc = String(describing: error)
        if desc.contains("rateLimited") || desc.contains("rateLimit") {
            return ("RATE_LIMITED", "Rate limited by the system. Try again later.")
        } else if desc.contains("guardrail") || desc.contains("Guardrail") {
            return ("GUARDRAIL", "The request violated content guidelines.")
        } else {
            // Log unrecognized error type for debugging
            fputs("Warning: Unrecognized GenerationError: \(desc)\n", stderr)
            return ("GENERATION_ERROR", "Generation failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - responses.cancel
    
    private func handleResponsesCancel(_ request: RPCRequest) async -> RPCResponse {
        guard case .responsesCancel(let params) = request.params else {
            return .error(id: request.id, code: "INVALID_PARAMS", detail: "Missing request_id")
        }
        
        guard activeRequests.keys.contains(params.requestId) else {
            return .error(id: request.id, code: "NOT_FOUND", detail: "Request not found: \(params.requestId)")
        }
        
        if let task = activeRequests[params.requestId] ?? nil {
            task.cancel()
        }
        activeRequests.removeValue(forKey: params.requestId)
        return .success(id: request.id, result: .empty)
    }
    
    // MARK: - process.shutdown
    
    private func handleShutdown(_ request: RPCRequest) -> RPCResponse {
        // Cancel all active requests
        for (_, task) in activeRequests {
            task?.cancel()
        }
        activeRequests.removeAll()
        
        // Schedule exit after response is sent
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            exit(0)
        }
        
        return .success(id: request.id, result: .empty)
    }
}
