defmodule KilnCMSWeb.SentryScrubberTest do
  @moduledoc """
  The grants a headless read takes (#1887, #496) never reach a Sentry event:
  not as a header, and not in the raw query string `Sentry.PlugContext` copies.
  """
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias KilnCMSWeb.SentryScrubber

  test "credential headers are dropped, ordinary ones kept" do
    headers =
      conn(:get, "/api/json/posts/1")
      |> put_req_header("x-kiln-preview-token", "SFMyNTY.secret")
      |> put_req_header("x-kiln-unlock", "grant")
      |> put_req_header("x-api-key", "kiln_key")
      |> put_req_header("x-csrf-token", "csrf")
      |> put_req_header("authorization", "Bearer kiln_key")
      |> put_req_header("accept", "application/vnd.api+json")
      |> SentryScrubber.scrub_headers()

    assert headers == %{"accept" => "application/vnd.api+json"}
  end

  test "the query string's credentials are masked, the rest kept as sent" do
    scrubbed =
      SentryScrubber.scrub_query_string(
        "preview_token=SFMyNTY.secret&unlock=grant&passphrase=pw&surface=json&locale=en"
      )

    params = URI.decode_query(scrubbed)
    refute scrubbed =~ "SFMyNTY"
    assert params["preview_token"] == "*********"
    assert params["unlock"] == "*********"
    assert params["passphrase"] == "*********"
    assert params["surface"] == "json"
    assert params["locale"] == "en"
  end

  test "an empty or absent query string is left alone" do
    assert SentryScrubber.scrub_query_string("") == ""
    assert SentryScrubber.scrub_query_string(nil) == nil
  end
end
