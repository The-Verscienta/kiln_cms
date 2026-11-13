defmodule KilnCMSWeb.Plugs.SecondFactorBearer do
  @moduledoc """
  A user JWT whose account its site now holds for a second factor it has not
  set up (#2247) is refused, on every request it makes (owner decision 3): a
  token minted during the grace period stops at the deadline, rather than
  living out its lifetime.

  On `:api`, `:graphql` and `:feed`, after `KilnCMSWeb.Plugs.ApiKeyAuth`, so
  it judges whichever actor those left: a user loaded from a JWT. **API keys
  are exempt** (the issue, and decision 3): an actor carrying
  `using_api_key?` metadata passes untouched, and so does an anonymous
  request. The decision is `KilnCMSWeb.SecondFactorGate.bearer_refused?/3` on
  the site the request resolved to: the account is held, or it is a
  passkey-only account past its deadline. A JWT never passed a passkey (the
  headless sign-in cannot take one), so for that account it is the password
  alone, whichever site's host minted it.

  The refusal is `403 second_factor_required`, `private, no-store` and
  `vary: authorization`: the `KilnCMSWeb.ApiError` envelope with
  `meta.setup_url`, or on `/gql` GraphQL's own error shape with
  `extensions.code: "second_factor_required"`. A public read is refused too:
  the client is sending a credential that is no longer good, and the answer
  says so rather than quietly serving it as anonymous (the same reasoning as
  the `401` for a token that does not verify, ADR 0017). Dropping the header
  reads public content as before.

  Each refusal emits `[:kiln_cms, :api, :second_factor_required]` (`count: 1`;
  metadata `surface`) and records no security event: a client retrying in a
  loop must not become an unbounded write. The sign-in doors record the event,
  once per sign-in.
  """
  @behaviour Plug

  use KilnCMSWeb, :verified_routes

  import Plug.Conn

  alias KilnCMSWeb.SecondFactorGate

  @message "This site requires two-step sign-in for your account. Set it up in a browser, then sign in again, or use an API key."

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if held?(Ash.PlugHelpers.get_actor(conn), conn), do: refuse(conn), else: conn
  end

  defp held?(%KilnCMS.Accounts.User{__metadata__: %{using_api_key?: true}}, _conn), do: false

  defp held?(%KilnCMS.Accounts.User{} = user, conn),
    do: SecondFactorGate.bearer_refused?(user, org_id(conn))

  defp held?(_anonymous, _conn), do: false

  defp refuse(conn) do
    :telemetry.execute([:kiln_cms, :api, :second_factor_required], %{count: 1}, %{
      surface: surface(conn)
    })

    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> KilnCMSWeb.Plugs.PublicCache.put_vary(["authorization"])
    |> send_error()
    |> halt()
  end

  defp send_error(%Plug.Conn{path_info: ["gql" | _]} = conn) do
    body = %{
      errors: [%{message: @message, extensions: %{code: "second_factor_required"}}]
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(body))
  end

  defp send_error(conn) do
    KilnCMSWeb.ApiError.send(conn, :forbidden, "second_factor_required", @message,
      meta: %{setup_url: url(conn, ~p"/account/two-factor")}
    )
  end

  defp surface(%Plug.Conn{path_info: ["gql" | _]}), do: :graphql
  defp surface(%Plug.Conn{path_info: ["api", "json" | _]}), do: :json_api
  defp surface(%Plug.Conn{path_info: ["api", "feed" | _]}), do: :feed
  defp surface(_conn), do: :other

  defp org_id(conn) do
    case conn.assigns[:current_org] do
      %{id: id} when is_binary(id) -> id
      _none -> nil
    end
  end
end
