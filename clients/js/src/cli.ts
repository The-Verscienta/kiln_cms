/**
 * The `kiln-types` command, apart from its process: `bin/kiln-types.ts` hands
 * it `process.argv`, the environment and the standard streams, and turns the
 * returned code into the exit status. Kept out of the bin so the tests drive
 * it in-process, with a stubbed `fetch` and no `process.exit`.
 *
 * Not part of the package's public API (`index.ts` does not export it).
 */

import { readFile, writeFile } from "node:fs/promises";

import { createClient } from "./client.js";
import { emitTypes, type SchemaDocument } from "./generator.js";

export interface CliIo {
  /** Declarations go here when there is no `--out` (and `--help`). */
  stdout: (text: string) => void;
  /** Status lines and errors. */
  stderr: (text: string) => void;
  env: Record<string, string | undefined>;
  /** The client's transport; defaults to `globalThis.fetch`. */
  fetch?: typeof globalThis.fetch;
}

interface CliOptions {
  url?: string;
  from?: string;
  out?: string;
  check?: string;
  types?: string;
  apiKey?: string;
  blocksOnly: boolean;
  help: boolean;
}

/** A refusal whose message is the whole report: no stack, exit 1. */
class CliError extends Error {}

export function usage(): string {
  return [
    "Usage: kiln-types [options]",
    "",
    "  --url <base>     Kiln base URL (default: $KILN_API_URL or http://localhost:4000)",
    "  --from <file>    read the schema document from a JSON file instead of a URL",
    "  --out <file>     write declarations here (default: stdout)",
    "  --check <file>   compare with this file instead of writing; exit 1 if it differs",
    "  --type <a,b>     restrict to these content types (?type=)",
    "  --blocks-only    the block union alone, no content types (?blocks=only)",
    "  --api-key <key>  bearer API key (default: $KILN_API_KEY)",
    "  --help           show this help",
  ].join("\n");
}

function parseArgs(argv: string[]): CliOptions {
  const options: CliOptions = { blocksOnly: false, help: false };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = (): string => {
      const next = argv[++i];
      if (next === undefined) throw new CliError(`${arg} needs a value\n\n${usage()}`);
      return next;
    };

    switch (arg) {
      case "--url":
        options.url = value();
        break;
      case "--from":
        options.from = value();
        break;
      case "--out":
        options.out = value();
        break;
      case "--check":
        options.check = value();
        break;
      case "--type":
        options.types = value();
        break;
      case "--api-key":
        options.apiKey = value();
        break;
      case "--blocks-only":
        options.blocksOnly = true;
        break;
      case "--help":
      case "-h":
        options.help = true;
        break;
      default:
        throw new CliError(`Unknown option: ${arg}\n\n${usage()}`);
    }
  }

  // Same refusal, same words, as `mix kiln.export.schema --check`.
  if (options.check !== undefined && options.out !== undefined) {
    throw new CliError("--check compares and writes nothing, so not with --out.");
  }

  return options;
}

// Fetches through the client rather than a bare `fetch`, so the CLI inherits
// its transport whole: the 15s timeout (a degraded server stalls rather than
// fails — the trap the client exists to bound), bearer auth, and
// KilnHttpError bodies.
async function loadDocument(options: CliOptions, io: CliIo): Promise<SchemaDocument> {
  if (options.from !== undefined) {
    return JSON.parse(await readFile(options.from, "utf8")) as SchemaDocument;
  }

  const kiln = createClient({
    baseUrl: options.url ?? io.env.KILN_API_URL ?? "http://localhost:4000",
    apiKey: options.apiKey ?? io.env.KILN_API_KEY,
    fetch: io.fetch,
  });

  return kiln.schema({
    types: options.types?.split(",").filter((name) => name !== ""),
    blocksOnly: options.blocksOnly,
  });
}

/** Run `kiln-types` with `argv` (no node/script prefix); resolves to the exit code. */
export async function run(argv: string[], io: CliIo): Promise<number> {
  try {
    const options = parseArgs(argv);

    if (options.help) {
      io.stdout(`${usage()}\n`);
      return 0;
    }

    const document = await loadDocument(options, io);
    const declarations = emitTypes(document);

    if (options.check !== undefined) {
      await check(options.check, declarations);
      io.stderr(`${options.check} is up to date (${summary(document)}).\n`);
    } else if (options.out === undefined) {
      io.stdout(declarations);
    } else {
      await writeFile(options.out, declarations, "utf8");
      io.stderr(`Wrote ${options.out}\n`);
    }

    return 0;
  } catch (error: unknown) {
    io.stderr(`${error instanceof Error ? error.message : String(error)}\n`);
    return 1;
  }
}

// Compares bytes, the way `git diff --exit-code` would after an `--out`, so a
// file that only differs in a trailing newline or line endings is stale too.
async function check(path: string, expected: string): Promise<void> {
  let current: string;

  try {
    current = await readFile(path, "utf8");
  } catch (error: unknown) {
    throw new CliError(`--check ${path}: ${fileError(error)}.`);
  }

  if (current !== expected) {
    throw new CliError(
      `${path} is out of date: ${firstDifference(current, expected)}. ` +
        `Re-export it with the same flags and --out ${path}.`,
    );
  }
}

// The first line that differs, so a CI log says where without dumping both
// files.
export function firstDifference(current: string, expected: string): string {
  const currentLines = current.split("\n");
  const expectedLines = expected.split("\n");
  const count = Math.max(currentLines.length, expectedLines.length);

  let index = 0;
  while (index < count && currentLines[index] === expectedLines[index]) index++;

  return (
    `line ${index + 1} is ${lineText(currentLines[index])}, ` +
    `the export has ${lineText(expectedLines[index])}`
  );
}

function lineText(line: string | undefined): string {
  if (line === undefined) return "past the end";
  return JSON.stringify(Array.from(line).slice(0, 120).join(""));
}

function summary(document: SchemaDocument): string {
  const kiln = document["x-kiln"] ?? {};
  const count = (key: string) => (Array.isArray(kiln[key]) ? kiln[key].length : 0);
  return `${count("blocks")} block type(s), ${count("content_types")} content type(s)`;
}

// The reason alone, as `:file.format_error/1` gives it server-side, not Node's
// "ENOENT: no such file or directory, open '…'" with the path a second time.
function fileError(error: unknown): string {
  const code = (error as { code?: unknown } | null)?.code;
  if (code === "ENOENT") return "no such file or directory";
  if (code === "EISDIR") return "illegal operation on a directory";
  if (code === "EACCES") return "permission denied";
  return error instanceof Error ? error.message : String(error);
}
