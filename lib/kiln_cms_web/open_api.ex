defmodule KilnCMSWeb.OpenApi do
  @moduledoc """
  Enriches the AshJsonApi-generated OpenAPI 3 document for the headless
  JSON:API (`/api/json/open_api`).

  AshJsonApi already derives the content paths (Page / Post / MediaItem) and a
  `bearerAuth` security scheme from the resources. This module layers on the
  human-facing metadata — title, version and a description covering
  authentication, pagination and outbound webhooks — so the published spec is a
  complete, self-describing piece of API documentation for headless consumers.

  Wired in via `modify_open_api: {KilnCMSWeb.OpenApi, :modify_spec, []}` in
  `KilnCMSWeb.AshJsonApiRouter`. The spec is published in **all** environments;
  the interactive Swagger UI explorer is dev-only (see `KilnCMSWeb.Router`).
  """

  @title "KilnCMS JSON:API"

  @doc "The spec title, also asserted in tests."
  @spec title() :: String.t()
  def title, do: @title

  @doc "The current application version, used as the OpenAPI `info.version`."
  @spec version() :: String.t()
  def version do
    case Application.spec(:kiln_cms, :vsn) do
      nil -> "0.0.0"
      vsn -> List.to_string(vsn)
    end
  end

  @doc """
  `modify_open_api` hook. Receives the generated `OpenApiSpex.OpenApi` struct
  and returns it with KilnCMS metadata applied to `info`.
  """
  @spec modify_spec(OpenApiSpex.OpenApi.t(), Plug.Conn.t() | nil, keyword()) ::
          OpenApiSpex.OpenApi.t()
  def modify_spec(spec, _conn, _opts) do
    # AshJsonApi always populates `info` (title + version are required keys on
    # `OpenApiSpex.Info`), so update the existing struct rather than rebuild it.
    info = %{spec.info | title: @title, version: version(), description: description()}
    %{spec | info: info}
  end

  defp description do
    """
    KilnCMS exposes a [JSON:API](https://jsonapi.org/)-compliant,
    **read-oriented** content delivery surface for headless consumers. The
    content types — **Page**, **Post** and **MediaItem** — are documented in the
    operations below; this overview covers the cross-cutting concerns.

    ## Authentication

    Requests are **anonymous by default** and pass through each resource's read
    policy, so unauthenticated clients see only **published** content. To read
    drafts, in-review or archived content, send a JWT as a bearer token
    belonging to an editor or admin:

    ```
    Authorization: Bearer <token>
    ```

    Tokens are issued by AshAuthentication — sign in via the `/auth` routes
    (password or magic-link strategies). The `bearerAuth` security scheme below
    applies to every operation.

    ## Content negotiation

    All requests and responses use the JSON:API media type
    `application/vnd.api+json`.

    ## Pagination, filtering & sorting

    Collection routes are paginated (offset + keyset: `page[limit]`,
    `page[offset]`, `page[after]`; default 25, max 100) and support `filter[...]`
    and `sort=`. See the full reference in `docs/json-api.md`.

    ## Webhooks

    Publishing and unpublishing content emits **HMAC-SHA256-signed outbound
    webhooks**, delivered to subscribed endpoints by Oban. Each delivery carries
    an `x-kilncms-event` header and an `x-kilncms-signature` header (lowercase
    hex HMAC of the request body, keyed by the endpoint secret) so receivers can
    verify authenticity. These are outbound callbacks **to** your services, not
    endpoints of this HTTP API.
    """
  end
end
