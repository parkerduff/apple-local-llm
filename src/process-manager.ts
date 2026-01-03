import { spawn, ChildProcess } from "child_process";
import { RPCTransport } from "./transport";
import { HelperLocation, ensureExecutable } from "./resolver";

export interface ProcessManagerOptions {
  idleTimeoutMs?: number;
  maxRestarts?: number;
  onLog?: (message: string) => void;
}

const DEFAULT_IDLE_TIMEOUT = 5 * 60 * 1000; // 5 minutes
const DEFAULT_MAX_RESTARTS = 3;
const PROTOCOL_VERSION = 1;
const INITIAL_BACKOFF_MS = 100;
const MAX_BACKOFF_MS = 5000;

export class ProcessManager {
  private location: HelperLocation;
  private options: ProcessManagerOptions;
  private process: ChildProcess | null = null;
  private transport: RPCTransport | null = null;
  private idleTimer: NodeJS.Timeout | null = null;
  private restartCount = 0;
  private healthy = false;
  private backoffMs = INITIAL_BACKOFF_MS;

  constructor(location: HelperLocation, options: ProcessManagerOptions = {}) {
    this.location = location;
    this.options = options;
  }

  async getTransport(): Promise<RPCTransport> {
    this.resetIdleTimer();

    if (this.transport && this.healthy) {
      return this.transport;
    }

    // Check if we need to wait (backoff after crash)
    const maxRestarts = this.options.maxRestarts ?? DEFAULT_MAX_RESTARTS;
    if (this.restartCount >= maxRestarts) {
      throw new Error(`Helper crashed ${this.restartCount} times, giving up`);
    }

    if (this.restartCount > 0) {
      this.options.onLog?.(`Restarting helper (attempt ${this.restartCount + 1}/${maxRestarts}) after ${this.backoffMs}ms`);
      await this.sleep(this.backoffMs);
      this.backoffMs = Math.min(this.backoffMs * 2, MAX_BACKOFF_MS);
    }

    return this.spawn();
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  private async spawn(): Promise<RPCTransport> {
    await ensureExecutable(this.location);

    this.process = spawn(this.location.executablePath, ["--stdio"], {
      stdio: ["pipe", "pipe", "pipe"],
    });

    this.transport = new RPCTransport(this.process);

    this.transport.on("log", (msg: string) => {
      this.options.onLog?.(msg);
    });

    this.transport.on("exit", (code: number | null) => {
      this.healthy = false;
      this.transport = null;
      this.process = null;
      if (code !== 0) {
        this.restartCount++;
        this.options.onLog?.(`Helper exited with code ${code}, crash count: ${this.restartCount}`);
      }
    });

    this.transport.on("error", (err: Error) => {
      this.options.onLog?.(`Transport error: ${err.message}`);
      this.healthy = false;
    });

    // Handshake
    let pingResponse;
    try {
      pingResponse = await this.transport.send("health.ping");
    } catch (err) {
      this.kill();
      throw err;
    }

    if (!pingResponse.ok) {
      this.kill();
      throw new Error("Handshake failed: health.ping returned error");
    }

    const result = pingResponse.result as { protocol_version?: number };
    if (result.protocol_version !== PROTOCOL_VERSION) {
      this.kill();
      throw new Error(
        `Protocol mismatch: expected ${PROTOCOL_VERSION}, got ${result.protocol_version}`
      );
    }

    this.healthy = true;
    this.restartCount = 0;
    this.backoffMs = INITIAL_BACKOFF_MS; // Reset backoff on success
    return this.transport;
  }

  private resetIdleTimer(): void {
    if (this.idleTimer) {
      clearTimeout(this.idleTimer);
    }

    const timeout = this.options.idleTimeoutMs ?? DEFAULT_IDLE_TIMEOUT;
    this.idleTimer = setTimeout(() => {
      this.shutdown();
    }, timeout);
  }

  async shutdown(): Promise<void> {
    if (this.idleTimer) {
      clearTimeout(this.idleTimer);
      this.idleTimer = null;
    }

    if (this.transport && this.healthy) {
      try {
        await this.transport.send("process.shutdown");
      } catch {
        // Ignore errors during shutdown
      }
    }

    this.kill();
  }

  private kill(): void {
    if (this.process) {
      this.process.kill();
      this.process = null;
    }
    this.transport = null;
    this.healthy = false;
  }

  isHealthy(): boolean {
    return this.healthy;
  }
}
