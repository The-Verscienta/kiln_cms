defmodule KilnCMSWeb.Plugs.LoadFromBearer do
  @moduledoc """
  Loads the user a bearer JWT names, in place of AshAuthentication's
  `:load_from_bearer` on the `:api`, `:graphql` and `:feed` pipelines (#2632).

  AshAuthentication's loader (`AshAuthentication.Plug.Helpers.retrieve_from_bearer/3`)
  reads only values that start with the exact `Bearer `, but an HTTP auth scheme
  is case-insensitive (RFC 7235), so `bearer <jwt>` and `BEARER <jwt>` were
  never loaded. This plug hands that loader a copy of the request whose
  bearer values are rewritten to `Bearer <token>` (`KilnCMSWeb.BearerAuth.normalize/1`),
  then puts the caller's `authorization` headers back, so nothing downstream
  sees a rewrite. A JWT that does not verify still leaves no actor, and
  `KilnCMSWeb.Plugs.ApiKeyAuth` answers it `401`.

  Never in the endpoint: federation's HTTP signatures read the raw headers.
  """
  @behaviour Plug

  alias KilnCMSWeb.BearerAuth

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    original = conn.req_headers

    conn
    |> Map.put(:req_headers, Enum.map(original, &normalize/1))
    |> AshAuthentication.Plug.Helpers.retrieve_from_bearer(:kiln_cms, opts)
    |> Map.put(:req_headers, original)
  end

  defp normalize({"authorization", value}), do: {"authorization", BearerAuth.normalize(value)}
  defp normalize(header), do: header
end
