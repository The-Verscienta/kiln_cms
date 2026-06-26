defmodule KilnCMSWeb.AshJsonApiRouter do
  @moduledoc """
  Headless JSON:API router for the CMS domain.

  Serves the JSON:API content endpoints at `/api/json` and a machine-readable
  **OpenAPI 3 spec** at `/api/json/open_api`. The spec is **published in all
  environments** (issue #37) so headless consumers can generate clients or
  render docs with Redoc, Swagger UI, Postman, etc. against dev or prod. The
  interactive Swagger UI explorer itself stays dev-only (see `KilnCMSWeb.Router`)
  because it ships inline scripts/CDN assets that conflict with the strict
  production CSP — point any external OpenAPI viewer at the spec instead.

  `KilnCMSWeb.OpenApi.modify_spec/3` enriches the generated document with the
  title, app version and a description covering authentication, pagination and
  webhooks.
  """

  use AshJsonApi.Router,
    domains: [KilnCMS.CMS],
    open_api: "/open_api",
    modify_open_api: {KilnCMSWeb.OpenApi, :modify_spec, []}
end
