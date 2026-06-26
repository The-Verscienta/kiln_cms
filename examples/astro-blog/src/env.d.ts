/// <reference path="../.astro/types.d.ts" />
/// <reference types="astro/client" />

interface ImportMetaEnv {
  readonly KILN_API_URL?: string;
  readonly KILN_LOCALE?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
