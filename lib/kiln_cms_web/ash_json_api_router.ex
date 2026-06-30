defmodule KilnCMSWeb.AshJsonApiRouter do
  @moduledoc """
  JSON:API router for the headless content surface (`KilnCMS.CMS`).

  Serves the JSON:API content endpoints plus a published, machine-readable
  **OpenAPI 3** spec at `/api/json/open_api`. The spec is available in **every
  environment** (issue #37) — it describes a read surface whose published
  content is already world-readable — and backs the Swagger UI mounted at
  `/api/json/swaggerui` in `KilnCMSWeb.Router`.

  `KilnCMSWeb.OpenApi.modify/3` enriches the generated spec with auth/usage
  documentation and concrete servers.
  """

  # Only domains that exist in this repo — `Verscienta.Catalog` is a downstream
  # project-specific domain that isn't built here (same as in GraphqlSchema), so
  # listing it breaks a clean compile.
  use AshJsonApi.Router,
    domains: [KilnCMS.CMS],
    open_api: "/open_api",
    modify_open_api: {KilnCMSWeb.OpenApi, :modify, []}
end
