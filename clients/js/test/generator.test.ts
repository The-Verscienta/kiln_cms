import { describe, expect, it } from "vitest";

import { emitTypes, type SchemaDocument } from "../src/generator.js";

/** A miniature of the document `GET /api/schema` serves. */
function fixture(): SchemaDocument {
  return {
    $schema: "https://json-schema.org/draft/2020-12/schema",
    "x-kiln": { surface: "json", artifact_format_version: 3 },
    $defs: {
      block: {
        oneOf: [{ $ref: "#/$defs/block_rich_text" }, { $ref: "#/$defs/block_call_to_action" }],
      },
      block_rich_text: {
        type: "object",
        description: "Portable Text body.",
        properties: {
          _type: { const: "rich_text" },
          body: { type: "array", items: { $ref: "#/$defs/portable_text_block" } },
        },
        required: ["_type", "body"],
        additionalProperties: false,
      },
      block_call_to_action: {
        type: "object",
        properties: {
          _type: { const: "call_to_action" },
          label: { type: "string" },
          url: { type: ["string", "null"] },
        },
        required: ["_type", "label"],
        additionalProperties: false,
      },
      portable_text_block: {
        type: "object",
        properties: {
          _type: { const: "block" },
          style: { type: "string" },
        },
        required: ["_type"],
      },
      marker: { const: "fixed" },
      content_post: {
        type: "object",
        properties: {
          type: { const: "post" },
          title: { type: "string" },
          blocks: { type: "array", items: { $ref: "#/$defs/block" } },
          tier: { type: ["string", "null"], enum: ["free", "pro"] },
          custom_fields: {
            type: "object",
            properties: {
              "weird key!": { type: "string" },
              badge: { enum: ['say "hi"', "C:\\reports"] },
            },
            required: [],
          },
          author: { oneOf: [{ $ref: "#/$defs/portable_text_block" }] },
        },
        required: ["type", "title", "blocks"],
      },
      content_landing_page: {
        type: "object",
        properties: { type: { const: "landing_page" } },
        required: ["type"],
        additionalProperties: false,
      },
    },
  };
}

describe("emitTypes", () => {
  const output = emitTypes(fixture());

  it("names blocks, documents and shared defs by convention", () => {
    expect(output).toContain("export interface RichTextBlock {");
    expect(output).toContain("export interface CallToActionBlock {");
    expect(output).toContain("export interface PortableTextBlock {");
    expect(output).toContain("export interface PostDocument {");
    expect(output).toContain("export interface LandingPageDocument {");
  });

  it("emits the block union in ref order and the document union sorted", () => {
    expect(output).toContain(
      "export type KilnBlock =\n  | RichTextBlock\n  | CallToActionBlock;",
    );
    expect(output).toContain(
      "export type KilnDocument =\n  | LandingPageDocument\n  | PostDocument;",
    );
  });

  it("carries the artifact format version in the header", () => {
    expect(output).toContain("// Artifact format version: 3");
  });

  it("marks non-required properties optional and closes sealed objects", () => {
    // Sealed (additionalProperties: false): no index signature.
    expect(output).toContain(
      'export interface CallToActionBlock {\n  _type: "call_to_action";\n  label: string;\n  url?: string | null;\n}',
    );
    // Open object keeps the unknown-key fallback.
    expect(output).toMatch(/interface PortableTextBlock \{[^}]*\[k: string\]: unknown;\n\}/);
  });

  it("keeps null out of an enum's value union until the end", () => {
    expect(output).toContain('tier?: "free" | "pro" | null;');
  });

  it("quotes and escapes admin-authored keys and values", () => {
    expect(output).toContain('"weird key!"?: string');
    expect(output).toContain('badge?: "say \\"hi\\"" | "C:\\\\reports"');
  });

  it("renders doc comments and inline objects", () => {
    expect(output).toContain("/** Portable Text body. */\nexport interface RichTextBlock {");
    expect(output).toContain("blocks: Array<KilnBlock>;");
    expect(output).toContain("author?: PortableTextBlock;");
  });

  it("aliases a def with no properties to unknown", () => {
    expect(output).toContain("export type Marker = unknown;");
  });

  it("emits section rules", () => {
    expect(output).toContain("// -- Shared ");
    expect(output).toContain("// -- Blocks ");
    expect(output).toContain("// -- Block union ");
    expect(output).toContain("// -- Documents ");
    expect(output).toContain("// -- Document union ");
  });

  it("emits nothing but the header for an empty document", () => {
    const empty = emitTypes({});
    expect(empty).toContain("Artifact format version: unknown");
    expect(empty).not.toContain("export ");
  });
});
