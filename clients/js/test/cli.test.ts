import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { firstDifference, run, type CliIo } from "../src/cli.js";
import { emitTypes, type SchemaDocument } from "../src/generator.js";
import { stubFetch } from "./helpers.js";

/**
 * `kiln-types`, driven in-process. `--check` mirrors
 * `mix kiln.export.schema --check` (test/mix/tasks/kiln_export_schema_test.exs
 * in the Kiln repo): same refusals, same "is up to date" / "is out of date:
 * line N is …, the export has …" wording.
 */

const fixturePath = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "schema.json");

interface Captured {
  io: CliIo;
  stdout: () => string;
  stderr: () => string;
}

function capture(extra: Partial<CliIo> = {}): Captured {
  let out = "";
  let err = "";
  return {
    io: {
      stdout: (text) => (out += text),
      stderr: (text) => (err += text),
      env: {},
      ...extra,
    },
    stdout: () => out,
    stderr: () => err,
  };
}

let dir: string;

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), "kiln-types-"));
});

afterEach(async () => {
  await rm(dir, { recursive: true, force: true });
});

describe("kiln-types --out", () => {
  it("writes what emitTypes renders", async () => {
    const path = join(dir, "kiln.d.ts");
    const cli = capture();

    expect(await run(["--from", fixturePath, "--out", path], cli.io)).toBe(0);

    const document = JSON.parse(await readFile(fixturePath, "utf8")) as SchemaDocument;
    expect(await readFile(path, "utf8")).toBe(emitTypes(document));
    expect(cli.stderr()).toBe(`Wrote ${path}\n`);
  });
});

describe("kiln-types --check", () => {
  it("passes on a file --out wrote with the same flags, and writes nothing", async () => {
    const path = join(dir, "kiln.d.ts");
    await run(["--from", fixturePath, "--out", path], capture().io);
    const written = (await stat(path)).mtimeMs;

    const cli = capture();
    expect(await run(["--from", fixturePath, "--check", path], cli.io)).toBe(0);

    expect(cli.stderr()).toBe(`${path} is up to date (3 block type(s), 2 content type(s)).\n`);
    expect(cli.stdout()).toBe("");
    expect((await stat(path)).mtimeMs).toBe(written);
  });

  it("fails on a stale file, naming the first differing line", async () => {
    const path = join(dir, "kiln.d.ts");
    await run(["--from", fixturePath, "--out", path], capture().io);
    const fresh = await readFile(path, "utf8");
    const stale = fresh.replace(
      "// Artifact format version: 2",
      "// Artifact format version: 1",
    );
    expect(stale).not.toBe(fresh);
    await writeFile(path, stale, "utf8");

    const cli = capture();
    expect(await run(["--from", fixturePath, "--check", path], cli.io)).toBe(1);

    expect(cli.stderr()).toBe(
      `${path} is out of date: line 6 is "// Artifact format version: 1", ` +
        `the export has "// Artifact format version: 2". ` +
        `Re-export it with the same flags and --out ${path}.\n`,
    );
    // Nothing was rewritten.
    expect(await readFile(path, "utf8")).toBe(stale);
  });

  it("treats a lost trailing newline as stale, as git diff would", async () => {
    const path = join(dir, "kiln.d.ts");
    await run(["--from", fixturePath, "--out", path], capture().io);
    await writeFile(path, (await readFile(path, "utf8")).trimEnd(), "utf8");

    const cli = capture();
    expect(await run(["--from", fixturePath, "--check", path], cli.io)).toBe(1);
    expect(cli.stderr()).toMatch(/is out of date: line \d+ is past the end, the export has ""/);
  });

  it("fails on a missing file", async () => {
    const path = join(dir, "missing.d.ts");
    const cli = capture();

    expect(await run(["--from", fixturePath, "--check", path], cli.io)).toBe(1);
    expect(cli.stderr()).toBe(`--check ${path}: no such file or directory.\n`);
  });

  it("is refused with --out, before fetching anything", async () => {
    const stub = stubFetch({ body: {} });
    const cli = capture({ fetch: stub.fetchImpl });

    expect(await run(["--check", "a.d.ts", "--out", "b.d.ts"], cli.io)).toBe(1);
    expect(cli.stderr()).toBe("--check compares and writes nothing, so not with --out.\n");
    expect(stub.calls).toHaveLength(0);
  });

  it("checks against the live schema with the same query --out would send", async () => {
    const document = JSON.parse(await readFile(fixturePath, "utf8")) as SchemaDocument;
    const path = join(dir, "kiln.d.ts");
    await writeFile(path, emitTypes(document), "utf8");

    const stub = stubFetch({ body: document });
    const cli = capture({ fetch: stub.fetchImpl, env: { KILN_API_KEY: "k_test" } });

    const code = await run(
      ["--url", "https://cms.example.com", "--type", "post,landing_page", "--check", path],
      cli.io,
    );

    expect(code).toBe(0);
    expect(stub.calls).toHaveLength(1);
    const [call] = stub.calls;
    expect(call?.url.origin + call!.url.pathname).toBe("https://cms.example.com/api/schema");
    expect(call?.url.searchParams.get("type")).toBe("post,landing_page");
    expect(call?.headers.authorization).toBe("Bearer k_test");
    expect(cli.stderr()).toMatch(/is up to date/);
  });

  it("fails when the server does, without touching the file", async () => {
    const path = join(dir, "kiln.d.ts");
    await writeFile(path, "stale", "utf8");
    const stub = stubFetch({ status: 503, body: { errors: [{ code: "unavailable" }] } });
    const cli = capture({ fetch: stub.fetchImpl });

    expect(await run(["--url", "https://cms.example.com", "--check", path], cli.io)).toBe(1);
    expect(cli.stderr()).not.toMatch(/up to date/);
    expect(await readFile(path, "utf8")).toBe("stale");
  });
});

describe("firstDifference", () => {
  it("names the first line that differs and clips long lines", () => {
    expect(firstDifference("a\nb\n", "a\nc\n")).toBe('line 2 is "b", the export has "c"');
    expect(firstDifference("a\n", "a\nb\n")).toBe('line 2 is "", the export has "b"');
    expect(firstDifference("a\nb\n", "a\nb")).toBe('line 3 is "", the export has past the end');

    const long = "x".repeat(200);
    expect(firstDifference(long, "y")).toBe(
      `line 1 is "${"x".repeat(120)}", the export has "y"`,
    );
  });
});

describe("--help", () => {
  it("lists --check", async () => {
    const cli = capture();
    expect(await run(["--help"], cli.io)).toBe(0);
    expect(cli.stdout()).toMatch(/--check <file>/);
  });
});
