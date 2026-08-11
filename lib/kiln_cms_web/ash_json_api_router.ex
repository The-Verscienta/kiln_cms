defmodule KilnCMSWeb.AshJsonApiRouter do
  @moduledoc """
  JSON:API router for the headless content surface (`KilnCMS.CMS`).

  Serves the JSON:API content endpoints plus a published, machine-readable
  **OpenAPI 3** spec at `/api/json/open_api` (issue #37), which backs the
  Swagger UI mounted at `/api/json/swaggerui` in `KilnCMSWeb.Router`.

  The spec route follows `config :kiln_cms, :api_docs` — on in dev and test,
  off in a production build (#567), because since #330 it describes the write
  surface too. `KilnCMSWeb.Plugs.ApiDocs` enforces that from the `:api`
  pipeline, since the route lives inside this router rather than in the
  application's own.

  `KilnCMSWeb.OpenApi.modify/3` enriches the generated spec with auth/usage
  documentation and concrete servers.
  """

  # Domains come from `:content_domains` at compile time (same as in
  # GraphqlSchema), so a downstream project overlay exposes its domain on the
  # JSON:API surface purely via `config/project.exs` — no core edit.
  use AshJsonApi.Router,
    domains: Application.compile_env(:kiln_cms, :content_domains, [KilnCMS.CMS]),
    open_api: "/open_api",
    modify_open_api: {KilnCMSWeb.OpenApi, :modify, []}
end
