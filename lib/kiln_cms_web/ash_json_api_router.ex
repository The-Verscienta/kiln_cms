defmodule KilnCMSWeb.AshJsonApiRouter do
  @moduledoc false
  use AshJsonApi.Router,
    domains: [KilnCMS.CMS],
    open_api: "/open_api"
end
