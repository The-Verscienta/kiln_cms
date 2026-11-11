#!/usr/bin/env node
/**
 * kiln-types — generate TypeScript declarations from a Kiln site's live
 * delivery schema (`GET /api/schema`, dynamic content types and custom fields
 * included).
 *
 *     kiln-types --url https://cms.example.com --out src/kiln-types.d.ts
 *     kiln-types --url https://cms.example.com --check src/kiln-types.d.ts
 *     kiln-types --from schema.json                # offline, from a saved export
 *     kiln-types --url http://localhost:4000 --type post,page
 *     kiln-types --blocks-only                     # the block union alone
 *
 * With no `--url`, reads `KILN_API_URL` (default `http://localhost:4000`).
 * With no `--out`, writes to stdout. `--check` writes nothing and exits 1 when
 * the file differs from what `--out` would write. The command lives in
 * `../cli.ts`; this file only wires it to the process.
 */

import process from "node:process";

import { run } from "../cli.js";

process.exitCode = await run(process.argv.slice(2), {
  stdout: (text) => process.stdout.write(text),
  stderr: (text) => process.stderr.write(text),
  env: process.env,
});
