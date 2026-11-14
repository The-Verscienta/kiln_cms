defmodule KilnCMSWeb.SentryRequestContextTest do
  @moduledoc """
  The request context `Sentry.PlugContext` records in the endpoint, for any
  event raised while the request is handled: its URL and `Referer` carry no
  credential from a token link.
  """
  use KilnCMSWeb.ConnCase, async: true

  @secret "T0kenSecretValue123"

  # `PlugContext` stores the context in the request process, which in a
  # `ConnTest` request is the test process.
  defp recorded_request, do: Sentry.Context.get_all().request

  test "a token link's URL and a credential query parameter are filtered", %{conn: conn} do
    conn
    |> put_req_header("referer", "http://www.example.com/password-reset/#{@secret}")
    |> get("/magic_link/#{@secret}?preview_token=#{@secret}&page=2")

    request = recorded_request()

    assert request.url ==
             "http://www.example.com/magic_link/[FILTERED]?preview_token=[FILTERED]&page=2"

    assert request.headers["referer"] == "http://www.example.com/password-reset/[FILTERED]"

    # The raw query string is masked in `before_send`, the last step before
    # an event leaves; nothing of the credential survives that.
    event =
      KilnCMS.SentryFilter.before_send(%Sentry.Event{
        event_id: "id",
        timestamp: "now",
        request: struct(Sentry.Interfaces.Request, request)
      })

    refute inspect(event.request) =~ @secret
  end

  test "an ordinary URL is recorded as requested", %{conn: conn} do
    get(conn, "/blog?page=2")
    assert recorded_request().url == "http://www.example.com/blog?page=2"
  end
end
