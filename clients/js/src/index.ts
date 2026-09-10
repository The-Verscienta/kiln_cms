export { createClient, KilnClient, type KilnClientOptions } from "./client.js";
export { KilnHttpError, isKilnHttpError } from "./errors.js";
export { flattenDocument, refKey, rel, resolve } from "./jsonapi.js";
export { emitTypes, type SchemaDocument } from "./generator.js";
export type {
  ArtifactDocument,
  ArtifactOptions,
  AsOfIndexEntry,
  AsOfIndexOptions,
  AsOfIndexResult,
  AutocompleteOptions,
  Block,
  Filter,
  FilterScalar,
  FilterSpec,
  HybridSearchOptions,
  HybridSearchResult,
  IncludedMap,
  Item,
  ListOptions,
  ListResult,
  PortableTextBlock,
  PortableTextMarkDef,
  PortableTextSpan,
  RequestOptions,
  ResourceRef,
  SchemaOptions,
  SearchOptions,
  Surface,
  WebArtifact,
} from "./types.js";
