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

  @typedoc "A configured Meilisearch endpoint: base URL + optional master key."
  @type config :: %{required(:url) => String.t(), required(:master_key) => String.t() | nil}

  @callback request(
              method :: :get | :post | :put | :patch | :delete,
              path :: String.t(),
              body :: map() | nil,
              config :: config()
            ) :: {:ok, term()} | {:error, term()}
end
