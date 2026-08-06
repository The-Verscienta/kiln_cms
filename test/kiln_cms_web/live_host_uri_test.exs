defmodule KilnCMSWeb.LiveHostUriTest do
  @moduledoc """
  `socket.host_uri` is server-vouched after mount, and no `handle_params/3`
  derives anything from the client's patch URL (#687).

  #685 pinned the *tenant* a connected LiveView resolves, but that guarantee
  was about `:current_org` and stopped at mount. Two client-controlled values
  outlived it:

    * `socket.host_uri` keeps the client's **scheme and port** — the claim is
      refused only when it names a different org, and nothing judges `http://`
      or `:1337`. `Phoenix.VerifiedRoutes.url/1` inside a LiveView reads it, as
      does LiveView's own redirect building.
    * `handle_params/3`'s `uri` is the `live_patch` payload outright.
      `Route.live_link_info!/3` checks the view module and the live_session
      name, and **not the host**.

  Neither was live when #687 was filed. These tests are what make the fix hold
  for readers that do not exist yet, which is the whole point — the bug would
  otherwise return via a canonical-URL tag, an email link or an OAuth
  `redirect_uri`, with nothing failing.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMSWeb.LiveUserAuth

  describe "vouch_uri/2" do
    defp socket_on(host) do
      %Phoenix.LiveView.Socket{
        host_uri: %URI{scheme: "https", host: host, port: 443}
      }
    end

    test "keeps the path and query but re-roots the authority" do
      uri = LiveUserAuth.vouch_uri(socket_on("orga.example.com"), "https://evil.test/x/y?q=1")

      assert uri == "https://orga.example.com/x/y?q=1"
    end

    test "a patch naming another org's host cannot smuggle that host through" do
      # The exact shape from #687: same view, same live_session, different host.
      patched =
        LiveUserAuth.vouch_uri(
          socket_on("orga.example.com"),
          "https://orgb.example.com/editor/content/post/123"
        )

      assert URI.parse(patched).host == "orga.example.com"
      refute patched =~ "orgb"
    end

    test "the client's scheme and port are replaced, not just its host" do
      # These are never judged by the org check — two spellings of one org's
      # host both resolve to that org, and nothing looks at scheme or port at
      # all. So a legitimate join can carry `http://` and `:1337` forever.
      uri =
        LiveUserAuth.vouch_uri(socket_on("orga.example.com"), "http://orga.example.com:1337/p")

      assert uri == "https://orga.example.com/p"
    end

    test "a socket with no vouched authority passes the URI through unchanged" do
      # A `live_render/3` child, or any socket mounted without
      # `:assign_current_org`. Mangling the URL would be worse than passing it.
      socket = %Phoenix.LiveView.Socket{host_uri: :not_mounted_at_router}

      assert LiveUserAuth.vouch_uri(socket, "https://x.test/p") == "https://x.test/p"
    end
  end

  describe ":assign_current_org vouches host_uri" do
    setup do
      KilnCMS.Cache.Hosts.clear()
      on_exit(&KilnCMS.Cache.Hosts.clear/0)
      :ok
    end

    defp org(slug) do
      Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
        name: slug,
        slug: "#{slug}-#{System.unique_integer([:positive])}",
        status: :active
      })
    end

    defp host_for(o), do: "#{o.slug}.#{KilnCMSWeb.Tenant.base_host()}"

    # The socket state `Phoenix.LiveView.Channel` builds for a CONNECTED mount:
    # `host_uri` from the client's join payload, `connect_info` from the
    # transport (which the client cannot forge).
    defp connected_socket(connected_host, claimed_uri) do
      %Phoenix.LiveView.Socket{
        host_uri: claimed_uri,
        transport_pid: self(),
        private: %{connect_info: %{uri: URI.parse("https://#{connected_host}/x")}}
      }
    end

    defp mount(socket),
      do: LiveUserAuth.on_mount(:assign_current_org, %{}, %{}, socket)

    test "the client's scheme and port are replaced with the endpoint's" do
      o = org("vouch")
      host = host_for(o)

      # A legitimate join — same org — that nonetheless claims http and a
      # nonstandard port. The org check has no reason to refuse it, and before
      # #687 those two values survived into every URL the LiveView built.
      claimed = URI.parse("http://#{host}:1337/x")

      assert {:cont, socket} = mount(connected_socket(host, claimed))
      assert socket.assigns.current_org.id == o.id

      endpoint = KilnCMSWeb.Endpoint.struct_url()
      assert socket.host_uri.scheme == endpoint.scheme
      assert socket.host_uri.port == endpoint.port
      assert socket.host_uri.host == host
    end

    test "a socket that claimed no URL keeps the sentinel, not a fabricated URI" do
      # `KilnCMSWeb.LiveRouteGuard` matches `:not_mounted_at_router` exactly.
      # Replacing it with a URI here would silently disarm that guard.
      o = org("vouch-none")

      assert {:cont, socket} =
               mount(connected_socket(host_for(o), :not_mounted_at_router))

      assert socket.host_uri == :not_mounted_at_router
    end

    test "the vouched host is the CONNECTED host, not the claimed one" do
      # Two spellings of one org resolve to the same org, so this join is not
      # refused — but the URI that survives must still be the server's.
      o = org("vouch-alias")
      connected = host_for(o)
      claimed = URI.parse("https://#{String.upcase(connected)}/x")

      assert {:cont, socket} = mount(connected_socket(connected, claimed))
      assert socket.host_uri.host == connected
    end
  end

  describe "no handle_params/3 reads its uri argument" do
    # The inventory, not a sample: every LiveView module in the app. A new one
    # that binds `uri` to a used variable fails here, which is the prompt for a
    # reviewer to ask where that host came from.
    @live_dir "lib/kiln_cms_web/live"

    # `sign_in_live.ex` is the single reviewed exception: upstream's signature
    # takes a `uri`, so it cannot discard it, and it launders the value through
    # `LiveUserAuth.vouch_uri/2` before passing it on. Listed by name so that
    # adding a second one is a deliberate act.
    @vouched ["sign_in_live.ex"]

    test "every handle_params/3 either discards its uri or vouches it" do
      offenders =
        @live_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".ex"))
        |> Enum.reject(&(&1 in @vouched))
        |> Enum.filter(&reads_uri?(Path.join(@live_dir, &1)))

      assert offenders == [],
             """
             These LiveViews bind handle_params/3's `uri` to a used variable:

               #{Enum.join(offenders, "\n  ")}

             That argument is the URL the client put in its `live_patch` payload,
             and LiveView does not check its host (#687). Derive nothing from it
             — spell it `_uri`. If you genuinely must pass it on, launder it
             through `KilnCMSWeb.LiveUserAuth.vouch_uri/2` and add the file to
             @vouched above with a reason.
             """
    end

    # Walks the AST rather than matching source lines. A regex over `def
    # handle_params(...)` looked fine and had a hole big enough to drive the bug
    # back through: `[^,]+` for the first argument stops at the first comma, so
    # `def handle_params(%{"a" => a, "b" => b}, uri, socket)` — a pattern with
    # two keys — did not match and the file read as clean. The parser has no
    # such blind spot, and is immune to line breaks and formatting besides.
    defp reads_uri?(path) do
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalker()
      |> Enum.any?(fn
        {:def, _, [{:handle_params, _, [_params, uri, _socket]} | _]} -> used?(uri)
        # `def handle_params(a, b, c) when guard` puts the head under `:when`.
        {:def, _, [{:when, _, [{:handle_params, _, [_p, uri, _s]} | _]} | _]} -> used?(uri)
        _other -> false
      end)
    end

    # A bare `_` or an `_`-prefixed name is a discard; anything else — a plain
    # variable, or a pattern the argument is destructured by — is a read.
    defp used?({name, _meta, ctx}) when is_atom(name) and is_atom(ctx),
      do: not String.starts_with?(Atom.to_string(name), "_")

    defp used?(_pattern), do: true

    test "the detector actually fires — a bare uri is caught, a discarded one is not" do
      # Pinned adversarial cases. A guard test that cannot fail is worse than
      # no guard test: it reads as coverage while asserting nothing.
      in_tmp = fn source ->
        path = Path.join(System.tmp_dir!(), "hp_#{System.unique_integer([:positive])}.ex")
        File.write!(path, source)
        on_exit(fn -> File.rm(path) end)
        reads_uri?(path)
      end

      refute in_tmp.("defmodule A do\n def handle_params(p, _uri, s), do: {p, s}\nend")
      assert in_tmp.("defmodule A do\n def handle_params(p, uri, s), do: {p, uri, s}\nend")

      # The case the regex missed: a comma inside the first argument's pattern.
      assert in_tmp.(
               ~s|defmodule A do\n def handle_params(%{"a" => a, "b" => b}, uri, s), do: {a, b, uri, s}\nend|
             )

      # A multi-line head, which a line-oriented check also cannot see.
      assert in_tmp.(
               "defmodule A do\n def handle_params(\n p,\n uri,\n s\n ), do: {p, uri, s}\nend"
             )

      # `handle_params/2` and unrelated functions are not this test's business.
      refute in_tmp.("defmodule A do\n def handle_params(p, uri), do: {p, uri}\nend")
      refute in_tmp.("defmodule A do\n def other(p, uri, s), do: {p, uri, s}\nend")
    end

    test "the vouched exception still exists and still vouches" do
      # Guards the allowlist itself: if `sign_in_live.ex` stops calling
      # `vouch_uri/2`, the entry above silently becomes a hole.
      source = File.read!(Path.join(@live_dir, "sign_in_live.ex"))

      assert source =~ "vouch_uri(socket, uri)",
             "sign_in_live.ex is on the @vouched allowlist but no longer vouches its uri"
    end
  end
end
