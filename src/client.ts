import { resolveHelper, ResolverResult } from "./resolver.js";
import { ProcessManager } from "./process-manager.js";
import { RPCResponse } from "./transport.js";

export type ReasonCode =
  | "NOT_DARWIN"
  | "UNSUPPORTED_HARDWARE"
  | "AI_DISABLED"
  | "MODEL_NOT_READY"
  | "SPAWN_FAILED"
  | "HELPER_UNHEALTHY"
  | "HELPER_NOT_FOUND"
  | "PROTOCOL_MISMATCH";

export interface CompatibilityResult {
  compatible: boolean;
  reasonCode?: ReasonCode;
}

export interface CapabilitiesResult {
  available: boolean;
  reasonCode?: string;
  model?: string;
}

export interface JSONSchema {
  type: "object" | "array" | "string" | "number" | "integer" | "boolean";
  properties?: Record<string, JSONSchema>;
  items?: JSONSchema;
  required?: string[];
  description?: string;
  enum?: string[];
}

export interface ResponseFormat {
  type: "json_schema";
  json_schema: {
    name: string;
    description?: string;
    schema: JSONSchema;
  };
}

export interface ResponsesCreateParams {
  model?: string;
  input: string;
  max_output_tokens?: number;
  stream?: boolean;
  signal?: AbortSignal;
  timeoutMs?: number;
  response_format?: ResponseFormat;
}

export interface ResponseResult {
  request_id: string;
  text: string;
  model?: string;
}

export interface StreamEvent {
  request_id: string;
  event: "delta" | "done" | "error";
  delta?: string;
  text?: string;
  model?: string;
  error?: { code: string; detail: string };
}

export const DEFAULT_MODEL = "default";

export interface ClientOptions {
  model?: string;
  onLog?: (message: string) => void;
  idleTimeoutMs?: number;
}

export class AppleLocalLLMClient {
  private options: ClientOptions;
  private resolverResult: ResolverResult | null = null;
  private processManager: ProcessManager | null = null;
  private compatibilityCache: CompatibilityResult | null = null;

  constructor(options: ClientOptions = {}) {
    this.options = { model: DEFAULT_MODEL, ...options };
  }

  private getModel(override?: string): string {
    return override ?? this.options.model ?? DEFAULT_MODEL;
  }

  get compatibility() {
    return {
      check: () => this.checkCompatibility(),
    };
  }

  get capabilities() {
    return {
      get: () => this.getCapabilities(),
    };
  }

  get responses() {
    return {
      create: (params: ResponsesCreateParams) => this.createResponse(params),
      cancel: (requestId: string) => this.cancelResponse(requestId),
    };
  }

  private async checkCompatibility(): Promise<CompatibilityResult> {
    if (this.compatibilityCache) {
      return this.compatibilityCache;
    }

    // Fast JS-side checks
    this.resolverResult = resolveHelper();
    if (!this.resolverResult.ok) {
      const result: CompatibilityResult = {
        compatible: false,
        reasonCode: this.resolverResult.reasonCode,
      };
      this.compatibilityCache = result;
      return result;
    }

    // Spawn helper and check capabilities
    try {
      this.processManager = new ProcessManager(this.resolverResult.location, {
        onLog: this.options.onLog,
        idleTimeoutMs: this.options.idleTimeoutMs,
      });

      const transport = await this.processManager.getTransport();
      const response = await transport.send("capabilities.get");

      if (!response.ok) {
        const result: CompatibilityResult = {
          compatible: false,
          reasonCode: "HELPER_UNHEALTHY",
        };
        this.compatibilityCache = result;
        return result;
      }

      const caps = response.result as { available: boolean; reason_code?: string; model?: string };
      if (caps.available) {
        const result: CompatibilityResult = { compatible: true };
        this.compatibilityCache = result;
        return result;
      } else {
        const result: CompatibilityResult = {
          compatible: false,
          reasonCode: caps.reason_code as ReasonCode,
        };
        this.compatibilityCache = result;
        return result;
      }
    } catch (err) {
      const result: CompatibilityResult = {
        compatible: false,
        reasonCode: "SPAWN_FAILED",
      };
      this.compatibilityCache = result;
      return result;
    }
  }

  private async getCapabilities(): Promise<CapabilitiesResult> {
    const compat = await this.checkCompatibility();
    if (!compat.compatible) {
      return {
        available: false,
        reasonCode: compat.reasonCode,
      };
    }

    const transport = await this.processManager!.getTransport();
    const response = await transport.send("capabilities.get");

    if (!response.ok) {
      return {
        available: false,
        reasonCode: response.error?.code,
      };
    }

    const raw = response.result as { available: boolean; reason_code?: string; model?: string };
    return {
      available: raw.available,
      reasonCode: raw.reason_code,
      model: raw.model,
    };
  }

  private async createResponse(
    params: ResponsesCreateParams
  ): Promise<
    | { ok: true; text: string; request_id: string }
    | { ok: false; error: { code: string; detail: string } }
  > {
    const compat = await this.checkCompatibility();
    if (!compat.compatible) {
      return {
        ok: false,
        error: {
          code: "UNAVAILABLE",
          detail: `Not compatible: ${compat.reasonCode}`,
        },
      };
    }

    const transport = await this.processManager!.getTransport();

    if (params.stream) {
      // For streaming, collect all deltas
      let fullText = "";
      const response = await transport.sendStreaming(
        "responses.create",
        {
          model: this.getModel(params.model),
          input: params.input,
          max_output_tokens: params.max_output_tokens,
          stream: true,
          response_format: params.response_format,
        },
        (event) => {
          const result = event.result as StreamEvent | undefined;
          if (result?.delta) {
            fullText += result.delta;
          }
        },
        { signal: params.signal, timeoutMs: params.timeoutMs }
      );

      const result = response.result as StreamEvent;
      if (result.event === "error" || !response.ok) {
        return {
          ok: false,
          error: result.error ?? response.error ?? { code: "INTERNAL", detail: "Unknown error" },
        };
      }

      return {
        ok: true,
        text: result.text ?? fullText,
        request_id: result.request_id,
      };
    } else {
      const response = await transport.send(
        "responses.create",
        { 
          model: this.getModel(params.model), 
          input: params.input, 
          max_output_tokens: params.max_output_tokens,
          response_format: params.response_format,
        },
        { signal: params.signal, timeoutMs: params.timeoutMs }
      );

      if (!response.ok) {
        return {
          ok: false,
          error: response.error ?? { code: "INTERNAL", detail: "Unknown error" },
        };
      }

      const result = response.result as ResponseResult;
      return {
        ok: true,
        text: result.text,
        request_id: result.request_id,
      };
    }
  }

  async *stream(
    params: Omit<ResponsesCreateParams, "stream">
  ): AsyncGenerator<{ delta: string } | { done: true; text: string }, void, unknown> {
    const compat = await this.checkCompatibility();
    if (!compat.compatible) {
      throw new Error(`Not compatible: ${compat.reasonCode}`);
    }

    const transport = await this.processManager!.getTransport();
    
    // Create a queue for streaming events
    const queue: Array<RPCResponse | { done: true }> = [];
    let resolveNext: (() => void) | null = null;
    let finished = false;

    transport.sendStreaming(
      "responses.create",
      {
        model: this.getModel(params.model),
        input: params.input,
        max_output_tokens: params.max_output_tokens,
        stream: true,
      },
      (event) => {
        queue.push(event);
        resolveNext?.();
      },
      { signal: params.signal, timeoutMs: params.timeoutMs }
    ).then(() => {
      finished = true;
      queue.push({ done: true });
      resolveNext?.();
    }).catch((err) => {
      finished = true;
      queue.push({ ok: false, error: { code: "INTERNAL", detail: err instanceof Error ? err.message : "Stream failed" } });
      resolveNext?.();
    });

    while (!finished || queue.length > 0) {
      if (queue.length === 0) {
        await new Promise<void>((r) => { resolveNext = r; });
        continue;
      }

      const event = queue.shift()!;
      if ("done" in event && event.done === true) break;

      // Handle error from .catch()
      if ("ok" in event && event.ok === false) {
        throw new Error((event as RPCResponse).error?.detail ?? "Stream failed");
      }

      const result = (event as RPCResponse).result as StreamEvent;
      if (result.event === "delta" && result.delta) {
        yield { delta: result.delta };
      } else if (result.event === "done") {
        yield { done: true, text: result.text ?? "" };
        break;
      } else if (result.event === "error") {
        throw new Error(result.error?.detail ?? "Stream error");
      }
    }
  }

  private async cancelResponse(requestId: string): Promise<{ ok: true } | { ok: false; error: { code: string; detail: string } }> {
    if (!this.processManager) {
      return { ok: false, error: { code: "NOT_RUNNING", detail: "No active session" } };
    }

    try {
      const transport = await this.processManager.getTransport();
      const response = await transport.send("responses.cancel", { request_id: requestId });

      if (!response.ok) {
        return {
          ok: false,
          error: response.error ?? { code: "INTERNAL", detail: "Cancel failed" },
        };
      }

      return { ok: true };
    } catch (err) {
      return {
        ok: false,
        error: { code: "INTERNAL", detail: err instanceof Error ? err.message : "Cancel failed" },
      };
    }
  }

  async shutdown(): Promise<void> {
    await this.processManager?.shutdown();
  }
}

export function createClient(options?: ClientOptions): AppleLocalLLMClient {
  return new AppleLocalLLMClient(options);
}
