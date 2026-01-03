# apple-local-llm

Call Apple's on-device Foundation Models from JavaScript — no servers, no setup.

Works with Node.js, Electron, and VS Code extensions.

## Requirements

- **macOS 26+** (Tahoe)
- **Apple Silicon** (M Series)
- **Apple Intelligence enabled** in System Settings

## Installation

```bash
npm install apple-local-llm
```

## Quick Start

### Simple API

```typescript
import { createClient } from "apple-local-llm";

const client = createClient();

// Check compatibility first
const compat = await client.compatibility.check();
if (!compat.compatible) {
  console.log("Not available:", compat.reasonCode);
  // Handle fallback to cloud API
}

// Generate a response
const result = await client.responses.create({
  input: "What is the capital of France?",
});

if (result.ok) {
  console.log(result.text); // "The capital of France is Paris."
}
```

### Streaming

```typescript
for await (const chunk of client.stream({ input: "Count from 1 to 5." })) {
  if ("delta" in chunk) {
    process.stdout.write(chunk.delta);
  }
}
```

## API Reference

### `createClient(options?)`

Creates a new client instance.

```typescript
const client = createClient({
  model: "default",               // Optional: model identifier (currently only "default")
  onLog: (msg) => console.log(msg), // Optional: debug logging
  idleTimeoutMs: 5 * 60 * 1000,     // Optional: helper idle timeout (default: 5 min)
});
```

**Defaults:**
- Helper auto-shuts down after 5 minutes of inactivity
- Helper auto-restarts up to 3 times on crash (with exponential backoff)
- Request timeout: 60 seconds (configurable via `timeoutMs`)

You can also import and instantiate the class directly:
```typescript
import { AppleLocalLLMClient } from "apple-local-llm";
const client = new AppleLocalLLMClient(options);
```

### `client.compatibility.check()`

Check if the local model is available. Always call this before making requests.

```typescript
const result = await client.compatibility.check();
// { compatible: true }
// or { compatible: false, reasonCode: "AI_DISABLED" }
```

**Reason codes:**
| Code | Description |
|------|-------------|
| `NOT_DARWIN` | Not running on macOS |
| `UNSUPPORTED_HARDWARE` | Not Apple Silicon |
| `AI_DISABLED` | Apple Intelligence not enabled |
| `MODEL_NOT_READY` | Model still downloading |
| `SPAWN_FAILED` | Helper binary failed to start |
| `HELPER_NOT_FOUND` | Helper binary not found |
| `HELPER_UNHEALTHY` | Helper process not responding correctly |
| `PROTOCOL_MISMATCH` | Helper version incompatible with client |

### `client.capabilities.get()`

Get detailed model capabilities (calls the helper).

```typescript
const caps = await client.capabilities.get();
// { available: true, model: "apple-on-device" }
// or { available: false, reasonCode: "AI_DISABLED" }
```

### `client.responses.create(params)`

Generate a response.

```typescript
const result = await client.responses.create({
  input: "Your prompt here",
  model: "default",         // Optional: model identifier
  max_output_tokens: 1000,  // Optional
  stream: false,            // Optional
  signal: abortController.signal, // Optional: AbortSignal
  timeoutMs: 60000,         // Optional: request timeout (ms)
});
```

Returns `ResponseResult` on success, or an error object:
```typescript
// Success:
{ ok: true, text: "...", request_id: "..." }
// Error:
{ ok: false, error: { code: "...", detail: "..." } }
```

Note: The return type is a discriminated union, not the exported `ResponseResult` interface.

**Error codes:**
| Code | Description |
|------|-------------|
| `UNAVAILABLE` | Model not available (see reason codes above) |
| `TIMEOUT` | Request timed out (default: 60s) |
| `CANCELLED` | Request was cancelled via AbortSignal |
| `RATE_LIMITED` | System rate limit exceeded |
| `GUARDRAIL` | Content violated Apple's safety guidelines |
| `INTERNAL` | Unexpected error |

### `client.stream(params)`

Async generator for streaming responses.

```typescript
for await (const chunk of client.stream({ input: "..." })) {
  if ("delta" in chunk) {
    // Partial content
    console.log(chunk.delta);
  } else if ("done" in chunk) {
    // Final complete text
    console.log(chunk.text);
  }
}
```

### `client.responses.cancel(requestId)`

Cancel an in-progress request.

```typescript
const result = await client.responses.cancel("req_123");
// { ok: true } or { ok: false, error: { code: "NOT_RUNNING", detail: "..." } }
```

### `client.shutdown()`

Gracefully shut down the helper process.

```typescript
await client.shutdown();
```

## TypeScript Types

All types are exported:

```typescript
import type {
  ClientOptions,
  ReasonCode,
  CompatibilityResult,
  CapabilitiesResult,
  ResponsesCreateParams,
  ResponseResult,
} from "apple-local-llm";
```

## CLI Usage

The `fm-proxy` binary can also be used directly from the command line:

```bash
# Simple prompt
fm-proxy "What is the capital of France?"

# Streaming output
fm-proxy --stream "Tell me a story"
fm-proxy -s "Tell me a story"

# Start HTTP server
fm-proxy --serve
fm-proxy --serve --port=3000

# Other options
fm-proxy --help      # Show usage (or -h)
fm-proxy --version   # Show version (or -v)
fm-proxy --stdio     # LSP mode (used internally by npm package)
```

### HTTP Server Mode

Run `fm-proxy --serve` to start a local HTTP server:

```bash
fm-proxy --serve --port=8080
```

**Endpoints:**

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check and availability status |
| `/generate` | POST | Text generation |

**CORS:** All endpoints support CORS with `Access-Control-Allow-Origin: *`.

**Examples:**

```bash
# Health check
curl http://localhost:8080/health
# Response: {"status":"ok","model":"apple-on-device","available":true}

# Simple generation
curl -X POST http://localhost:8080/generate \
  -H "Content-Type: application/json" \
  -d '{"prompt": "What is 2+2?"}'
# Response: {"text":"2+2 equals 4."}
```

## How It Works

This package bundles a small native helper (`fm-proxy`) that communicates with Apple's Foundation Models framework over stdio. The helper is spawned on first request and stays alive to keep the model warm.

- **No localhost server** — npm package uses stdio, not HTTP
- **No user setup** — just `npm install`
- **Fails gracefully** — check `compatibility.check()` and fall back to cloud

## Runtime Support

**JS API (`createClient()`):**
| Environment | Supported |
|-------------|-----------|
| Node.js | ✅ |
| Electron (main process) | ✅ |
| VS Code extensions | ✅ |
| Electron (renderer) | ❌ No `child_process` |
| Browser | ❌ |

**HTTP Server (`fm-proxy --serve`):**
| Environment | Supported |
|-------------|-----------|
| Any HTTP client | ✅ |
| Browser (fetch) | ✅ |
| Electron (renderer) | ✅ |

## License

MIT
