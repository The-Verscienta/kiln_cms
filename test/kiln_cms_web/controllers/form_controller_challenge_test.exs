defmodule KilnCMSWeb.FormControllerChallengeTest do
  @moduledoc """
  Human verification on the public form endpoints (#2249): the widget and the
  Content-Security-Policy on the pages that draw it, what each answer does to
  a browser and a JSON submission, and the headless schema.

  `async: false`: `KilnCMS.ChallengeFixtures.enable!/1` writes application env
  and an OS variable, both node-wide.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import KilnCMS.ChallengeFixtures

  alias KilnCMS.CMS
  alias KilnCMS.FormFixtures

  @provider "https://challenge.test"

  setup do
    enable!()
    %{form: FormFixtures.form!(%{challenge: :always}), plain: FormFixtures.form!()}
  end

  defp csp(conn), do: conn |> get_resp_header("content-security-policy") |> List.first()

  # The browser policy carries a per-request nonce; everything else must match.
  defp without_nonce(policy), do: String.replace(policy, ~r/'nonce-[^']+'/, "'nonce'")

  defp submissions(form), do: CMS.recent_form_submissions!(form.id, authorize?: false)

  defp post_form(conn, form, params),
    do: conn |> unique_ip() |> post("/forms/#{form.slug}", params)

  defp post_json(conn, form, params),
    do: conn |> unique_ip() |> post("/api/forms/#{form.slug}", params)

  describe "the form's own page (GET /forms/:slug)" do
    test "draws the widget and lets the provider in", %{conn: conn, form: form} do
      conn = conn |> unique_ip() |> get("/forms/#{form.slug}")
      html = html_response(conn, 200)

      assert html =~ "data-kiln-challenge"
      assert html =~ ~s(data-sitekey="test-site-key")
      assert html =~ ~s(data-action="form")
      assert html =~ ~s(name="_kiln_challenge")
      # How to call the provider's script comes from the provider (#2249).
      assert html =~ ~s(data-global="kilnFakeChallenge")
      assert html =~ ~s(data-render-options="{&quot;response-field&quot;:false}")
      assert html =~ ~s(data-action-option="action")
      assert html =~ ~s(data-onload-param="")
      assert html =~ ~s(data-interactive="false")
      # On the site's own pages app.js mounts it; no extra script.
      refute html =~ "challenge_static.js"

      assert csp(conn) =~ "script-src 'self' 'nonce-"
      assert csp(conn) =~ @provider
    end

    test "a form left :off renders and is served exactly as before", %{conn: conn, plain: plain} do
      on = conn |> unique_ip() |> get("/forms/#{plain.slug}")
      refute html_response(on, 200) =~ "data-kiln-challenge"

      enable!(disabled: true)
      off = build_conn() |> unique_ip() |> get("/forms/#{plain.slug}")

      assert without_nonce(csp(on)) == without_nonce(csp(off))
      refute csp(on) =~ @provider
    end

    test "nothing is drawn while the operator has forms off", %{conn: conn, form: form} do
      enable!(forms: false)
      conn = conn |> unique_ip() |> get("/forms/#{form.slug}")

      refute html_response(conn, 200) =~ "data-kiln-challenge"
      refute csp(conn) =~ @provider
    end
  end

  describe "a browser submission (POST /forms/:slug)" do
    test "a passing token is thanked and stored as verified", %{conn: conn, form: form} do
      conn = post_form(conn, form, %{"email" => "a@b.co", "_kiln_challenge" => "pass"})

      assert html_response(conn, 200) =~ "Merci!"
      assert [%{challenge: :passed, status: :new}] = submissions(form)
    end

    test "the provider's own field name works too", %{conn: conn, form: form} do
      conn = post_form(conn, form, %{"email" => "a@b.co", "cf-turnstile-response" => "pass"})

      assert html_response(conn, 200) =~ "Merci!"
      assert [%{challenge: :passed}] = submissions(form)
    end

    test "a refused token gets the form back, values kept, with a fresh widget",
         %{conn: conn, form: form} do
      conn = post_form(conn, form, %{"email" => "a@b.co", "_kiln_challenge" => "fail"})
      html = html_response(conn, 422)

      assert html =~ "The human-verification check didn&#39;t pass"
      assert html =~ ~s(value="a@b.co")
      assert html =~ "data-kiln-challenge"
      # The spent token is never echoed back.
      refute html =~ ~s(value="fail")
      assert csp(conn) =~ @provider
      assert submissions(form) == []
    end

    test "a field error on a form that asks keeps the provider in the policy",
         %{conn: conn, form: form} do
      conn = post_form(conn, form, %{"email" => "nope", "_kiln_challenge" => "pass"})

      assert html_response(conn, 422) =~ "data-kiln-challenge"
      assert csp(conn) =~ @provider
      refute_received {:challenge_verify, _, _}
    end

    test "a field error on a form left :off keeps the strict policy", %{conn: conn, plain: plain} do
      conn = post_form(conn, plain, %{"email" => "nope"})

      assert html_response(conn, 422)
      refute csp(conn) =~ @provider
    end

    test "no token is thanked, and held for review", %{conn: conn, form: form} do
      conn = post_form(conn, form, %{"email" => "a@b.co"})

      assert html_response(conn, 200) =~ "Merci!"
      assert [%{challenge: :missing, status: :spam}] = submissions(form)
    end

    test "a provider that cannot answer is thanked, and held", %{conn: conn, form: form} do
      conn = post_form(conn, form, %{"email" => "a@b.co", "_kiln_challenge" => "down"})

      assert html_response(conn, 200) =~ "Merci!"
      assert [%{challenge: :unavailable, status: :spam}] = submissions(form)
    end

    test "the honeypot is thanked and never verified", %{conn: conn, form: form} do
      conn =
        post_form(conn, form, %{
          "email" => "a@b.co",
          "website" => "bot",
          "_kiln_challenge" => "pass"
        })

      assert html_response(conn, 200) =~ "Merci!"
      refute_received {:challenge_verify, _, _}
      assert submissions(form) == []
    end
  end

  describe "with reCAPTCHA (#2249)" do
    setup do
      enable!(provider: "recaptcha")
      test = self()

      Req.Test.stub(KilnCMS.Challenge, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:siteverify, conn.host, conn.request_path, URI.decode_query(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"success": true, "hostname": "localhost"}))
      end)

      :ok
    end

    test "the page draws reCAPTCHA's widget and admits only its origins", %{
      conn: conn,
      form: form
    } do
      conn = conn |> unique_ip() |> get("/forms/#{form.slug}")
      html = html_response(conn, 200)

      assert html =~ ~s(data-global="grecaptcha")
      assert html =~ ~s(data-onload-param="onload")
      assert html =~ ~s(data-interactive="true")
      assert html =~ "Complete the check above, then send again."

      assert csp(conn) =~
               "https://www.recaptcha.net/recaptcha/ https://www.gstatic.com/recaptcha/"

      refute csp(conn) =~ "www.google.com"
      refute csp(conn) =~ @provider
    end

    test "the embed admits the same origins", %{conn: conn, form: form} do
      conn = conn |> unique_ip() |> get("/forms/#{form.slug}/embed")

      assert csp(conn) =~
               "script-src 'self' https://www.recaptcha.net/recaptcha/ https://www.gstatic.com/recaptcha/;"

      assert csp(conn) =~ "frame-src 'self' https://www.recaptcha.net/recaptcha/;"
      refute csp(conn) =~ "www.google.com"
    end

    test "the token reCAPTCHA posts is verified at recaptcha.net and never stored",
         %{conn: conn, form: form} do
      conn = post_form(conn, form, %{"email" => "a@b.co", "g-recaptcha-response" => "rc-token"})

      assert html_response(conn, 200) =~ "Merci!"
      assert [%{challenge: :passed, data: data}] = submissions(form)
      refute Map.has_key?(data, "g-recaptcha-response")

      assert_received {:siteverify, "www.recaptcha.net", "/recaptcha/api/siteverify",
                       %{"response" => "rc-token"}}
    end
  end

  describe "the embed" do
    test "draws the widget with its own mount script and widens only its policy",
         %{conn: conn, form: form} do
      conn = conn |> unique_ip() |> get("/forms/#{form.slug}/embed")
      html = html_response(conn, 200)

      assert html =~ "data-kiln-challenge"
      assert html =~ ~s(<script type="module" src="/assets/js/challenge_static.js)
      assert csp(conn) =~ "script-src 'self' #{@provider};"
      assert csp(conn) =~ "frame-src 'self' #{@provider};"
    end

    test "a form left :off keeps its policy byte for byte", %{conn: conn, plain: plain} do
      on = conn |> unique_ip() |> get("/forms/#{plain.slug}/embed")
      refute html_response(on, 200) =~ "data-kiln-challenge"

      enable!(disabled: true)
      off = build_conn() |> unique_ip() |> get("/forms/#{plain.slug}/embed")

      assert csp(on) == csp(off)
      refute csp(on) =~ "frame-src"
    end

    test "the thank-you page and a refused re-render keep the form's widened policy",
         %{conn: conn, form: form} do
      thanks =
        post_form(conn, form, %{
          "email" => "a@b.co",
          "_kiln_embed" => "1",
          "_kiln_challenge" => "pass"
        })

      assert html_response(thanks, 200) =~ "Merci!"
      assert csp(thanks) =~ "frame-src 'self' #{@provider};"

      refused =
        post_form(build_conn(), form, %{
          "email" => "a@b.co",
          "_kiln_embed" => "1",
          "_kiln_challenge" => "fail"
        })

      assert html_response(refused, 422) =~ "challenge_static.js"
      assert csp(refused) =~ "frame-src 'self' #{@provider};"
    end
  end

  describe "Embed.content_security_policy/2" do
    test "with no sources it is the policy it always was" do
      form = %{embed_origins: ["https://a.test"]}

      assert KilnCMSWeb.Embed.content_security_policy(form, %{}) ==
               KilnCMSWeb.Embed.content_security_policy(form)

      refute KilnCMSWeb.Embed.content_security_policy(form) =~ "frame-src"
    end

    test "with sources it adds them, and an explicit frame-src" do
      policy =
        KilnCMSWeb.Embed.content_security_policy(%{embed_origins: []}, %{
          script_src: [@provider],
          frame_src: [@provider],
          connect_src: ["https://api.challenge.test"]
        })

      assert policy =~ "script-src 'self' #{@provider};"
      assert policy =~ "connect-src 'self' https://api.challenge.test;"
      assert policy =~ "frame-src 'self' #{@provider};"
      assert String.ends_with?(policy, "frame-ancestors 'self'")
    end
  end

  describe "the headless schema (GET /api/forms/:slug)" do
    test "describes the check a form asks for", %{conn: conn, form: form} do
      body = conn |> get("/api/forms/#{form.slug}") |> json_response(200)

      assert body["challenge"] == %{
               "required" => true,
               "provider" => "fake",
               "site_key" => "test-site-key",
               "script_url" => "https://challenge.test/api.js?render=explicit",
               "action" => "form",
               "field" => "_kiln_challenge",
               "without_token" => "held",
               # What to call the script with (#2249), so a headless front end
               # can draw any provider's widget, not only Turnstile's.
               "global" => "kilnFakeChallenge",
               "onload_param" => nil,
               "render_options" => %{"response-field" => false},
               "action_option" => "action",
               "interactive" => false,
               "api" => "explicit_render"
             }
    end

    test "is null for a form that asks for none, the rest unchanged", %{conn: conn, plain: plain} do
      body = conn |> get("/api/forms/#{plain.slug}") |> json_response(200)

      assert Map.fetch!(body, "challenge") == nil

      assert Map.keys(body) |> Enum.sort() ==
               ~w(challenge description fields honeypot_field name slug submit_label submit_url success_message)
    end

    test "is null for every form while the operator has forms off", %{conn: conn, form: form} do
      enable!(forms: false)

      assert conn |> get("/api/forms/#{form.slug}") |> json_response(200) |> Map.get("challenge") ==
               nil
    end
  end

  describe "a JSON submission (POST /api/forms/:slug)" do
    test "verified", %{conn: conn, form: form} do
      body =
        conn
        |> post_json(form, %{"email" => "a@b.co", "_kiln_challenge" => "pass"})
        |> json_response(200)

      assert body == %{"ok" => true, "message" => "Merci!", "challenge" => "verified"}
    end

    test "held without a token, on another host, or when the provider is down",
         %{conn: conn, form: form} do
      for extra <- [%{}, %{"_kiln_challenge" => "wrong-host"}, %{"_kiln_challenge" => "down"}] do
        body =
          conn
          |> post_json(form, Map.put(extra, "email", "a@b.co"))
          |> json_response(200)

        assert body == %{"ok" => true, "message" => "Merci!", "challenge" => "held"}
      end

      assert Enum.all?(submissions(form), &(&1.status == :spam))
    end

    test "failed is a 422 naming the token", %{conn: conn, form: form} do
      body =
        conn
        |> post_json(form, %{"email" => "a@b.co", "_kiln_challenge" => "fail"})
        |> json_response(422)

      assert body == %{
               "ok" => false,
               "errors" => %{"_kiln_challenge" => "did not pass the human-verification check"},
               "challenge" => "failed"
             }
    end

    test "a form left :off answers exactly as before", %{conn: conn, plain: plain} do
      body =
        conn
        |> post_json(plain, %{"email" => "a@b.co", "_kiln_challenge" => "fail"})
        |> json_response(200)

      assert body == %{"ok" => true, "message" => "Merci!"}
      refute_received {:challenge_verify, _, _}
    end

    test "a tripped honeypot answers in the real shape, and is never verified",
         %{conn: conn, form: form} do
      with_token =
        conn
        |> post_json(form, %{"email" => "a@b.co", "website" => "x", "_kiln_challenge" => "fail"})
        |> json_response(200)

      without =
        conn
        |> post_json(form, %{"email" => "a@b.co", "website" => "x"})
        |> json_response(200)

      assert with_token["challenge"] == "verified"
      assert without["challenge"] == "held"
      refute_received {:challenge_verify, _, _}
      assert submissions(form) == []
    end

    test "a headless site's own host is held until the operator lists it",
         %{conn: conn, form: form} do
      params = %{"email" => "a@b.co", "_kiln_challenge" => "host:www.headless.example"}

      assert %{"challenge" => "held"} = conn |> post_json(form, params) |> json_response(200)

      enable!(hostnames: ["www.headless.example"])

      assert %{"challenge" => "verified"} =
               build_conn() |> post_json(form, params) |> json_response(200)
    end

    test "the provider's own field name works too", %{conn: conn, form: form} do
      assert %{"challenge" => "verified"} =
               conn
               |> post_json(form, %{"email" => "a@b.co", "cf-turnstile-response" => "pass"})
               |> json_response(200)
    end
  end
end
