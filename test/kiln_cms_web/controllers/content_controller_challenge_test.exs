defmodule KilnCMSWeb.ContentControllerChallengeTest do
  @moduledoc """
  Human verification on published pages that place a form (#2249): the widget
  and a widened Content-Security-Policy only where a form draws one, an ETag
  that moves when what the form renders does, and the surfaces that must not
  change at all — pages without such a form, previews, fired artifacts and the
  newsletter sign-up.

  `async: false`: `KilnCMS.ChallengeFixtures.enable!/1` writes application env
  and an OS variable, both node-wide, and these tests read the shared delivery
  cache.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import KilnCMS.ChallengeFixtures

  alias KilnCMS.Blocks
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page
  alias KilnCMS.FormFixtures

  @provider "https://challenge.test"

  setup do
    KilnCMS.Cache.bust_published()
    enable!()
    admin = FormFixtures.admin()

    %{
      admin: admin,
      required: FormFixtures.form!(%{challenge: :always}, actor: admin),
      plain: FormFixtures.form!(%{}, actor: admin)
    }
  end

  defp uniq, do: System.unique_integer([:positive])

  defp form_block(form, id \\ nil),
    do: %{id: id, type: :form, content: form.slug, data: %{"form_slug" => form.slug}, order: 0}

  defp page!(blocks, attrs \\ %{}) do
    Ash.Seed.seed!(
      Page,
      Map.merge(
        %{
          title: "A page",
          slug: "cc-#{uniq()}",
          state: :published,
          blocks: KilnCMS.TypedFixtures.typed_blocks(blocks)
        },
        attrs
      )
    )
  end

  defp csp(conn), do: conn |> get_resp_header("content-security-policy") |> List.first()
  defp etag(conn), do: conn |> get_resp_header("etag") |> List.first()
  defp without_nonce(policy), do: String.replace(policy, ~r/'nonce-[^']+'/, "'nonce'")

  defp fetch(slug, etag \\ nil) do
    conn = build_conn()
    conn = if etag, do: put_req_header(conn, "if-none-match", etag), else: conn
    get(conn, "/#{slug}")
  end

  describe "a page placing a form that asks for a check" do
    test "draws the widget and lets the provider in", %{required: required} do
      page = page!([form_block(required)])
      conn = fetch(page.slug)

      html = html_response(conn, 200)
      assert html =~ "data-kiln-challenge"
      assert html =~ ~s(name="_kiln_challenge")
      assert csp(conn) =~ @provider
    end

    test "inside a columns block too", %{required: required} do
      page =
        page!([
          %{
            type: :columns,
            content: nil,
            data: %{"columns" => [%{"blocks" => [form_block(required)]}, %{"blocks" => []}]},
            order: 0
          }
        ])

      conn = fetch(page.slug)
      assert html_response(conn, 200) =~ "data-kiln-challenge"
      assert csp(conn) =~ @provider
    end

    test "a page without one keeps its policy byte for byte", %{plain: plain} do
      for blocks <- [[], [form_block(plain)]] do
        page = page!(blocks)
        on = fetch(page.slug)
        refute html_response(on, 200) =~ "data-kiln-challenge"

        enable!(disabled: true)
        off = fetch(page.slug)
        enable!()

        assert without_nonce(csp(on)) == without_nonce(csp(off))
        refute csp(on) =~ @provider
      end
    end

    test "another site's form under the same slug is its own", %{required: required} do
      org = KilnCMS.OrgFixtures.org("ccc")
      other_admin = FormFixtures.admin()

      FormFixtures.form!(%{slug: required.slug}, actor: other_admin, tenant: org.id)

      page =
        Ash.Seed.seed!(
          Page,
          %{
            title: "Theirs",
            slug: "cc-#{uniq()}",
            state: :published,
            blocks: KilnCMS.TypedFixtures.typed_blocks([form_block(required)])
          },
          tenant: org
        )

      host = "#{org.slug}.#{KilnCMSWeb.Tenant.base_host()}"
      conn = %{build_conn() | host: host} |> get("/#{page.slug}")

      html = html_response(conn, 200)
      assert html =~ ~s(action="/en/forms/#{required.slug}")
      refute html =~ "data-kiln-challenge"
      refute csp(conn) =~ @provider
    end

    test "nothing is drawn while the operator has forms off", %{required: required} do
      enable!(forms: false)
      conn = fetch(page!([form_block(required)]).slug)

      refute html_response(conn, 200) =~ "data-kiln-challenge"
      refute csp(conn) =~ @provider
    end
  end

  describe "the ETag" do
    test "a page without a form keeps the ETag it had", %{plain: plain} do
      bare = page!([])
      with_plain = page!([form_block(plain)])

      # The pre-#2249 formula, with no forms segment, and the build named last
      # (#2463).
      expected = fn record ->
        raw =
          "#{record.id}:#{record.locale}:#{record.updated_at}:#{record.published_version_id}" <>
            ":#{record.seo_title}:#{record.seo_description}" <>
            ":#{KilnCMSWeb.Robots.directive(record)}" <>
            ":#{KilnCMS.Cache.head_generation(record.org_id)}" <>
            ":#{KilnCMSWeb.BuildFingerprint.fingerprint()}"

        digest = :sha256 |> :crypto.hash(raw) |> Base.encode16(case: :lower) |> binary_part(0, 16)
        ~s("#{digest}")
      end

      assert etag(fetch(bare.slug)) == expected.(bare)
      refute etag(fetch(with_plain.slug)) == expected.(with_plain)
    end

    test "304 while nothing changed", %{required: required} do
      page = page!([form_block(required)])
      tag = etag(fetch(page.slug))

      assert fetch(page.slug, tag).status == 304
    end

    test "200 after a field of the form is edited", %{required: required, admin: admin} do
      page = page!([form_block(required)])
      tag = etag(fetch(page.slug))

      [field] = CMS.form_fields_for!(required.id, authorize?: false)
      CMS.update_form_field!(field, %{label: "Where can we reach you?"}, actor: admin)

      conn = fetch(page.slug, tag)
      assert html_response(conn, 200) =~ "Where can we reach you?"
      refute etag(conn) == tag
    end

    test "200 after the form's check is switched", %{plain: plain, admin: admin} do
      page = page!([form_block(plain)])
      tag = etag(fetch(page.slug))

      CMS.update_form!(CMS.get_form!(plain.id, authorize?: false), %{challenge: :always},
        actor: admin
      )

      conn = fetch(page.slug, tag)
      assert html_response(conn, 200) =~ "data-kiln-challenge"
      assert csp(conn) =~ @provider
    end

    test "200 after the operator changes the site key, or turns forms off",
         %{required: required} do
      page = page!([form_block(required)])
      tag = etag(fetch(page.slug))

      enable!(site_key: "rotated-site-key")
      conn = fetch(page.slug, tag)
      assert html_response(conn, 200) =~ ~s(data-sitekey="rotated-site-key")
      rotated = etag(conn)

      enable!(forms: false)
      conn = fetch(page.slug, rotated)
      refute html_response(conn, 200) =~ "data-kiln-challenge"
    end

    # A plugin update can change the script or options its widget is drawn
    # with under the same id and site key; a cached page would then draw it
    # with the old ones.
    test "200 after the provider's widget changes under the same id", %{required: required} do
      page = page!([form_block(required)])
      tag = etag(fetch(page.slug))

      enable!(providers: [__MODULE__.MovedFake])
      conn = fetch(page.slug, tag)

      assert html_response(conn, 200) =~ ~s(data-script-url="https://challenge.test/v2/api.js")
      refute etag(conn) == tag
    end
  end

  describe "with reCAPTCHA (#2249)" do
    test "the page admits recaptcha.net and gstatic, never www.google.com",
         %{required: required} do
      enable!(provider: "recaptcha")
      page = page!([form_block(required)])
      conn = fetch(page.slug)

      html = html_response(conn, 200)
      assert html =~ ~s(data-onload-param="onload")
      assert html =~ ~s(data-interactive="true")
      assert html =~ ~s(data-action-option="")
      assert csp(conn) =~ "https://www.recaptcha.net/recaptcha/"
      assert csp(conn) =~ "https://www.gstatic.com/recaptcha/"
      refute csp(conn) =~ "www.google.com"
    end
  end

  describe "an experiment variant" do
    setup do
      KilnCMS.ExperimentFixtures.enable!()
      :ok
    end

    test "that places the form only in the variant widens the variant's policy",
         %{required: required, plain: plain, admin: admin} do
      block_id = Ecto.UUID.generate()

      page =
        CMS.create_page!(
          %{
            title: "Experimented",
            slug: "cc-#{uniq()}",
            blocks: KilnCMS.TypedFixtures.typed_blocks([form_block(plain, block_id)])
          },
          actor: admin
        )

      CMS.publish_page!(page, actor: admin)
      KilnCMS.DataCase.drain_oban()
      page = Ash.reload!(page, authorize?: false, tenant: page.org_id)

      KilnCMS.ExperimentFixtures.pinned!(page, "page", %{
        "blocks" => %{block_id => %{"form_slug" => required.slug}}
      })

      conn = fetch(page.slug)
      html = html_response(conn, 200)

      assert html =~ ~s(action="/en/forms/#{required.slug}")
      assert html =~ "data-kiln-challenge"
      assert csp(conn) =~ @provider
    end
  end

  describe "surfaces that do not change" do
    test "a draft preview renders no form, so no widget", %{required: required, admin: admin} do
      page =
        CMS.create_page!(
          %{
            title: "Draft",
            slug: "cc-#{uniq()}",
            blocks: KilnCMS.TypedFixtures.typed_blocks([form_block(required)])
          },
          actor: admin
        )

      path = "/preview/#{KilnCMS.CMS.PreviewToken.sign(page)}/live"
      conn = get(build_conn(), path)
      html = html_response(conn, 200)

      assert html =~ "Draft"
      refute html =~ "data-kiln-challenge"
      refute csp(conn) =~ @provider
    end

    test "the fired form block is the same placeholder whatever the settings",
         %{required: required} do
      block = %Blocks.Form{id: "f", _type: "form", form_slug: required.slug}
      on = {Blocks.render(block, :web), Blocks.render(block, :json)}

      enable!(disabled: true)
      off = {Blocks.render(block, :web), Blocks.render(block, :json)}

      assert on == off
      refute IO.iodata_to_binary(elem(on, 0)) =~ "challenge"
    end

    test "a newsletter sign-up is never verified" do
      email = "nl-#{uniq()}@example.com"

      response =
        build_conn()
        |> post("/newsletter/subscribe", %{"email" => email, "_kiln_challenge" => "fail"})
        |> html_response(200)

      assert response =~ "Check your inbox"
      refute_received {:challenge_verify, _, _}
    end
  end
end

defmodule KilnCMSWeb.ContentControllerChallengeTest.MovedFake do
  @moduledoc false
  # `KilnCMS.ChallengeFake` after a release that moved its script.
  use Kiln.Challenge.Provider

  def id, do: "fake"

  def widget,
    do: %{KilnCMS.ChallengeFake.widget() | script_url: "https://challenge.test/v2/api.js"}

  def csp_sources, do: KilnCMS.ChallengeFake.csp_sources()
  def verify(token, opts), do: KilnCMS.ChallengeFake.verify(token, opts)
end
