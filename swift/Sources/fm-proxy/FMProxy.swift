import Foundation
import FoundationModels

@main
struct FMProxy {
    static func main() async {
        let args = CommandLine.arguments.dropFirst()
        
        // Check for help
        if args.contains("--help") || args.contains("-h") {
            printUsage()
            return
        }
        
        // Check for version
        if args.contains("--version") || args.contains("-v") {
            print("fm-proxy 1.0.0")
            return
        }
        
        // Check for stdio mode (for npm package)
        if args.contains("--stdio") {
            let transport = StdioTransport()
            let handler = RPCHandler()
            await transport.run(handler: handler)
            return
        }
        
        // Check for serve mode (HTTP server)
        if args.contains("--serve") {
            let portArg = args.first { $0.hasPrefix("--port=") }
            let port: UInt16 = portArg.flatMap { UInt16($0.dropFirst(7)) } ?? 8080
            
            // Auth token from args or env
            let tokenArg = args.first { $0.hasPrefix("--auth-token=") }
            let authToken: String? = tokenArg.map { String($0.dropFirst(13)) } 
                ?? ProcessInfo.processInfo.environment["AUTH_TOKEN"]
            
            let server = HTTPServer(port: port, authToken: authToken)
            await server.start()
            return
        }
        
        // No args = show usage
        if args.isEmpty {
            printUsage()
            return
        }
        
        // Simple CLI mode: treat remaining args as prompt
        let prompt = args.filter { !$0.hasPrefix("-") }.joined(separator: " ")
        if prompt.isEmpty {
            printUsage()
            return
        }
        
        // Check streaming flag
        let streaming = args.contains("--stream") || args.contains("-s")
        
        // Parse max tokens
        let maxTokensArg = args.first { $0.hasPrefix("--max-tokens=") }
        let maxTokens: Int? = maxTokensArg.flatMap { Int($0.dropFirst(13)) }
        
        await runSimpleCLI(prompt: prompt, streaming: streaming, maxTokens: maxTokens)
    }
    
    static func printUsage() {
        let usage = """
        fm-proxy - Apple on-device LLM CLI
        
        USAGE:
            fm-proxy <prompt>              Simple prompt
            fm-proxy --serve               Start HTTP server
            fm-proxy --stdio               stdio mode (for npm package)
        
        OPTIONS:
            -s, --stream       Stream output token by token
            --max-tokens=<N>   Limit response to N tokens
            --serve            Start HTTP server (default port 8080)
            --port=<PORT>      Set server port (use with --serve)
            --auth-token=<T>   Require Bearer token for HTTP requests
            --stdio            Run in stdio mode (for programmatic use)
            -h, --help         Print help
            -v, --version      Print version
        
        ENVIRONMENT:
            AUTH_TOKEN         Same as --auth-token
        
        EXAMPLES:
            fm-proxy "What is the capital of France?"
            fm-proxy --stream "Tell me a story"
            fm-proxy --max-tokens=50 "Count to 100"
            fm-proxy --serve
            fm-proxy --serve --port=3000
            curl -X POST http://127.0.0.1:8080/generate -H "Content-Type: application/json" -d '{"input":"Hello"}'
            curl -X POST http://127.0.0.1:8080/generate -H "Content-Type: application/json" -H "Authorization: Bearer <token>" -d '{"input":"Hello"}'
        """
        print(usage)
    }
    
    static func runSimpleCLI(prompt: String, streaming: Bool, maxTokens: Int? = nil) async {
        // Check availability
        let availability = SystemLanguageModel.default.availability
        guard case .available = availability else {
            switch availability {
            case .unavailable(let reason):
                fputs("Error: Model unavailable - \(reason)\n", stderr)
            case .available:
                break // Already handled by guard
            @unknown default:
                fputs("Error: Model not available\n", stderr)
            }
            exit(1)
        }
        
        do {
            let session = LanguageModelSession()
            let options: GenerationOptions? = maxTokens.map { GenerationOptions(maximumResponseTokens: $0) }
            
            if streaming {
                var previousContent = ""
                let stream = options != nil
                    ? session.streamResponse(to: prompt, options: options!)
                    : session.streamResponse(to: prompt)
                for try await partial in stream {
                    let newContent = partial.content
                    if newContent.count > previousContent.count && newContent.hasPrefix(previousContent) {
                        let delta = String(newContent.dropFirst(previousContent.count))
                        print(delta, terminator: "")
                        fflush(stdout)
                    }
                    previousContent = newContent
                }
                print() // Final newline
            } else {
                let response = options != nil
                    ? try await session.respond(to: prompt, options: options!)
                    : try await session.respond(to: prompt)
                print(response.content)
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
