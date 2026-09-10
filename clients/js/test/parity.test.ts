import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import { emitTypes, type SchemaDocument } from "../src/generator.js";

/**
 * The emitter-parity tripwire. `emitTypes` promises the same declarations as
 * the server-side `KilnCMS.SchemaExport.TypeScript` for the same document;
 * this golden is the shared source of truth that makes the promise testable.
 * The Elixir suite (`test/kiln_cms/schema_export/type_script_parity_test.exs`)
 * asserts the SAME golden from the same fixture, so a change to either
 * emitter that the other doesn't mirror turns exactly one side red.
 *
 * To regenerate after a deliberate, mirrored change to both emitters:
 *
 *     npm run build && node dist/bin/kiln-types.js \
 *       --from test/fixtures/schema.json --out test/fixtures/golden.d.ts
 */

const here = dirname(fileURLToPath(import.meta.url));

describe("emitter parity golden", () => {
  it("reproduces fixtures/golden.d.ts byte-for-byte", () => {
    const fixture = JSON.parse(
      readFileSync(join(here, "fixtures", "schema.json"), "utf8"),
    ) as SchemaDocument;
    const golden = readFileSync(join(here, "fixtures", "golden.d.ts"), "utf8");

    expect(emitTypes(fixture)).toBe(golden);
  });
});
