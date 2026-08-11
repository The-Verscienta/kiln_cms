defmodule KilnCMSWeb.FormEmbedDefaultTest do
  @moduledoc """
  The **shipped** framing default for embeddable forms (#562), exercised through
  the real request pipeline.

  `config/test.exs` pins `:embed_origins` to an allowlist so the rest of the
  suite asserts a configured policy deterministically — which leaves the one
  thing #562 is about, the `Application.get_env/3` fallback taken when
  `EMBED_ORIGINS` is unset, covered by nothing. Reverting
  `KilnCMSWeb.Embed`'s default to `:all` would then serve `frame-ancestors *` to
  the whole internet again with a green suite.

  So this module clears the key instead of passing a setting as an argument, and
  asserts on the header the controller actually puts. It is `async: false`
  because `Application.delete_env/2` is global — the repo's established shape for
  config-dependent tests (see `test/kiln_cms/unsplash_test.exs`).
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.CMS
  alias KilnCMSWeb.Embed

  setup do
    previous = Application.get_env(:kiln_cms, :embed_origins)
    Application.delete_env(:kiln_cms, :embed_origins)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:kiln_cms, :embed_origins)
        value -> Application.put_env(:kiln_cms, :embed_origins, value)
      end
    end)

    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fed-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp form! do
    actor = admin()

    form =
      CMS.create_form!(
        %{
          name: "Contact us",
          slug: "fed-#{System.unique_integer([:positive])}",
          success_message: "Merci!",
          active: true
        },
        actor: actor
      )

    CMS.create_form_field!(
      %{form_id: form.id, name: "email", label: "Email", field_type: :email, required: true},
      actor: actor
    )

    form
  end

  defp csp(conn), do: conn |> get_resp_header("content-security-policy") |> List.first()

  test "with EMBED_ORIGINS unset the embed page is same-origin only", %{conn: conn} do
    form = form!()
    conn = conn |> unique_ip() |> get("/forms/#{form.slug}/embed")

    assert html_response(conn, 200) =~ "Contact us"
    assert String.ends_with?(csp(conn), "frame-ancestors 'self'")
    refute csp(conn) =~ "frame-ancestors *"
  end

  test "the embedded thank-you page is same-origin only too", %{conn: conn} do
    form = form!()

    conn =
      conn
      |> unique_ip()
      |> post("/forms/#{form.slug}", %{"email" => "a@b.com", "_kiln_embed" => "1"})

    assert html_response(conn, 200) =~ "Merci!"
    assert String.ends_with?(csp(conn), "frame-ancestors 'self'")
  end

  test "the framable 404 is same-origin only too", %{conn: conn} do
    conn = conn |> unique_ip() |> get("/forms/does-not-exist/embed")

    assert html_response(conn, 404) =~ "Form not found"
    assert String.ends_with?(csp(conn), "frame-ancestors 'self'")
  end

  test "the module reports embedding as closed", %{conn: _conn} do
    assert Embed.frame_ancestors_for(nil) == "'self'"
    refute Embed.cross_site?(nil)
    assert Embed.allowed_origins_label(nil) == nil
  end

  # #650. The flip to same-origin-only in #562 is silent for anyone who was
  # relying on the old open default: the CMS logs a healthy 200 and the browser
  # discards the response. The request itself carries the evidence, so the
  # server can say so once.
  #
  # Here rather than in `form_embed_test.exs` for the reason this module exists
  # at all: the warning is about the SHIPPED closed default, which is exactly
  # the state this file clears the config to reach — and doing that needs
  # `async: false`, because `Application.delete_env/2` is global.
  describe "the blocked-framing warning" do
    setup do
      # The module setup has already cleared `:embed_origins`, so the policy is
      # the shipped closed default here. Only the one-shot needs arming.
      Embed.reset_framing_warning()
      on_exit(&Embed.reset_framing_warning/0)
      :ok
    end

    defp framed(conn, site, opts \\ []) do
      conn
      |> unique_ip()
      |> put_req_header("sec-fetch-dest", Keyword.get(opts, :dest, "iframe"))
      |> put_req_header("sec-fetch-site", site)
      |> then(fn c ->
        case Keyword.get(opts, :referer) do
          nil -> c
          referer -> put_req_header(c, "referer", referer)
        end
      end)
    end

    test "names the variable and the parent origin, once", %{conn: conn} do
      form = form!()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn
          |> framed("cross-site", referer: "https://acme.test/pricing?utm=x")
          |> get(~p"/forms/#{form.slug}/embed")
          |> response(200)
        end)

      assert log =~ "EMBED_ORIGINS"
      # The parent, from the Referer — an origin, not the full URL.
      assert log =~ "https://acme.test"
      refute log =~ "/pricing"
      # And which form, since #648 made the policy per form: an operator with a
      # dozen of them needs to know which Embed tab to open.
      assert log =~ form.slug

      # At most hourly per node: a busy embed route must not flood the log.
      second =
        ExUnit.CaptureLog.capture_log(fn ->
          build_conn()
          |> framed("cross-site", referer: "https://acme.test/")
          |> get(~p"/forms/#{form.slug}/embed")
          |> response(200)
        end)

      refute second =~ "EMBED_ORIGINS"
    end

    # Per form since #648, because the policy is. A node-wide claim would let
    # the first blocked form silence every other one for an hour — including
    # forms closed for a different reason and needing a different fix — and a
    # `curl` at a slug that matches nothing would silence all of them.
    test "one form's warning does not mute another form's", %{conn: conn} do
      first = form!()
      second = form!()

      ExUnit.CaptureLog.capture_log(fn ->
        conn |> framed("cross-site") |> get(~p"/forms/#{first.slug}/embed") |> response(200)
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          build_conn()
          |> framed("cross-site")
          |> get(~p"/forms/#{second.slug}/embed")
          |> response(200)
        end)

      assert log =~ second.slug
      refute log =~ first.slug
    end

    test "a probe at a slug that matches no form mutes only itself", %{conn: conn} do
      form = form!()

      ExUnit.CaptureLog.capture_log(fn ->
        conn |> framed("cross-site") |> get(~p"/forms/no-such-form/embed") |> response(404)
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          build_conn()
          |> framed("cross-site")
          |> get(~p"/forms/#{form.slug}/embed")
          |> response(200)
        end)

      assert log =~ form.slug
    end

    # A scanner can set Fetch Metadata by hand — the headers are unforgeable to a
    # *page*, not to `curl`. A one-shot per node would let one probe claim the
    # slot and leave the operator's own broken embed silent until the next
    # deploy, which inverts what the warning is for.
    test "a spoofed probe cannot mute the warning for good", %{conn: conn} do
      form = form!()

      probe =
        ExUnit.CaptureLog.capture_log(fn ->
          conn |> framed("cross-site") |> get(~p"/forms/#{form.slug}/embed") |> response(200)
        end)

      assert probe =~ "EMBED_ORIGINS"

      # An hour later, by the clock the claim actually reads. Reaching into the
      # persistent_term is the point: it asserts the re-arm is time-based rather
      # than testing a helper that fakes the answer.
      :persistent_term.put(
        {KilnCMSWeb.Embed, :framing_warned_at, form.id},
        System.monotonic_time() - System.convert_time_unit(3601, :second, :native)
      )

      operator =
        ExUnit.CaptureLog.capture_log(fn ->
          build_conn()
          |> framed("cross-site", referer: "https://acme.test/")
          |> get(~p"/forms/#{form.slug}/embed")
          |> response(200)
        end)

      assert operator =~ "EMBED_ORIGINS"
    end

    # `frame-ancestors` governs all four embedding destinations identically, and
    # an operator who reached for `<object>` rather than `<iframe>` is exactly
    # the one who will not guess why the form is blank.
    for dest <- ~w(frame embed object) do
      test "a #{dest} destination warns like an iframe", %{conn: conn} do
        form = form!()

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            conn
            |> framed("cross-site", dest: unquote(dest))
            |> get(~p"/forms/#{form.slug}/embed")
            |> response(200)
          end)

        assert log =~ "EMBED_ORIGINS"
      end
    end

    # `Referer` is attacker-controlled and this line goes into an operator's
    # terminal. `URI.parse/1` will hand back a host containing ESC quite
    # happily; Bandit's HTTP/1 parser rejects CR/LF/NUL, but that is one
    # transport's parser rather than a property of the value.
    test "a referer carrying terminal escapes is dropped, not logged", %{conn: conn} do
      form = form!()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn
          |> framed("cross-site", referer: "https://acme.test\e[2J\e[31mINJECTED")
          |> get(~p"/forms/#{form.slug}/embed")
          |> response(200)
        end)

      # Still warns — the missing origin must not cost the operator the signal.
      assert log =~ "EMBED_ORIGINS"
      assert log =~ "framed by another site"
      refute log =~ "INJECTED"
    end

    test "an absurdly long referer host is dropped", %{conn: conn} do
      form = form!()
      host = String.duplicate("a", 300)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn
          |> framed("cross-site", referer: "https://#{host}.test/")
          |> get(~p"/forms/#{form.slug}/embed")
          |> response(200)
        end)

      assert log =~ "framed by another site"
      refute log =~ host
    end

    # `https:///path` parses to a host of `""`, which is not a usable origin and
    # reads worse in the message than saying nothing.
    test "a hostless referer falls back to the generic wording", %{conn: conn} do
      form = form!()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn
          |> framed("cross-site", referer: "https:///path")
          |> get(~p"/forms/#{form.slug}/embed")
          |> response(200)
        end)

      assert log =~ "framed by another site"
    end

    # `frame-ancestors 'self'` matches the ORIGIN, so a sibling subdomain is
    # refused exactly like an unrelated host — and it is the likeliest first
    # thing an operator tries.
    test "a same-site parent is blocked too, and warns", %{conn: conn} do
      form = form!()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn |> framed("same-site") |> get(~p"/forms/#{form.slug}/embed") |> response(200)
        end)

      assert log =~ "EMBED_ORIGINS"
    end

    test "stays quiet for same-origin framing and for an unframed request", %{conn: conn} do
      form = form!()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn |> framed("same-origin") |> get(~p"/forms/#{form.slug}/embed") |> response(200)

          # No Fetch Metadata at all — an old browser or a server-side fetch
          # tells us nothing, so it must not guess.
          build_conn() |> unique_ip() |> get(~p"/forms/#{form.slug}/embed") |> response(200)
        end)

      refute log =~ "EMBED_ORIGINS"
    end

    test "stays quiet once EMBED_ORIGINS is set", %{conn: conn} do
      form = form!()
      Application.put_env(:kiln_cms, :embed_origins, ["https://acme.test"])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn
          |> framed("cross-site", referer: "https://acme.test/")
          |> get(~p"/forms/#{form.slug}/embed")
          |> response(200)
        end)

      refute log =~ "EMBED_ORIGINS"
    end
  end
end
