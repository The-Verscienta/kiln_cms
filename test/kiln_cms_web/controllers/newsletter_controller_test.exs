defmodule KilnCMSWeb.NewsletterControllerTest do
  @moduledoc "Public newsletter confirm/unsubscribe endpoints (token-authorized)."
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Newsletter

  defp subscriber do
    Newsletter.subscribe!(
      %{email: "ctrl-#{System.unique_integer([:positive])}@example.com"},
      authorize?: false
    )
  end

  defp reload(sub), do: Newsletter.get_subscriber!(sub.id, authorize?: false)

  test "GET confirm with a valid token confirms the subscriber", %{conn: conn} do
    sub = subscriber()
    assert sub.status == :pending

    conn = get(conn, ~p"/newsletter/confirm/#{sub.confirm_token}")
    assert html_response(conn, 200) =~ "confirmed"
    assert reload(sub).status == :confirmed
  end

  test "GET unsubscribe renders a confirmation page WITHOUT unsubscribing", %{conn: conn} do
    sub = subscriber()

    conn = get(conn, ~p"/newsletter/unsubscribe/#{sub.unsubscribe_token}")
    # A one-button POST form — a GET (e.g. a link prefetcher) must not mutate.
    assert html_response(conn, 200) =~ "unsubscribe"
    assert html_response(conn, 200) =~ "<form method=\"post\""
    assert reload(sub).status == :pending
  end

  test "POST unsubscribe (one-click) unsubscribes", %{conn: conn} do
    sub = subscriber()

    conn = post(conn, ~p"/newsletter/unsubscribe/#{sub.unsubscribe_token}")
    assert html_response(conn, 200) =~ "unsubscribed"
    assert reload(sub).status == :unsubscribed
  end

  test "an unrecognized token renders a friendly page without erroring", %{conn: conn} do
    conn = get(conn, ~p"/newsletter/unsubscribe/nope-not-a-real-token")
    assert html_response(conn, 200) =~ "not recognized"
  end
end
