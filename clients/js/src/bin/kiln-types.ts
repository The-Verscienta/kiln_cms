#!/usr/bin/env node
/**
 * kiln-types — generate TypeScript declarations from a Kiln site's live
 * delivery schema (`GET /api/schema`, dynamic content types and custom fields
 * included).
 *
 *     kiln-types --url https://cms.example.com --out src/kiln-types.d.ts
 *     kiln-types --from schema.json                # offline, from a saved export
 *     kiln-types --url http://localhost:4000 --type post,page
 *     kiln-types --blocks-only                     # the block union alone
 *
 * With no `--url`, reads `KILN_API_URL` (default `http://localhost:4000`).
 * With no `--out`, writes to stdout.
 */

import { readFile, writeFile } from "node:fs/promises";
import process from "node:process";

import { createClient } from "../client.js";
import { emitTypes, type SchemaDocument } from "../generator.js";

interface CliOptions {
  url?: string;
  from?: string;
  out?: string;
  types?: string;
  apiKey?: string;
  blocksOnly: boolean;
}

function usage(): string {
  return [
    "Usage: kiln-types [options]",
    "",
    "  --url <base>     Kiln base URL (default: $KILN_API_URL or http://localhost:4000)",
    "  --from <file>    read the schema document from a JSON file instead of a URL",
    "  --out <file>     write declarations here (default: stdout)",
    "  --type <a,b>     restrict to these content types (?type=)",
    "  --blocks-only    the block union alone, no content types (?blocks=only)",
    "  --api-key <key>  bearer API key (default: $KILN_API_KEY)",
    "  --help           show this help",
  ].join("\n");
}

function parseArgs(argv: string[]): CliOptions {
  const options: CliOptions = { blocksOnly: false };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = (): string => {
      const next = argv[++i];
      if (next === undefined) throw new Error(`${arg} needs a value\n\n${usage()}`);
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
        console.log(usage());
        process.exit(0);
        break;
      default:
        throw new Error(`Unknown option: ${arg}\n\n${usage()}`);
    }
  }

  return options;
}

// Fetches through the client rather than a bare `fetch`, so the CLI inherits
// its transport whole: the 15s timeout (a degraded server stalls rather than
// fails — the trap the client exists to bound), bearer auth, and
// KilnHttpError bodies.
async function loadDocument(options: CliOptions): Promise<SchemaDocument> {
  if (options.from !== undefined) {
    return JSON.parse(await readFile(options.from, "utf8")) as SchemaDocument;
  }

  const kiln = createClient({
    baseUrl: options.url ?? process.env.KILN_API_URL ?? "http://localhost:4000",
    apiKey: options.apiKey ?? process.env.KILN_API_KEY,
  });

  return kiln.schema({
    types: options.types?.split(",").filter((name) => name !== ""),
    blocksOnly: options.blocksOnly,
  });
}

async function main(): Promise<void> {
  const options = parseArgs(process.argv.slice(2));
  const document = await loadDocument(options);
  const declarations = emitTypes(document);

  if (options.out === undefined) {
    process.stdout.write(declarations);
  } else {
    await writeFile(options.out, declarations, "utf8");
    console.error(`Wrote ${options.out}`);
  }
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
