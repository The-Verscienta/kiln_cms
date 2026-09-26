defmodule KilnCMS.Search.Meilisearch.Client do
  @moduledoc """
  Behaviour for talking to a Meilisearch instance.

  The active implementation is selected by
  `config :kiln_cms, KilnCMS.Search.Meilisearch, client: ...` and reached via the
  `KilnCMS.Search.Meilisearch` facade. The default is
  `KilnCMS.Search.Meilisearch.ReqClient` (HTTP via Req). Tests inject a stub so
  no server is required.

  One generic `request/4` callback keeps the surface small: the facade builds the
  method/path/body, the client only deals with transport (base URL + auth header)
  and returns the decoded JSON body.
  """

  @typedoc """
  A configured Meilisearch endpoint: base URL, optional key, and whether the
  URL was chosen by a site rather than the operator (`safe: true`), in which
  case the request must go through `KilnCMS.SafeFetch` — see
  `KilnCMS.Search.Meilisearch.SiteInstance`.
  """
  @type config :: %{
          required(:url) => String.t(),
          required(:master_key) => String.t() | nil,
          optional(:safe) => boolean()
        }

  @callback request(
              method :: :get | :post | :put | :patch | :delete,
              path :: String.t(),
              body :: map() | list() | nil,
              config :: config()
            ) :: {:ok, term()} | {:error, term()}
end
