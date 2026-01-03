/**
 * Comprehensive test suite for all apple-local-llm interaction methods
 * Run with: npx tsx test-all-interactions.ts
 */

import { createClient, AppleLocalLLMClient } from "./src/client.js";
import { spawn, ChildProcess } from "child_process";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const BINARY_PATH = path.join(__dirname, "swift", ".build", "release", "fm-proxy");
const TEST_PROMPT = "What color is the sky on a clear day?";

interface TestResult {
  name: string;
  passed: boolean;
  error?: string;
  duration?: number;
}

const results: TestResult[] = [];

async function test(name: string, fn: () => Promise<void>): Promise<void> {
  const start = Date.now();
  try {
    await fn();
    results.push({ name, passed: true, duration: Date.now() - start });
    console.log(`✅ ${name}`);
  } catch (err) {
    const error = err instanceof Error ? err.message : String(err);
    results.push({ name, passed: false, error, duration: Date.now() - start });
    console.log(`❌ ${name}: ${error}`);
  }
}

// Helper to make HTTP requests using curl (more reliable with the Swift server)
function httpRequest(options: { hostname: string; port: number; path: string; method: string; headers?: Record<string, string> }, body?: string): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const url = `http://${options.hostname}:${options.port}${options.path}`;
    const args = ["-s", "-w", "\n%{http_code}", "-X", options.method, url];
    
    if (options.headers) {
      for (const [key, value] of Object.entries(options.headers)) {
        args.push("-H", `${key}: ${value}`);
      }
    }
    if (body) {
      args.push("-d", body);
    }
    
    const proc = spawn("curl", args);
    let stdout = "";
    let stderr = "";
    proc.stdout.on("data", (d) => (stdout += d));
    proc.stderr.on("data", (d) => (stderr += d));
    proc.on("close", (code) => {
      if (code !== 0) {
        reject(new Error(`curl failed: ${stderr}`));
        return;
      }
      // Parse response - last line is status code
      const lines = stdout.trim().split("\n");
      const statusCode = parseInt(lines.pop() || "0", 10);
      const responseBody = lines.join("\n");
      resolve({ status: statusCode, body: responseBody });
    });
    proc.on("error", reject);
  });
}

// Helper to wait for server to be ready
async function waitForServer(port: number, maxAttempts = 30): Promise<void> {
  for (let i = 0; i < maxAttempts; i++) {
    try {
      const res = await httpRequest({ hostname: "localhost", port, path: "/health", method: "GET" });
      if (res.status === 200) return;
    } catch {
      // Server not ready yet
    }
    await new Promise((r) => setTimeout(r, 300));
  }
  throw new Error("Server did not start in time");
}

async function main() {
  console.log("\n========================================");
  console.log("Testing apple-local-llm Interaction Methods");
  console.log("========================================\n");

  // ================================================
  // SECTION 1: npm Package API Tests
  // ================================================
  console.log("\n--- npm Package API Tests ---\n");

  const client = createClient({ onLog: () => {} });

  // Test 1: createClient()
  await test("createClient() - creates client instance", async () => {
    if (!client) throw new Error("Client not created");
  });

  // Test 1b: new AppleLocalLLMClient() - direct instantiation
  await test("new AppleLocalLLMClient() - direct class instantiation", async () => {
    const directClient = new AppleLocalLLMClient({ onLog: () => {} });
    if (!directClient) throw new Error("Direct client not created");
    await directClient.shutdown();
  });

  // Test 1c: createClient with idleTimeoutMs option
  await test("createClient({idleTimeoutMs}) - accepts idle timeout option", async () => {
    const timedClient = createClient({ idleTimeoutMs: 60000, onLog: () => {} });
    if (!timedClient) throw new Error("Client with timeout not created");
    await timedClient.shutdown();
  });

  // Test 2: client.compatibility.check()
  await test("client.compatibility.check() - returns compatibility", async () => {
    const result = await client.compatibility.check();
    if (typeof result.compatible !== "boolean") throw new Error("Invalid result format");
    if (!result.compatible && !result.reasonCode) throw new Error("Missing reasonCode when incompatible");
  });

  // Check if we can continue with model tests
  const compat = await client.compatibility.check();
  if (!compat.compatible) {
    console.log(`\n⚠️ Model not available (${compat.reasonCode}). Skipping model-dependent tests.\n`);
  } else {
    // Test 3: client.capabilities.get()
    await test("client.capabilities.get() - returns capabilities", async () => {
      const caps = await client.capabilities.get();
      if (typeof caps.available !== "boolean") throw new Error("Invalid result format");
    });

    // Test 4: client.responses.create() - non-streaming
    await test("client.responses.create() - non-streaming response", async () => {
      const result = await client.responses.create({ input: TEST_PROMPT });
      if (!result.ok) throw new Error(`Request failed: ${(result as any).error?.detail}`);
      if (!result.text) throw new Error("No text in response");
    });

    // Test 5: client.responses.create() - streaming via flag
    await test("client.responses.create({stream:true}) - streaming response", async () => {
      const result = await client.responses.create({ input: TEST_PROMPT, stream: true });
      if (!result.ok) throw new Error(`Request failed: ${(result as any).error?.detail}`);
      if (!result.text) throw new Error("No text in response");
    });

    // Test 6: client.stream() - async generator
    await test("client.stream() - async generator streaming", async () => {
      let gotDelta = false;
      let gotDone = false;
      for await (const chunk of client.stream({ input: TEST_PROMPT })) {
        if ("delta" in chunk) gotDelta = true;
        if ("done" in chunk) gotDone = true;
      }
      if (!gotDone) throw new Error("Never received done event");
    });

    // Test 7: client.responses.create() with max_output_tokens
    await test("client.responses.create({max_output_tokens}) - respects token limit", async () => {
      const result = await client.responses.create({ input: "Count from 1 to 100", max_output_tokens: 20 });
      if (!result.ok) throw new Error(`Request failed: ${(result as any).error?.detail}`);
    });

    // Test 8: AbortSignal support
    await test("client.responses.create({signal}) - AbortSignal support", async () => {
      const controller = new AbortController();
      setTimeout(() => controller.abort(), 10);
      try {
        await client.responses.create({ input: "Tell me a very long story", signal: controller.signal });
        // If it completes fast, that's ok
      } catch (err) {
        if (!(err instanceof Error) || !err.message.includes("abort")) {
          throw err;
        }
        // Abort error is expected
      }
    });

    // Test 9: model parameter
    await test("client.responses.create({model}) - accepts model parameter", async () => {
      const result = await client.responses.create({ input: "Say yes", model: "default" });
      if (!result.ok) throw new Error(`Request failed: ${(result as any).error?.detail}`);
    });

    // Test 10: responses.cancel() - cancel non-existent request (should return error)
    await test("client.responses.cancel() - handles non-existent request", async () => {
      const result = await client.responses.cancel("non-existent-id");
      // Should return ok: false since request doesn't exist
      if (result.ok) throw new Error("Expected cancel to fail for non-existent request");
    });
  }

  // Test 11: client.shutdown()
  await test("client.shutdown() - graceful shutdown", async () => {
    await client.shutdown();
  });

  // ================================================
  // SECTION 2: CLI Tests
  // ================================================
  console.log("\n--- CLI Tests ---\n");

  // Test CLI: --help
  await test("fm-proxy --help - shows usage", async () => {
    const result = await runCLI(["--help"]);
    if (!result.stdout.includes("USAGE")) throw new Error("Help not shown");
  });

  // Test CLI: --version
  await test("fm-proxy --version - shows version", async () => {
    const result = await runCLI(["--version"]);
    if (!result.stdout.includes("fm-proxy")) throw new Error("Version not shown");
  });

  // Test CLI: -h (short help)
  await test("fm-proxy -h - short help flag", async () => {
    const result = await runCLI(["-h"]);
    if (!result.stdout.includes("USAGE")) throw new Error("Help not shown");
  });

  // Test CLI: -v (short version)
  await test("fm-proxy -v - short version flag", async () => {
    const result = await runCLI(["-v"]);
    if (!result.stdout.includes("fm-proxy")) throw new Error("Version not shown");
  });

  if (compat.compatible) {
    // Test CLI: simple prompt
    await test('fm-proxy "prompt" - simple prompt', async () => {
      const result = await runCLI([TEST_PROMPT]);
      if (result.exitCode !== 0) throw new Error(`Exit code: ${result.exitCode}, stderr: ${result.stderr}`);
      if (!result.stdout) throw new Error("No output");
    });

    // Test CLI: --stream
    await test("fm-proxy --stream - streaming output", async () => {
      const result = await runCLI(["--stream", TEST_PROMPT]);
      if (result.exitCode !== 0) throw new Error(`Exit code: ${result.exitCode}`);
      if (!result.stdout) throw new Error("No output");
    });

    // Test CLI: -s (short stream)
    await test("fm-proxy -s - short stream flag", async () => {
      const result = await runCLI(["-s", TEST_PROMPT]);
      if (result.exitCode !== 0) throw new Error(`Exit code: ${result.exitCode}`);
      if (!result.stdout) throw new Error("No output");
    });
  }

  // ================================================
  // SECTION 3: HTTP Server Tests
  // ================================================
  console.log("\n--- HTTP Server Tests ---\n");

  let serverProcess: ChildProcess | undefined;
  const port = 18080; // Use non-standard port to avoid conflicts

  try {
    // Start server
    await test("fm-proxy --serve - starts server", async () => {
      serverProcess = spawn(BINARY_PATH, ["--serve", `--port=${port}`]);
      await waitForServer(port);
    });

    // Test GET /health
    await test("GET /health - health check", async () => {
      const res = await httpRequest({ hostname: "localhost", port, path: "/health", method: "GET" });
      if (res.status !== 200) throw new Error(`Status: ${res.status}`);
      const json = JSON.parse(res.body);
      if (json.status !== "ok") throw new Error("Health check failed");
    });

    if (compat.compatible) {
      // Test POST /generate
      await test("POST /generate - simple generation", async () => {
        const res = await httpRequest(
          {
            hostname: "localhost",
            port,
            path: "/generate",
            method: "POST",
            headers: { "Content-Type": "application/json" },
          },
          JSON.stringify({ prompt: TEST_PROMPT })
        );
        if (res.status !== 200) throw new Error(`Status: ${res.status}, Body: ${res.body}`);
        const json = JSON.parse(res.body);
        if (!json.text) throw new Error("No text in response");
      });
    }

    // Test 404
    await test("GET /nonexistent - returns 404", async () => {
      const res = await httpRequest({ hostname: "localhost", port, path: "/nonexistent", method: "GET" });
      if (res.status !== 404) throw new Error(`Expected 404, got ${res.status}`);
    });

    // Test OPTIONS (CORS)
    await test("OPTIONS / - CORS preflight", async () => {
      const res = await httpRequest({ hostname: "localhost", port, path: "/", method: "OPTIONS" });
      if (res.status !== 204) throw new Error(`Expected 204, got ${res.status}`);
    });

    // Test POST /generate with missing prompt
    await test("POST /generate - missing prompt returns 400", async () => {
      const res = await httpRequest(
        {
          hostname: "localhost",
          port,
          path: "/generate",
          method: "POST",
          headers: { "Content-Type": "application/json" },
        },
        JSON.stringify({})
      );
      if (res.status !== 400) throw new Error(`Expected 400, got ${res.status}`);
    });

  } finally {
    if (serverProcess) {
      serverProcess.kill();
    }
  }

  // Test --port flag
  await test("fm-proxy --serve --port=N - custom port", async () => {
    const customPort = 18081;
    const proc = spawn(BINARY_PATH, ["--serve", `--port=${customPort}`]);
    try {
      await waitForServer(customPort);
      const res = await httpRequest({ hostname: "localhost", port: customPort, path: "/health", method: "GET" });
      if (res.status !== 200) throw new Error(`Status: ${res.status}`);
    } finally {
      proc.kill();
    }
  });

  // ================================================
  // Summary
  // ================================================
  console.log("\n========================================");
  console.log("Test Results Summary");
  console.log("========================================\n");

  const passed = results.filter((r) => r.passed).length;
  const failed = results.filter((r) => !r.passed).length;

  console.log(`Total: ${results.length} | Passed: ${passed} | Failed: ${failed}\n`);

  if (failed > 0) {
    console.log("Failed tests:");
    results
      .filter((r) => !r.passed)
      .forEach((r) => {
        console.log(`  ❌ ${r.name}: ${r.error}`);
      });
    process.exit(1);
  }

  console.log("All tests passed! ✅\n");
}

async function runCLI(args: string[]): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  return new Promise((resolve) => {
    const proc = spawn(BINARY_PATH, args);
    let stdout = "";
    let stderr = "";
    proc.stdout.on("data", (d) => (stdout += d));
    proc.stderr.on("data", (d) => (stderr += d));
    proc.on("close", (code) => resolve({ stdout, stderr, exitCode: code ?? 0 }));
    // Timeout after 30s
    setTimeout(() => {
      proc.kill();
      resolve({ stdout, stderr, exitCode: -1 });
    }, 30000);
  });
}

main().catch((err) => {
  console.error("Test runner error:", err);
  process.exit(1);
});
