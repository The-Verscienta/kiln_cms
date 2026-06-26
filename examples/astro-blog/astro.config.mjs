// @ts-check
import { defineConfig } from "astro/config";

// A fully static build: every published document is fetched from the KilnCMS
// headless API at build time and rendered to plain HTML (no client JS needed).
// Point this at your running KilnCMS instance with `KILN_API_URL` (see .env.example).
export default defineConfig({
  output: "static",
});
