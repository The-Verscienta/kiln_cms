defmodule KilnCMSWeb.AshJsonApiRouter do
  use AshJsonApi.Router,
    domains: [KilnCMS.CMS],
    open_api: "/open_api"
end
