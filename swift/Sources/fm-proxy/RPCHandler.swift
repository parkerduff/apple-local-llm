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
        
        // Store placeholder before creating task to avoid race condition
        activeRequests[requestId] = .some(nil)
        
        let task = Task {
            defer { self.removeActiveRequest(requestId) }
            
            do {
                let session = LanguageModelSession()
                let prompt = params.input
                
                if shouldStream {
                    // Streaming response
                    var fullText = ""
                    let stream = session.streamResponse(to: prompt)
                    
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
                } else {
                    // Non-streaming response
                    let response = try await session.respond(to: prompt)
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
