# Apple On-Device LLM Proxy (No Server)

A JavaScript library that lets you call Apple's on-device Foundation Models from JavaScript.

It works by bundling a small native helper that runs locally on the same Mac and exposes Apple’s Foundation Models to JavaScript over stdio — no servers, no localhost, and no user setup.

When available, Apple's local models are accessible via a simple API. When unavailable, the feature silently disables.

## Goal

Ship a simple API for Node/Electron/VS Code that uses Apple's on-device Foundation Models, via a bundled native proxy over stdio.

**Primary goal: seamless integration into other apps.** The library should be invisible when it works and absent when it doesn't — never a source of friction.

- ✅ No localhost server
- ✅ No user setup
- ✅ Works invisibly when compatible
- ✅ Fails silently when not
- ✅ Distributed primarily via npm

npm description: Call Apple's on-device Foundation Models — no servers, no setup.

---

## 1) Public API (with safety baked in)

### 1.1 Entry points

```typescript
const client = createClient();
```

### 1.2 Compatibility gate (first-class)

```typescript
const compat = await client.compatibility.check();
```

Returns:

```typescript
{
  compatible: boolean;
  reasonCode?: 
    | "NOT_DARWIN"           // Checked in JS, no spawn
    | "UNSUPPORTED_HARDWARE" // Checked in JS (non-ARM64), no spawn
    | "HELPER_NOT_FOUND"     // Binary not found at expected path
    | "AI_DISABLED"          // Requires helper spawn (no model load)
    | "MODEL_NOT_READY"      // Requires helper spawn (no model load)
    | "SPAWN_FAILED"         // Helper couldn't execute
    | "PROTOCOL_MISMATCH"    // Helper ran but incompatible protocol version
    | "HELPER_UNHEALTHY";    // Helper hangs, violates framing, etc.
}
```

**Spawn behavior by reason code:**
- **NOT_DARWIN / UNSUPPORTED_HARDWARE / HELPER_NOT_FOUND**: Detected in JS layer. No helper spawn needed.
- **AI_DISABLED / MODEL_NOT_READY**: Requires spawning helper to call `SystemLanguageModel.default.availability`. Helper does NOT warm or load the model for these checks.
- **SPAWN_FAILED / PROTOCOL_MISMATCH / HELPER_UNHEALTHY**: Diagnosed during helper lifecycle.

**Rules:**
- Fast
- Cached aggressively (see below)
- Never loads model
- All other APIs auto-check unless explicitly bypassed

**Caching strategy:**
- Results cached indefinitely for session (positive or negative)
- Call `compatibility.check()` again to refresh

---

### 1.3 Core API (MVP)

- `client.capabilities.get()`
- `client.responses.create({ input, max_output_tokens, stream? })`

### 1.4 Additional APIs (implemented)

- `client.stream()` → async iterator ✅
- AbortSignal support ✅
- `responses.cancel(id)` ✅

### 1.5 Future APIs (not implemented)

- `response_format` (JSON / schema) — requires Swift macro changes
- `tools` — requires Swift macro changes

---

## 2) Architecture (unchanged, hardened)

### 2.1 Components

1. **JS package** (`@org/apple-local-llm`)
   - binary resolution
   - process lifecycle manager
   - framed RPC client
   - Simple responses API
   - deterministic validation + fallback

2. **Native helper** (`fm-proxy`, Swift)
   - Foundation Models calls
   - LSP-style stdio RPC
   - streaming + cancellation
   - strict stdout framing
   - stderr logging only

### 2.2 Runtime requirement

This library requires a Node.js context that can spawn child processes:
- ✅ Node.js CLI
- ✅ Electron main process
- ✅ VS Code extension host
- ❌ Electron renderer with contextIsolation (no child_process)
- ❌ Browser

---

## 3) Process model (with failure containment)

**Default:**
- Persistent child process
- Spawn on first eligible request
- Idle timeout (5–10 min)
- Model stays warm if possible

**Crash recovery:**
- Exponential backoff on crash (100ms → 5s max)
- Max 3 restart attempts before giving up
- Backoff resets on successful handshake

---

## 4) RPC protocol (safe by construction)

**Transport:**
- LSP framing (Content-Length)
- Single stdout writer (synchronized with NSLock)
- Per-request timeouts (60s default, 120s for streaming)
- Streaming timeout resets on each delta received

**Required methods:**
- `health.ping` → returns `{ ok: true, protocol_version: 1 }`
- `capabilities.get`
- `responses.create`
- `responses.cancel`
- `process.shutdown`

**Protocol versioning:**
- `health.ping` returns `protocol_version`
- JS client checks version on handshake
- Mismatch → kill helper, return `PROTOCOL_MISMATCH`

**Diagnostic error codes** (for debugging/telemetry):
- **SPAWN_FAILED**: Helper binary couldn't execute (missing, permissions, Gatekeeper, etc.)
- **PROTOCOL_MISMATCH**: Helper executed but returned incompatible protocol version
- **HELPER_UNHEALTHY**: Helper hangs, violates framing, crashes repeatedly, watchdog triggered

**Error model** (never throw):

```json
{
  "ok": false,
  "error": {
    "code": "UNAVAILABLE | TIMEOUT | CANCELLED | INTERNAL",
    "detail": "…"
  }
}
```

---

## 5) Native helper mitigations (Swift)

**Availability:**
- `capabilities.get`:
  - checks OS / hardware / Apple Intelligence enabled
  - never loads model
  - returns reason codes

**Mapping `SystemLanguageModel.Availability` to reason codes:**
```swift
switch SystemLanguageModel.default.availability {
case .available:
    // compatible: true
case .unavailable(.appleIntelligenceNotEnabled):
    // AI_DISABLED
case .unavailable(.deviceNotEligible):
    // UNSUPPORTED_HARDWARE (backup; JS should catch this first)
case .unavailable(.modelNotReady):
    // MODEL_NOT_READY
case .unavailable(_):
    // AI_DISABLED (unknown unavailable reason)
}
```

**Inference:**
- Streaming emits deltas + terminal event (`done` or `error`)
- Cancellation is best-effort but always terminates stream
- Concurrent requests supported via Swift actor + request ID tracking

**Logging:**
- stderr only
- off by default
- no user text unless debug enabled

---

## 6) JS client mitigations

**Helper lifecycle manager:**
- Spawn → handshake → cache compatibility
- Restart on crash (with backoff)
- Kill + fallback if unhealthy

**Guarded call wrapper:**

Every request passes through:
- Compatibility check (auto-runs on first request)
- Timeout enforcement (configurable per-request)
- Structured error mapping (never throws, returns `{ ok: false, error }`)

### 6.1 Binary path & execution mitigations (VS Code specific)

VS Code extensions can have path/permission issues when bundled or installed. Required mitigations:

**Executable permissions:**
- Verify `chmod +x` on helper binary at first use
- If missing, attempt to set it (may fail in read-only contexts)
- Log clear error if permissions can't be fixed

**Path resolution:**
- Use `require.resolve()` to find platform package
- Handle both bundled (extension directory) and installed (`node_modules`) cases
- Resolve symlinks to get actual binary path

**Fallback: copy to globalStorage (returns HelperLocation):**
```typescript
// If executing in-place fails (permissions, path issues)
const globalStoragePath = context.globalStorageUri.fsPath;
const appBundlePath = path.join(globalStoragePath, "fm-proxy.app");
const executablePath = path.join(appBundlePath, "Contents/MacOS/fm-proxy");

export async function ensureExecutableHelper(bundledAppBundlePath: string): Promise<HelperLocation> {
  if (await canExecuteInPlace(bundledAppBundlePath)) {
    return {
      type: "app-bundle",
      appBundlePath: bundledAppBundlePath,
      executablePath: path.join(bundledAppBundlePath, "Contents/MacOS/fm-proxy"),
    };
  }

  // Copy the entire .app bundle without modifying contents post-signing
  await fs.cp(bundledAppBundlePath, appBundlePath, { recursive: true });

  // Ensure exec bit; do not rewrite any files inside the bundle
  await fs.chmod(executablePath, 0o755);

  return { type: "app-bundle", appBundlePath, executablePath };
}
```

**Bundle immutability (critical for code signing):**
- Treat the helper `.app` bundle as **immutable** after signing
- Never patch Info.plist, add files, or modify contents post-install
- Copy the bundle without modifying its contents post-signing
- `chmod` on executable is safe (doesn't modify file contents)
- Modifying bundle contents invalidates signature → Gatekeeper blocks

**Note:** `fs.cp` may not preserve extended attributes (xattrs); we avoid relying on xattrs for execution. The bundle must remain unmodified in contents to preserve code signature validity.

**Common failure modes to handle:**
- Extension installed in read-only location
- Path contains spaces or special characters
- Binary stripped of execute bit during packaging
- Symlink resolution fails

---

## 7) Distribution plan (new, explicit)

### 7.1 Primary: npm ✅ Done

- Single package: `apple-local-llm`
- Binary bundled in `bin/fm-proxy`

**No x64 support.** Foundation Models / Apple Intelligence only runs on Apple Silicon. Intel Macs return `UNSUPPORTED_HARDWARE` from the JS layer without spawning anything.

- Ships prebuilt binary
- No build-on-install

This is the canonical distribution.

---

### 7.2 Future: GitHub Releases, VS Code Extension, Vercel Adapter

Optional future work — not needed for MVP.

---

## 8) Entitlements, Gatekeeper & macOS blocking risks

### 8.1 Sandbox inheritance

Child processes generally inherit the parent's sandbox. Per Apple DTS:
> "If you're not shipping on the Mac App Store you can leave off both of these entitlements and the helper process will inherit its parent's sandbox just fine."

**Notes:**
- The `com.apple.security.inherit` entitlement is primarily an App Review marker for MAS submissions
- VS Code and most Electron apps are **not** sandboxed in the App Sandbox sense, so this is less relevant for our primary use case
- No special entitlements required for the helper binary when distributed outside the Mac App Store

### 8.2 Gatekeeper & quarantine

**Problem:** Files downloaded via browser/curl get `com.apple.quarantine` extended attribute. Gatekeeper blocks unsigned/un-notarized executables with this flag.

**npm behavior:** `npm install` typically does not set the quarantine attribute (Node's HTTP client doesn't participate in Launch Services quarantine). However, **do not rely on this** — edge cases exist (corporate proxies, alternative package managers, manual downloads).

**Required mitigation:** Sign and notarize the helper binary with Developer ID. This is not optional:
- Ensures execution regardless of how the binary was obtained
- No Gatekeeper prompts or "unidentified developer" dialogs
- Required for transparency and security audits
- Future macOS versions may tighten enforcement

Build process:
```bash
# Sign with Developer ID
codesign --sign "Developer ID Application: Your Name" --options runtime fm-proxy

# Notarize
xcrun notarytool submit fm-proxy.zip --apple-id ... --wait

# Staple ticket (optional, for offline verification)
xcrun stapler staple fm-proxy
```

### 8.3 Rate limits

**Tested on macOS 26.1:** No rate limiting observed with bare CLI (50 concurrent requests). Ship as simple CLI executable.

Early macOS 26 betas had CLI rate limits, but this appears fixed in 26.1. If Apple reintroduces limits, we can revisit `.app` bundle packaging.

### 8.4 Prior art

**Existing projects confirm Foundation Models works from npm-distributed binaries** (no App Store, no special entitlements):

- **@meridius-labs/apple-on-device-ai** — Swift dylib + Rust N-API, in-process FFI

Validation:
- ✅ Bare Mach-O executable works
- ✅ No special entitlements needed
- ✅ No rate limits on macOS 26.1

---

## Status

### Implemented ✅

- Swift CLI helper with LSP-style stdio RPC
- JS client with process lifecycle management
- Streaming with async iterator
- AbortSignal support
- Request cancellation
- Crash recovery with exponential backoff
- Idle timeout (5 min default)
- Protocol versioning
- Concurrent request support

### Future (v2)

- `response_format` — structured JSON output via `DynamicGenerationSchema`
- `tools` — function calling (requires investigation of dynamic tool support)
- Token counting API (not exposed by Apple)

---

## Publishing

```bash
# Build and copy binary
npm run build:swift
cp swift/.build/release/fm-proxy bin/

# Publish
npm publish
```

Test from a fresh directory:
```bash
npm install apple-local-llm
npx fm-proxy "test"
```

If Gatekeeper blocks, sign with Developer ID and publish patch version. Should work since Node spawns it (inherited trust from npm install).

### Optional

- **Code signing** — only needed if Gatekeeper blocks unsigned binary
- **GitHub Release** — for transparency only, npm is the distribution

**MVP Complete.** Ready to publish.