// Flat ESLint config: typescript-eslint recommended over src/ and test/.
import eslint from "@eslint/js";
import tseslint from "typescript-eslint";

export default tseslint.config(
  { ignores: ["dist/", "node_modules/"] },
  eslint.configs.recommended,
  ...tseslint.configs.recommended,
  {
    rules: {
      // The client deals in JSON documents whose shape is the server's to
      // define; `unknown` + narrowing is the pattern, but explicit `any` stays
      // an error so a lazy cast can't silently widen the public types.
      "@typescript-eslint/no-explicit-any": "error",
      "@typescript-eslint/consistent-type-imports": "error",
    },
  },
);
