import * as path from "path";
import * as fs from "fs";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export interface HelperLocation {
  type: "cli";
  executablePath: string;
}

export type ResolverResult =
  | { ok: true; location: HelperLocation }
  | { ok: false; reasonCode: "NOT_DARWIN" | "UNSUPPORTED_HARDWARE" | "HELPER_NOT_FOUND" };

export function resolveHelper(): ResolverResult {
  if (process.platform !== "darwin") {
    return { ok: false, reasonCode: "NOT_DARWIN" };
  }

  if (process.arch !== "arm64") {
    return { ok: false, reasonCode: "UNSUPPORTED_HARDWARE" };
  }

  const helperPath = findHelperBinary();
  if (!helperPath) {
    return { ok: false, reasonCode: "HELPER_NOT_FOUND" };
  }

  return {
    ok: true,
    location: {
      type: "cli",
      executablePath: helperPath,
    },
  };
}

function findHelperBinary(): string | null {
  // Try bundled binary in main package (npm distribution)
  const bundledPath = path.join(__dirname, "..", "bin", "fm-proxy");
  if (fs.existsSync(bundledPath)) {
    return bundledPath;
  }

  // Try development paths (for local testing)
  const devPaths = [
    path.join(__dirname, "..", "swift", ".build", "release", "fm-proxy"),
    path.join(__dirname, "..", "swift", ".build", "debug", "fm-proxy"),
  ];

  for (const p of devPaths) {
    if (fs.existsSync(p)) {
      return p;
    }
  }

  return null;
}

export async function ensureExecutable(location: HelperLocation): Promise<void> {
  try {
    await fs.promises.access(location.executablePath, fs.constants.X_OK);
  } catch {
    await fs.promises.chmod(location.executablePath, 0o755);
  }
}
