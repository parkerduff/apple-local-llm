# Apple On-Device LLM Proxy (No Server)

A JavaScript library that lets you call Apple’s on-device Foundation Models using the OpenAI Responses API format.

It works by bundling a small native helper that runs locally on the same Mac and exposes Apple’s Foundation Models to JavaScript over stdio — no servers, no localhost, and no user setup.

When available, Apple's local models behave like a drop-in OpenAI client. When unavailable, the feature silently disables.

## Goal

Ship a drop-in, OpenAI Responses–compatible API for Node/Electron/VS Code that uses Apple's on-device Foundation Models, via a bundled native proxy over stdio.

**Primary goal: seamless integration into other apps.** The library should be invisible when it works and absent when it doesn't — never a source of friction.

- ✅ No localhost server
- ✅ No user setup
- ✅ Works invisibly when compatible
- ✅ Fails silently when not
- ✅ Distributed primarily via npm

npm description: Call Apple’s on-device LLMs from JavaScript using the OpenAI Responses API format — no servers, no setup.

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
  reason_code?: 
    | "NOT_DARWIN"           // Checked in JS, no spawn
    | "OS_TOO_OLD"           // Checked in JS, no spawn
    | "UNSUPPORTED_HARDWARE" // Checked in JS (non-ARM64), no spawn
    | "AI_DISABLED"          // Requires helper spawn (no model load)
    | "MODEL_NOT_READY"      // Requires helper spawn (no model load)
    | "SPAWN_FAILED"         // Helper couldn't execute
    | "PROTOCOL_MISMATCH"    // Helper ran but incompatible protocol version
    | "HELPER_UNHEALTHY";    // Helper hangs, violates framing, etc.
}
```

**Spawn behavior by reason code:**
- **NOT_DARWIN / UNSUPPORTED_HARDWARE**: Detected in JS layer via `process.platform`, `process.arch`. No helper spawn needed.
- **OS_TOO_OLD**: May be confirmed by helper during `capabilities.get` (without model load), or approximated in JS.
- **AI_DISABLED / MODEL_NOT_READY**: Requires spawning helper to call `SystemLanguageModel.default.availability`. Helper does NOT warm or load the model for these checks.
- **SPAWN_FAILED / PROTOCOL_MISMATCH / HELPER_UNHEALTHY**: Diagnosed during helper lifecycle.

**Rules:**
- Fast
- Cached aggressively (see below)
- Never loads model
- All other APIs auto-check unless explicitly bypassed

**Caching strategy:**
- **Positive result** (`compatible: true`): Cache indefinitely for session
- **Negative result** (`AI_DISABLED`, `MODEL_NOT_READY`): Cache for 5 minutes, don't re-spawn on every request
- **Fatal errors** (`SPAWN_FAILED`, `HELPER_UNHEALTHY`): Disable for session, only retry on explicit "Re-check compatibility" command

**PROTOCOL_MISMATCH handling:**
- On `PROTOCOL_MISMATCH`, treat it as possibly stale/cached helper (e.g., globalStorage copy)
- Mitigation:
  1. Purge any relocated/cached helper copy (e.g., delete `globalStorage/fm-proxy.app`)
  2. Re-resolve helper from packaged platform dependency
  3. Retry handshake once
- If mismatch persists after one retry:
  - Disable for session
  - Surface `PROTOCOL_MISMATCH` as the reason code
  - Next attempt only on explicit "Re-check compatibility"

---

### 1.3 Core API (MVP)

- `client.capabilities.get()`
- `client.responses.create({ input, max_output_tokens, stream? })`

### 1.4 v1 APIs

- `client.responses.stream()` → async iterator
- AbortSignal support
- `responses.cancel(id)`
- `response_format` (JSON / schema)
- `tools`
- `chat.completions.create()` adapter

---

## 2) Architecture (unchanged, hardened)

### 2.1 Components

1. **JS package** (`@org/apple-local-llm`)
   - binary resolution
   - process lifecycle manager
   - framed RPC client
   - OpenAI-compatible API
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

**Escape hatch:**
- Spawn-per-request mode
- Used automatically if:
  - helper crashes repeatedly
  - watchdog triggers
  - environment behaves oddly (enterprise Macs)

---

## 4) RPC protocol (safe by construction)

**Transport:**
- LSP framing (Content-Length)
- Single stdout writer
- Max frame size limits
- Per-request timeouts
- "No progress" streaming timeout

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

**Inference:**
- Enforce input size caps
- Streaming emits deltas + terminal event
- Cancellation is best-effort but always terminates stream

**Hang protection:**
- Per-request watchdog
- If exceeded → cancel task + return TIMEOUT

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

**Guarded call wrapper (critical):**

Every request passes through:
- compatibility check
- timeout enforcement
- structured error mapping
- fallback path

**Deterministic validation layer:**
- JSON schema validation
- Slug sanitization/scoring
- Retry once → fallback heuristic

This is what prevents "bad auto-renames" and broken UX.

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

### 7.1 Primary: npm

- Main package: `@org/apple-local-llm`
- Platform subpackages:
  - `@org/fm-proxy-darwin-arm64`

**No x64 support.** Foundation Models / Apple Intelligence only runs on Apple Silicon. Intel Macs return `UNSUPPORTED_HARDWARE` from the JS layer without spawning anything.

- Uses `optionalDependencies`
- Ships prebuilt, signed binaries
- No build-on-install

This is the canonical distribution.

---

### 7.2 GitHub Releases (trust + transparency)

- Signed helper binaries
- Checksums
- Release notes
- Reproducible build instructions

This builds confidence and supports audits.

---

### 7.3 VS Code Marketplace (reference extension)

A thin wrapper extension that:
- depends on npm package
- demonstrates real usage
- proves compatibility in the extension host
- provides discoverability

This is not the product — it's proof and marketing.

---

### 7.4 Optional: Vercel AI SDK adapter

Later, add:

```typescript
import { appleLocal } from "@org/apple-local-llm/vercel";
```

High leverage, low maintenance, optional.

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

### 8.3 Rate limits: CLI vs GUI apps ⚠️

**Observed behavior** (community reports; may be build-dependent):

Apple DTS Engineer ([source](https://developer.apple.com/forums/thread/787737)):
> "An app that has UI and runs in the foreground doesn't have a rate limit when using the models; a macOS command line tool, which doesn't have UI, does."

However, Apple's official `GenerationError.rateLimited` documentation states:
> "This error will only happen if your app is running in the background and exceeds the system defined rate limit."

And release notes suggest CLI rate limiting may have been a bug fixed in later macOS 26 builds.

**What we know:**
- Community reports: CLI tools hit rate limit after ~10 requests, blocking for 30+ minutes
- Apple docs: Rate limiting is tied to **background** execution, not CLI vs GUI per se
- **gety-ai/apple-on-device-openai** ships as GUI app explicitly to avoid this
- Behavior may vary across macOS 26 beta/release builds

**Unknowns:**
- Does `.app` bundle + `LSUIElement` count as "foreground UI"?
- Does spawning executable inside bundle register it properly with the system?
- Is VS Code (foreground) enough, or is the helper still "background"?

### 8.4 Candidate mitigation: Modular helper packaging

Ship the helper in a format that **may** avoid rate limits, but treat this as a mitigation to validate, not a guaranteed solution. Architecture is pluggable so we can swap approaches.

**Current approach: Invisible `.app` bundle**

Package the helper as an agent app with `LSUIElement: YES`:
```
fm-proxy.app/
└── Contents/
    ├── Info.plist          # LSUIElement: YES, CFBundleIdentifier
    ├── MacOS/
    │   └── fm-proxy        # The actual executable
    └── Resources/
```

Info.plist:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.org.fm-proxy</string>
    <key>CFBundleExecutable</key>
    <string>fm-proxy</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSBackgroundOnly</key>
    <false/>
</dict>
</plist>
```

`LSUIElement: YES` = agent app (no Dock icon, no Force Quit entry, but registers as GUI-capable).

**JS client: Modular resolver**

The binary resolution layer abstracts the packaging format:

```typescript
// src/resolver.ts
export interface HelperLocation {
  type: 'cli' | 'app-bundle';
  executablePath: string;
  appBundlePath?: string;  // Only for app-bundle type
}

export function resolveHelper(): HelperLocation {
  const platformPkg = require('@org/fm-proxy-darwin-arm64');
  
  // Check if we have an app bundle or bare CLI
  if (platformPkg.appBundlePath) {
    return {
      type: 'app-bundle',
      executablePath: path.join(platformPkg.appBundlePath, 'Contents/MacOS/fm-proxy'),
      appBundlePath: platformPkg.appBundlePath,
    };
  }
  
  // Fallback to bare CLI (future: if Apple removes rate limits)
  return {
    type: 'cli',
    executablePath: platformPkg.binaryPath,
  };
}
```

**Spawning strategy:**

```typescript
export type AppBundleLaunchMode = "direct-exec" | "launchservices-nonstdio";

export interface ClientOptions {
  // ... other options ...
  appBundleLaunchMode?: AppBundleLaunchMode; // default: "direct-exec"
}

// Note: "launchservices-nonstdio" is only implemented if we adopt XPC/socket transport;
// stdio transport is "direct-exec" only.

// src/spawn.ts
import { resolveHelper, HelperLocation } from './resolver';

export function spawnHelper(location: HelperLocation, opts: ClientOptions): ChildProcess {
  if (location.type === 'app-bundle') {
    if (opts.appBundleLaunchMode === 'launchservices-nonstdio') {
      // NOTE: LaunchServices (`open -a`) does not reliably provide stdio pipes to the launched app.
      // If we need LaunchServices to influence rate limiting behavior, we must switch transport for this mode
      // (e.g., XPC/Mach service or a unix domain socket), while keeping "no localhost server".
      throw new Error("launchservices-nonstdio mode requires non-stdio transport (TODO)");
    }
    
    // Default: direct exec of the bundle's executable (stdio works)
    // We attempt direct exec; if macOS still treats it as background/CLI,
    // we can switch to LaunchServices (open -a) as an alternative spawn mode.
    return spawn(location.executablePath, ['--stdio'], {
      stdio: ['pipe', 'pipe', 'pipe'],
    });
  }
  
  // Bare CLI fallback
  return spawn(location.executablePath, ['--stdio'], {
    stdio: ['pipe', 'pipe', 'pipe'],
  });
}
```

**Migration path:**

When Apple relaxes rate limits (or we confirm they don't apply to our use case):
1. Ship new version of `@org/fm-proxy-darwin-arm64` with bare CLI instead of `.app`
2. JS client automatically uses it via resolver
3. No changes needed in consuming apps

### 8.5 Rate limit handling in JS client (configurable policy)

Rate limiting behavior must be configurable, because acceptable UX differs by host environment.

**Configuration:**

```typescript
export type RateLimitPolicy = "fallback" | "retry" | "disable";

export interface ClientOptions {
  // Default: "fallback" (best for VS Code/Electron UX)
  rateLimitPolicy?: RateLimitPolicy;

  // Only used when policy is "retry" or "disable"
  maxConsecutiveRateLimits?: number; // default: 3
  disableForMs?: number;            // default: 30 * 60 * 1000
  maxRetryDelayMs?: number;         // default: 30_000
}
```

**Default behavior (recommended):**
- `rateLimitPolicy: "fallback"` → never block the calling request
- Immediately fall back to deterministic/cloud path and mark local provider disabled until a recheck window

**Rule:** The library must never delay/await on the caller's critical path unless `rateLimitPolicy: "retry"` is explicitly selected. With the default `"fallback"` policy, rate limiting triggers immediate fallback and a temporary disable window.

**Alternate behaviors:**
- `rateLimitPolicy: "retry"` → allow backoff/retry (useful for CLI tools or batch jobs)
- `rateLimitPolicy: "disable"` → disable local provider for a window after N consecutive rate limits

**Implementation:**

```typescript
interface RateLimitState {
  consecutive: number;
  disabledUntil: number | null;
  backoffMs: number;
}

const state: RateLimitState = { consecutive: 0, disabledUntil: null, backoffMs: 1000 };

export function isRateLimitDisabled(): boolean {
  return state.disabledUntil !== null && Date.now() < state.disabledUntil;
}

export async function onRateLimited(opts: ClientOptions): Promise<"fallback" | "retry" | "disabled"> {
  const policy = opts.rateLimitPolicy ?? "fallback";
  const maxN = opts.maxConsecutiveRateLimits ?? 3;
  const disableForMs = opts.disableForMs ?? 30 * 60 * 1000;
  const maxDelay = opts.maxRetryDelayMs ?? 30_000;

  state.consecutive++;

  // Always allow disabling after repeated rate limits
  if (state.consecutive >= maxN) {
    state.disabledUntil = Date.now() + disableForMs;
    return "disabled";
  }

  if (policy === "fallback") {
    // UX-first: do not block this request
    state.disabledUntil = Date.now() + Math.min(60_000, disableForMs); // short cooldown
    return "fallback";
  }

  if (policy === "disable") {
    state.disabledUntil = Date.now() + disableForMs;
    return "disabled";
  }

  // policy === "retry"
  const jitter = Math.random() * 500;
  const delay = Math.min(state.backoffMs + jitter, maxDelay);
  state.backoffMs = Math.min(state.backoffMs * 2, maxDelay);
  await sleep(delay);
  return "retry";
}

export function onSuccessfulResponse(): void {
  state.consecutive = 0;
  state.backoffMs = 1000;
  state.disabledUntil = null;
}
```

### 8.6 Validation test plan

Needs testing on macOS 26 release:
- Does `LSUIElement` app avoid rate limits?
- Does spawning executable inside `.app` bundle register it properly?
- Do we need `open -a` instead of direct spawn?
- Does in-process FFI (Meridius-style) avoid rate limits?

Test:
```bash
# Build as .app bundle with LSUIElement: YES
# Run 20+ requests in quick succession
# Compare to bare CLI behavior
# Test with VS Code as foreground vs background
```

If `.app` bundle doesn't work, fallback options:
- Switch to in-process FFI (Rust NAPI like Meridius)
- Accept rate limits with graceful degradation

**Transport decision (if LaunchServices required):**
- If LaunchServices is required to avoid rate limiting, validate whether stdio is viable with `open -a`
- If not (likely), choose between:
  - XPC/Mach service (preferred, native, no ports)
  - Unix domain socket in temp dir (simpler, cross-platform pattern)
- Either option preserves "no localhost server" constraint

### 8.7 Prior art

**Existing projects confirm Foundation Models works from npm-distributed binaries** (no App Store, no special entitlements):

- **@meridius-labs/apple-on-device-ai** — Swift dylib + Rust N-API, in-process FFI, Vercel AI SDK compatible
- **scouzi1966/maclocal-api** — Standalone Swift CLI via Homebrew tap

Key validation:
- ✅ Bare Mach-O executable works functionally
- ✅ No special entitlements needed
- ⚠️ Rate limits observed in CLI tools; `.app` bundle is candidate mitigation

---

## Next steps

- Lock the exact Responses event subset for v1
- Design the public README
- Sketch the repo + package.json layout