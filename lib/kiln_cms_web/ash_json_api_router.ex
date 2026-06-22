defmodule KilnCMSWeb.AshJsonApiRouter do
  @moduledoc false

  # OpenAPI spec is only compiled in when `dev_routes` is enabled — it backs
  # the Swagger UI and shouldn't be world-readable in production.
  if Application.compile_env(:kiln_cms, :dev_routes, false) do
    use AshJsonApi.Router,
      domains: [KilnCMS.CMS],
      open_api: "/open_api"
  else
    use AshJsonApi.Router,
      domains: [KilnCMS.CMS]
  end
end
