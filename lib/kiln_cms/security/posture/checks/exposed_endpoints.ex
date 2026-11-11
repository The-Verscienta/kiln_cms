defmodule KilnCMS.Security.Posture.Checks.ExposedEndpoints do
  @moduledoc """
  `core.exposed_endpoints` (#2252): endpoints that tell an outsider more than
  they need to know.

  Fails when the Prometheus exporter (`KilnCMSWeb.Metrics`) is on, bound to
  every interface, with no token (an empty `KILN_METRICS_TOKEN` counts as
  none). Warns when the API explorer and spec (`:api_docs`) or GraphQL
  introspection are on. Each is read through the function the route itself
  asks (`KilnCMSWeb.Plugs.ApiDocs.enabled?/0`,
  `KilnCMSWeb.GraphqlLimits.introspection_enabled?/0`), or the exporter's own
  configuration.
  """
  use Kiln.Security.Check
  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.Security.Posture

  @impl Kiln.Security.Check
  def id, do: "core.exposed_endpoints"

  @impl Kiln.Security.Check
  def title, do: gettext("Exposed endpoints")

  @impl Kiln.Security.Check
  def description,
    do:
      gettext(
        "The API explorer, GraphQL introspection and an open metrics port each map the installation for an attacker."
      )

  @impl Kiln.Security.Check
  def scope, do: :deployment

  @impl Kiln.Security.Check
  def run(_context) do
    metrics_public? = metrics_public?(Application.get_env(:kiln_cms, KilnCMSWeb.Metrics, []))
    api_docs? = KilnCMSWeb.Plugs.ApiDocs.enabled?() == true
    introspection? = KilnCMSWeb.GraphqlLimits.introspection_enabled?() == true

    open =
      [
        {metrics_public?,
         gettext(
           "The metrics port listens on every interface with no token (KILN_METRICS_TOKEN)."
         )},
        {api_docs?, gettext("The API explorer and spec are served (api_docs).")},
        {introspection?, gettext("GraphQL introspection is on.")}
      ]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    opts = [
      details: open,
      docs_url: Posture.docs_url("exposed-endpoints"),
      facts: %{
        metrics_public: metrics_public?,
        api_docs: api_docs?,
        graphql_introspection: introspection?
      }
    ]

    cond do
      metrics_public? ->
        fail(gettext("Anyone who can reach the metrics port can read it."), opts)

      open != [] ->
        warn(gettext("Endpoints that describe the API to anyone are on."), opts)

      true ->
        pass(gettext("Nothing describes the installation to an outsider."), opts)
    end
  end

  defp metrics_public?(config) do
    Keyword.get(config, :enabled, false) == true and Keyword.get(config, :bind) == :all and
      Keyword.get(config, :token) in [nil, ""]
  end
end
