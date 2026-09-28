defmodule KilnCMSWeb.NewsletterControllerTest do
  @moduledoc "Public newsletter subscribe/confirm/unsubscribe endpoints."
  use KilnCMSWeb.ConnCase, async: true

  require Ash.Query

  alias KilnCMS.Newsletter

  defp subscriber do
    Newsletter.subscribe!(
      %{email: "ctrl-#{System.unique_integer([:positive])}@example.com"},
      authorize?: false
    )
  end

  defp reload(sub), do: Newsletter.get_subscriber!(sub.id, authorize?: false)

  describe "confirm (#1664)" do
    # The emailed link is a GET, and mail scanners / link prefetchers follow it
    # before (or without) the reader. It must render a button and change nothing.
    test "GET renders a one-button page WITHOUT confirming", %{conn: conn} do
      sub = subscriber()
      assert sub.status == :pending

      html = conn |> get(~p"/newsletter/confirm/#{sub.confirm_token}") |> html_response(200)

      assert html =~ "Confirm your subscription"
      assert html =~ to_string(sub.email)
      # The button posts back to the same token, with the session's CSRF token.
      assert html =~ ~s(action="/newsletter/confirm/#{sub.confirm_token}")
      assert html =~ ~s(method="post")
      assert html =~ ~s(name="_csrf_token")
      refute html =~ "Subscription confirmed"

      assert reload(sub).status == :pending
    end

    test "repeated GETs (a scanner re-fetching) never confirm", %{conn: conn} do
      sub = subscriber()

      for _ <- 1..3, do: get(conn, ~p"/newsletter/confirm/#{sub.confirm_token}")

      assert reload(sub).status == :pending
    end

    test "POST confirms the subscriber", %{conn: conn} do
      sub = subscriber()

      conn = post(conn, ~p"/newsletter/confirm/#{sub.confirm_token}")

      assert html_response(conn, 200) =~ "Subscription confirmed"
      assert reload(sub).status == :confirmed
    end

    test "a GET of an already-confirmed link says so, with no button", %{conn: conn} do
      sub = subscriber()
      {:ok, _} = Newsletter.confirm_subscriber(sub, authorize?: false)

      html = conn |> get(~p"/newsletter/confirm/#{sub.confirm_token}") |> html_response(200)

      assert html =~ "Subscription confirmed"
      refute html =~ ~s(action="/newsletter/confirm/)
    end

    test "an unrecognized token is refused on both verbs, changing nothing", %{conn: conn} do
      get_html = conn |> get(~p"/newsletter/confirm/nope-not-a-real-token") |> html_response(200)
      assert get_html =~ "not recognized"
      assert get_html =~ "invalid or expired"
      refute get_html =~ ~s(method="post")

      post_html =
        conn |> post(~p"/newsletter/confirm/nope-not-a-real-token") |> html_response(200)

      assert post_html =~ "not recognized"
    end
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

  describe "POST /newsletter/subscribe (#586)" do
    defp address, do: "signup-#{System.unique_integer([:positive])}@example.com"

    defp find(email) do
      KilnCMS.Newsletter.Subscriber
      |> Ash.Query.filter(email == ^email)
      |> Ash.read!(authorize?: false)
      |> List.first()
    end

    test "signing up creates a PENDING subscriber and says to check the inbox", %{conn: conn} do
      email = address()

      conn = post(conn, ~p"/newsletter/subscribe", %{"email" => email, "name" => "Reader"})

      assert html_response(conn, 200) =~ "Check your inbox"
      subscriber = find(email)
      assert subscriber.status == :pending
      assert subscriber.name == "Reader"
    end

    test "a leading/trailing space in the address doesn't reject a real sign-up", %{conn: conn} do
      email = address()

      conn = post(conn, ~p"/newsletter/subscribe", %{"email" => "  #{email} "})

      assert html_response(conn, 200) =~ "Check your inbox"
      assert find(email).status == :pending
    end

    test "an already-subscribed address gets the SAME page (no enumeration)", %{conn: conn} do
      # The response must not reveal whether this address already subscribes to
      # the site — that's the reason every outcome shares one page.
      sub = subscriber()
      {:ok, _} = Newsletter.confirm_subscriber(sub, authorize?: false)

      conn = post(conn, ~p"/newsletter/subscribe", %{"email" => to_string(sub.email)})

      assert html_response(conn, 200) =~ "Check your inbox"
      # ...and it is emphatically not a way to reset someone's consent.
      assert reload(sub).status == :confirmed
    end

    test "an unsubscribed address is not resurrected", %{conn: conn} do
      sub = subscriber()
      {:ok, _} = Newsletter.unsubscribe_subscriber(sub, authorize?: false)

      conn = post(conn, ~p"/newsletter/subscribe", %{"email" => to_string(sub.email)})

      assert html_response(conn, 200) =~ "Check your inbox"
      assert reload(sub).status == :unsubscribed
    end

    test "the honeypot reports fake success and stores nothing", %{conn: conn} do
      email = address()

      conn =
        post(conn, ~p"/newsletter/subscribe", %{
          "email" => email,
          KilnCMS.Forms.honeypot_field() => "http://spam.example"
        })

      assert html_response(conn, 200) =~ "Check your inbox"
      refute find(email)
    end

    # The same predicate as public forms (`KilnCMS.Forms.honeypot_tripped?/1`):
    # a whitespace-only or non-string value is a bot too (#1657).
    for {label, value} <- [
          {"whitespace-only", "   "},
          {"list", ["http://spam.example"]},
          {"map", %{"a" => "b"}}
        ] do
      test "a #{label} honeypot value also reports fake success and stores nothing",
           %{conn: conn} do
        email = address()

        conn =
          post(conn, ~p"/newsletter/subscribe", %{
            "email" => email,
            KilnCMS.Forms.honeypot_field() => unquote(Macro.escape(value))
          })

        assert html_response(conn, 200) =~ "Check your inbox"
        refute find(email)
      end
    end

    test "an empty honeypot (an untouched input) still subscribes", %{conn: conn} do
      email = address()

      conn =
        post(conn, ~p"/newsletter/subscribe", %{
          "email" => email,
          KilnCMS.Forms.honeypot_field() => ""
        })

      assert html_response(conn, 200) =~ "Check your inbox"
      assert find(email).status == :pending
    end

    test "a malformed address is rejected without a 500", %{conn: conn} do
      # `Mail.enqueue!/1` raises on a bad recipient; the resource validation is
      # what keeps that from escaping this anonymous endpoint as a crash.
      conn = post(conn, ~p"/newsletter/subscribe", %{"email" => "not-an-address"})

      assert html_response(conn, 200) =~ "doesn&#39;t look like an email address"
    end

    test "a missing address is rejected", %{conn: conn} do
      conn = post(conn, ~p"/newsletter/subscribe", %{})

      assert html_response(conn, 200) =~ "doesn&#39;t look like an email address"
    end

    test "there is no GET sign-up — a prefetcher must not be able to mail anyone" do
      refute Enum.any?(
               Phoenix.Router.routes(KilnCMSWeb.Router),
               &(&1.path == "/newsletter/subscribe" and &1.verb != :post)
             )
    end
  end
end
