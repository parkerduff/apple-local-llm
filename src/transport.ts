import { ChildProcess } from "child_process";
import { EventEmitter } from "events";

export interface RPCRequest {
  id?: string;
  method: string;
  params?: unknown;
}

export interface SendOptions {
  timeoutMs?: number;
  signal?: AbortSignal;
}

const DEFAULT_TIMEOUT_MS = 60_000; // 60 seconds

export interface RPCResponse {
  id?: string | null;
  ok: boolean;
  result?: unknown;
  error?: {
    code: string;
    detail: string;
  };
}

export class RPCTransport extends EventEmitter {
  private process: ChildProcess;
  private buffer = Buffer.alloc(0);
  private contentLength: number | null = null;
  private requestId = 0;
  private pending = new Map<string, {
    resolve: (response: RPCResponse) => void;
    reject: (error: Error) => void;
  }>();

  constructor(proc: ChildProcess) {
    super();
    this.process = proc;

    proc.stdout?.on("data", (chunk: Buffer) => {
      this.onData(chunk);
    });

    proc.stderr?.on("data", (chunk: Buffer) => {
      this.emit("log", chunk.toString());
    });

    proc.on("exit", (code) => {
      this.emit("exit", code);
      for (const [, { reject }] of this.pending) {
        reject(new Error(`Helper process exited with code ${code}`));
      }
      this.pending.clear();
    });

    proc.on("error", (err) => {
      this.emit("error", err);
    });
  }

  private onData(data: Buffer): void {
    this.buffer = Buffer.concat([this.buffer, data]);
    this.processBuffer();
  }

  private processBuffer(): void {
    while (true) {
      if (this.contentLength === null) {
        const headerEndMarker = Buffer.from("\r\n\r\n");
        const headerEnd = this.buffer.indexOf(headerEndMarker);
        if (headerEnd === -1) return;

        const header = this.buffer.subarray(0, headerEnd).toString("utf8");
        const match = header.match(/Content-Length:\s*(\d+)/i);
        if (!match) {
          this.emit("error", new Error("Invalid LSP header"));
          return;
        }

        this.contentLength = parseInt(match[1], 10);
        this.buffer = this.buffer.subarray(headerEnd + 4);
      }

      if (this.buffer.length < this.contentLength) return;

      const body = this.buffer.subarray(0, this.contentLength).toString("utf8");
      this.buffer = this.buffer.subarray(this.contentLength);
      this.contentLength = null;

      try {
        const response: RPCResponse = JSON.parse(body);
        this.handleResponse(response);
      } catch (err) {
        this.emit("error", new Error(`Invalid JSON response: ${body}`));
      }
    }
  }

  private handleResponse(response: RPCResponse): void {
    // Always emit as event first (for streaming handlers)
    this.emit("event", response);
    
    // Then resolve pending promise if this is a direct response
    if (response.id && this.pending.has(response.id)) {
      const { resolve } = this.pending.get(response.id)!;
      this.pending.delete(response.id);
      resolve(response);
    }
  }

  async send(method: string, params?: unknown, options: SendOptions = {}): Promise<RPCResponse> {
    const id = `req_${++this.requestId}`;
    const request: RPCRequest = { id, method, params };
    const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;

    return new Promise((resolve, reject) => {
      let timer: NodeJS.Timeout | null = null;
      let aborted = false;

      const cleanup = () => {
        if (timer) clearTimeout(timer);
        this.pending.delete(id);
      };

      // Timeout handling
      timer = setTimeout(() => {
        cleanup();
        reject(new Error(`Request timeout after ${timeoutMs}ms`));
      }, timeoutMs);

      // AbortSignal handling
      if (options.signal) {
        if (options.signal.aborted) {
          cleanup();
          reject(new Error("Request aborted"));
          return;
        }
        options.signal.addEventListener("abort", () => {
          aborted = true;
          cleanup();
          reject(new Error("Request aborted"));
        }, { once: true });
      }

      this.pending.set(id, {
        resolve: (response) => {
          if (!aborted) {
            cleanup();
            resolve(response);
          }
        },
        reject: (err) => {
          cleanup();
          reject(err);
        },
      });

      const body = JSON.stringify(request);
      const message = `Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`;

      this.process.stdin?.write(message, (err) => {
        if (err) {
          cleanup();
          reject(err);
        }
      });
    });
  }

  async sendStreaming(
    method: string,
    params: unknown,
    onEvent: (event: RPCResponse) => void,
    options: SendOptions = {}
  ): Promise<RPCResponse> {
    const id = `req_${++this.requestId}`;
    const request: RPCRequest = { id, method, params };
    const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS * 2; // Longer timeout for streaming

    return new Promise((resolve, reject) => {
      let timer: NodeJS.Timeout | null = null;
      let aborted = false;

      const cleanup = () => {
        if (timer) clearTimeout(timer);
        this.pending.delete(id);
        this.off("event", eventHandler);
      };

      // Timeout handling
      timer = setTimeout(() => {
        cleanup();
        reject(new Error(`Streaming request timeout after ${timeoutMs}ms`));
      }, timeoutMs);

      // Reset timeout on each event (progress)
      const resetTimeout = () => {
        if (timer) clearTimeout(timer);
        timer = setTimeout(() => {
          cleanup();
          reject(new Error(`No streaming progress for ${timeoutMs}ms`));
        }, timeoutMs);
      };

      // AbortSignal handling
      if (options.signal) {
        if (options.signal.aborted) {
          cleanup();
          reject(new Error("Request aborted"));
          return;
        }
        options.signal.addEventListener("abort", () => {
          aborted = true;
          cleanup();
          reject(new Error("Request aborted"));
        }, { once: true });
      }

      const eventHandler = (event: RPCResponse) => {
        const result = event.result as { request_id?: string; event?: string } | undefined;
        if (result?.request_id === id) {
          resetTimeout(); // Got progress, reset timeout
          if (!aborted) {
            onEvent(event);
          }
          if (result.event === "done" || result.event === "error") {
            cleanup();
            resolve(event);
          }
        }
      };

      this.on("event", eventHandler);
      this.pending.set(id, {
        resolve: (response) => {
          if (!aborted) {
            cleanup();
            resolve(response);
          }
        },
        reject: (err) => {
          cleanup();
          reject(err);
        },
      });

      const body = JSON.stringify(request);
      const message = `Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`;

      this.process.stdin?.write(message, (err) => {
        if (err) {
          cleanup();
          reject(err);
        }
      });
    });
  }

  close(): void {
    this.process.stdin?.end();
  }
}
