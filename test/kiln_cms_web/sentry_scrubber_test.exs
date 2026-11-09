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

  test "a public form's human-verification token is masked in the params (#2249)" do
    params =
      SentryScrubber.scrub_params(%Plug.Conn{
        params: %{
          "_kiln_challenge" => "0.token",
          "cf-turnstile-response" => "0.other",
          "email" => "a@example.com"
        }
      })

    assert params["_kiln_challenge"] == "*********"
    assert params["cf-turnstile-response"] == "*********"
    assert params["email"] == "a@example.com"
  end

  test "reCAPTCHA's own token field is masked (#2249)" do
    params =
      SentryScrubber.scrub_params(%Plug.Conn{
        params: %{
          "g-recaptcha-response" => "0.recaptcha",
          "email" => "a@example.com"
        }
      })

    assert params == %{
             "g-recaptcha-response" => "*********",
             "email" => "a@example.com"
           }
  end

  test "an empty or absent query string is left alone" do
    assert SentryScrubber.scrub_query_string("") == ""
    assert SentryScrubber.scrub_query_string(nil) == nil
  end
end
