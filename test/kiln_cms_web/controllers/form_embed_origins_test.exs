defmodule KilnCMSWeb.FormEmbedOriginsTest do
  @moduledoc """
  Per-form framing allowlists (#648).

  `EMBED_ORIGINS` has no tenant dimension, so on a multi-org deployment it is
  necessarily the union of every org's embedders — and that union is what every
  org's forms become framable by. `Form.embed_origins` is the per-form answer,
  and these tests are about the two things #648 asked for: an entry made for one
  org does not reach another org's forms, and the Embed tab's answer is the one
  actually served.

  `config/test.exs` pins `:embed_origins` to `["https://embedder.test"]`, which
  is what a form *without* its own list inherits — and, in the two-org test, the
  origin that must NOT appear once a form has one, since a form's list replaces
  the deployment's rather than extending it.
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.OrgFixtures
  import KilnCMS.FormFixtures, only: [admin: 0, form!: 1, form!: 2]

  alias KilnCMS.CMS
  alias KilnCMSWeb.Embed

  # `frame-ancestors` is the last directive emitted, so everything after it is
  # the whole source list. Compared with `==`, never `=~`: a substring assertion
  # passes just as happily on a policy that ALSO carries the other tenant's
  # origin, which is the exact defect this file exists to catch.
  defp frame_ancestors(conn) do
    [_head, sources] =
      conn
      |> get_resp_header("content-security-policy")
      |> List.first()
      |> String.split("frame-ancestors ")

    sources
  end

  describe "one org's allowlist does not reach another org's forms" do
    test "each form is framable only by the origins it names", %{conn: conn} do
      actor = admin()
      a = org("embed-a")
      b = org("embed-b")

      form_a =
        form!(%{embed_origins: ["https://partner-a.test"]}, actor: actor, tenant: a)

      form_b =
        form!(%{embed_origins: ["https://partner-b.test"]}, actor: actor, tenant: b)

      policy_a =
        conn
        |> unique_ip()
        |> org_conn(a)
        |> get("/forms/#{form_a.slug}/embed")
        |> frame_ancestors()

      policy_b =
        conn
        |> unique_ip()
        |> org_conn(b)
        |> get("/forms/#{form_b.slug}/embed")
        |> frame_ancestors()

      # The acceptance criterion of #648: A's partner authorises A's form and
      # nothing else. Under the deployment-global allowlist both of these would
      # have been `'self' https://partner-a.test https://partner-b.test`.
      assert policy_a == "'self' https://partner-a.test"
      assert policy_b == "'self' https://partner-b.test"

      # And a form's own list REPLACES the deployment's rather than extending
      # it — otherwise the shared union is still in the policy and an org that
      # narrows its own form cannot narrow it below what someone else needed.
      refute policy_a =~ "embedder.test"
      refute policy_b =~ "embedder.test"
    end

    # The honest half of the same story, pinned so nobody reads the test above
    # as more than it says. A form that has not been given a list inherits the
    # deployment's, and `EMBED_ORIGINS` has no tenant dimension — so on a
    # multi-org instance the union is still shared until each org sets its own.
    # That is what "the global variable stays the default for single-org
    # deployments" costs, and the docs say so rather than claiming otherwise.
    test "forms that set no list of their own still share the deployment's",
         %{conn: conn} do
      actor = admin()
      a = org("embed-inherit-a")
      b = org("embed-inherit-b")

      form_a = form!(%{}, actor: actor, tenant: a)
      form_b = form!(%{}, actor: actor, tenant: b)

      for {org, form} <- [{a, form_a}, {b, form_b}] do
        policy =
          conn
          |> unique_ip()
          |> org_conn(org)
          |> get("/forms/#{form.slug}/embed")
          |> frame_ancestors()

        assert policy == "'self' https://embedder.test"
      end
    end
  end

  describe "the three states of Form.embed_origins" do
    test "nil inherits the deployment's EMBED_ORIGINS", %{conn: conn} do
      form = form!(%{}, actor: admin())
      assert form.embed_origins == nil

      conn = conn |> unique_ip() |> get("/forms/#{form.slug}/embed")
      assert frame_ancestors(conn) == "'self' https://embedder.test"
    end

    test "an empty list closes this form even where the deployment is open", %{conn: conn} do
      form = form!(%{embed_origins: []}, actor: admin())

      conn = conn |> unique_ip() |> get("/forms/#{form.slug}/embed")

      # Not the inherited `'self' https://embedder.test`: `[]` is a decision,
      # and it has to be distinguishable from `nil`, which is the absence of one.
      assert frame_ancestors(conn) == "'self'"
    end

    test "a list is served instead of the deployment's, keeping 'self'", %{conn: conn} do
      form =
        form!(%{embed_origins: ["https://acme.test", "https://blog.acme.test"]}, actor: admin())

      conn = conn |> unique_ip() |> get("/forms/#{form.slug}/embed")

      assert frame_ancestors(conn) == "'self' https://acme.test https://blog.acme.test"
    end
  end

  describe "the whole embed round trip carries the form's policy" do
    test "the thank-you page is framable by the same parents as the form", %{conn: conn} do
      form = form!(%{embed_origins: ["https://acme.test"]}, actor: admin())

      conn =
        conn
        |> unique_ip()
        |> post("/forms/#{form.slug}", %{"email" => "a@b.com", "_kiln_embed" => "1"})

      assert html_response(conn, 200) =~ "Merci!"
      # A thank-you page under the deployment policy would render blank inside
      # an iframe the form itself was allowed to appear in.
      assert frame_ancestors(conn) == "'self' https://acme.test"
    end

    test "a rejected submission keeps the form's policy too", %{conn: conn} do
      form = form!(%{embed_origins: ["https://acme.test"]}, actor: admin())

      conn =
        conn
        |> unique_ip()
        |> post("/forms/#{form.slug}", %{"email" => "", "_kiln_embed" => "1"})

      assert html_response(conn, 422)
      assert frame_ancestors(conn) == "'self' https://acme.test"
    end

    test "an unknown slug falls back to the deployment policy", %{conn: conn} do
      conn = conn |> unique_ip() |> get("/forms/no-such-form-#{System.unique_integer()}/embed")

      assert html_response(conn, 404) =~ "Form not found"
      # There is no form to speak for, and answering with one would leak whether
      # the slug exists.
      assert frame_ancestors(conn) == "'self' https://embedder.test"
    end
  end

  describe "what an org admin may write" do
    setup do: %{actor: admin()}

    # The entries are concatenated into a response header, so a value that can
    # end the directive or name a keyword source is refused at the write — not
    # quietly dropped, and not left to close the policy at render time, which
    # would leave an admin looking at a saved allowlist that does nothing.
    test "refuses anything that is not a plain origin", %{actor: actor} do
      for bad <- [
            "*",
            # A wildcard over a public suffix is a bare `*` wearing a hat: CSP
            # applies no PSL rule, so this grants every .com site.
            "https://*.com",
            "'unsafe-inline'",
            "data:",
            "https://a.test; report-uri https://evil.test",
            "https://a.test https://evil.test",
            "https://a.test\nx-frame-options: allow",
            "acme.test",
            "javascript:alert(1)"
          ] do
        assert {:error, error} =
                 CMS.create_form(
                   %{
                     name: "Bad",
                     slug: "feo-bad-#{System.unique_integer([:positive])}",
                     embed_origins: [bad]
                   },
                   actor: actor
                 )

        message = Exception.message(error)

        assert message =~ "embed_origins",
               "#{inspect(bad)} was accepted as a frame-ancestors source"

        # And it names the entry it refused. `Splode` interpolates `vars` only
        # inside `Exception.message/1`, so a caller reading `.message` off the
        # struct gets the literal "%{value}" — an admin told a list of eight
        # origins is wrong, without being told which one.
        assert message =~ inspect(bad),
               "the error did not name the refused entry: #{message}"
      end
    end

    test "accepts an origin with a wildcard label, a port, and localhost", %{actor: actor} do
      form =
        form!(
          %{
            embed_origins: [
              "https://*.acme.test",
              "https://acme.test:8443",
              "http://localhost:4000"
            ]
          },
          actor: actor
        )

      assert form.embed_origins == [
               "https://*.acme.test",
               "https://acme.test:8443",
               "http://localhost:4000"
             ]

      # Everything the write accepts must also survive the render-time check, or
      # a saved allowlist silently closes the page it was meant to open.
      assert Embed.frame_ancestors_for(form) ==
               "'self' https://*.acme.test https://acme.test:8443 http://localhost:4000"
    end

    test "one bad entry rejects the whole write", %{actor: actor} do
      assert {:error, _error} =
               CMS.create_form(
                 %{
                   name: "Partly bad",
                   slug: "feo-partly-#{System.unique_integer([:positive])}",
                   embed_origins: ["https://ok.test", "*"]
                 },
                 actor: actor
               )
    end
  end

  describe "KilnCMSWeb.Embed, per form" do
    # `own_origins/1` is the only reader of the attribute's shape; everything
    # else asks it. A second reader is how three states become two.
    test "own_origins separates 'no list of its own' from 'an empty list'" do
      assert Embed.own_origins(%{embed_origins: ["https://a.test"]}) == ["https://a.test"]
      assert Embed.own_origins(%{embed_origins: []}) == []
      assert Embed.own_origins(%{embed_origins: nil}) == :deployment
      assert Embed.own_origins(nil) == :deployment
    end

    test "origins_for reads the form, then the deployment" do
      assert Embed.origins_for(%{embed_origins: ["https://a.test"]}) == ["https://a.test"]
      assert Embed.origins_for(%{embed_origins: []}) == []
      assert Embed.origins_for(%{embed_origins: nil}) == ["https://embedder.test"]
      assert Embed.origins_for(nil) == ["https://embedder.test"]
    end

    # The one shape that must not fall through to the deployment default. A form
    # read without this attribute selected would otherwise get the shared union
    # back — a widening, in the module whose whole job is not to widen.
    test "a form whose embed_origins was not selected is refused, not defaulted" do
      # A real projected read rather than a hand-built map, so this is the shape
      # a narrowed query actually produces — and so the type checker cannot see
      # a literal `%Ash.NotLoaded{}` and warn about the very call the test makes.
      form = form!(%{embed_origins: []}, actor: admin())

      narrowed =
        KilnCMS.CMS.Form
        |> Ash.Query.select([:id, :slug])
        |> Ash.Query.do_filter(id: form.id)
        |> Ash.read_one!(authorize?: false, tenant: KilnCMS.Accounts.default_org_id())

      assert %Ash.NotLoaded{} = narrowed.embed_origins

      assert_raise ArgumentError, ~r/did not select it/, fn ->
        Embed.own_origins(narrowed)
      end

      assert_raise ArgumentError, ~r/did not select it/, fn ->
        Embed.origins_for(narrowed)
      end
    end

    # `frame_ancestors/1` takes a setting. Handed a form it would have matched
    # the catch-all and rendered `'self'`, dropping that form's allowlist in
    # silence — indistinguishable on the wire from embedding being switched off.
    # Guarded on the attribute, not on `%_struct{}`: a plain map is a form
    # everywhere else here, and a struct-only guard would let exactly those
    # through to the silent close.
    test "frame_ancestors/1 refuses a form rather than closing the policy" do
      for form <- [
            %{embed_origins: ["https://a.test"]},
            %{embed_origins: nil},
            %{__struct__: KilnCMS.CMS.Form, embed_origins: ["https://a.test"]}
          ] do
        assert_raise ArgumentError, ~r/frame_ancestors_for/, fn ->
          Embed.frame_ancestors(form)
        end
      end
    end

    test "cross_site? and the label answer for the form, not the deployment" do
      closed = %{embed_origins: []}
      listed = %{embed_origins: ["https://a.test", "https://b.test"]}

      refute Embed.cross_site?(closed)
      assert Embed.allowed_origins_label(closed) == nil

      assert Embed.cross_site?(listed)
      assert Embed.allowed_origins_label(listed) == "https://a.test, https://b.test"

      # `nil` asks the deployment question explicitly. There is deliberately no
      # arity that asks it by *omission* — a forgotten argument would hand one
      # tenant the shared union, the widening this whole change removes.
      assert Embed.cross_site?(nil)
      assert Embed.allowed_origins_label(nil) == "https://embedder.test"
    end

    test "the label names only what the header actually grants" do
      # A list that renders as `'self'` must not be displayed as an allowlist:
      # the panel exists so an admin can check a host before pasting a snippet,
      # and naming an origin the policy closes is the wrong answer to that.
      assert Embed.allowed_origins_label(%{embed_origins: ["https://a.test", "*"]}) == nil
    end

    test "content_security_policy carries the form's frame-ancestors" do
      policy = Embed.content_security_policy(%{embed_origins: ["https://a.test"]})

      assert String.ends_with?(policy, "frame-ancestors 'self' https://a.test")
      assert policy =~ "script-src 'self'"
    end
  end
end
