defmodule KilnCMSWeb.FormEmbedOrgDefaultTest do
  @moduledoc """
  The org rung of the framing ladder (#1131), exercised through the real
  request pipeline:

      form.embed_origins  ->  SiteEmbedSettings.embed_origins  ->  EMBED_ORIGINS

  `test/kiln_cms_web/controllers/form_embed_origins_test.exs` pins the
  form-vs-deployment half (#648); this file is about the rung #1131 inserted
  between them — an org-wide default governing every form that has not set
  its own, without reaching into another org's forms.

  `config/test.exs` pins `:embed_origins` to `["https://embedder.test"]`,
  which is the deployment's answer for an org that has configured no default
  of its own — and, in these tests, the origin that must NOT appear once an
  org has set one, since #648's "a form's list replaces the deployment's"
  rule applies one rung up too.
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.OrgFixtures

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "feod-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp form!(attrs, opts) do
    form =
      CMS.create_form!(
        Map.merge(
          %{
            name: "Contact us",
            slug: "feod-#{System.unique_integer([:positive])}",
            success_message: "Merci!"
          },
          attrs
        ),
        Keyword.take(opts, [:actor, :tenant])
      )

    CMS.create_form_field!(
      %{form_id: form.id, name: "email", label: "Email", field_type: :email, required: true},
      Keyword.take(opts, [:actor, :tenant])
    )

    form
  end

  defp save_org_default!(origins, org_id) do
    CMS.save_site_embed_settings!(%{embed_origins: origins}, authorize?: false, tenant: org_id)
  end

  # Same helper as form_embed_origins_test.exs, compared with `==` rather than
  # `=~` — a substring match would pass on a policy that ALSO carries the
  # deployment's or another org's origin, which is exactly the defect these
  # tests exist to catch.
  defp frame_ancestors(conn) do
    [_head, sources] =
      conn
      |> get_resp_header("content-security-policy")
      |> List.first()
      |> String.split("frame-ancestors ")

    sources
  end

  describe "an org default governs every form that has not set its own" do
    test "two orgs, neither form sets its own list: each gets its own org's default",
         %{conn: conn} do
      actor = admin()
      a = org("epol-two-a")
      b = org("epol-two-b")

      save_org_default!(["https://a-partner.test"], a.id)
      save_org_default!(["https://b-partner.test"], b.id)

      form_a = form!(%{}, actor: actor, tenant: a)
      form_b = form!(%{}, actor: actor, tenant: b)

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

      # Each org's own default, and nothing else — not the other org's, and
      # not the deployment's shared `EMBED_ORIGINS`.
      assert policy_a == "'self' https://a-partner.test"
      assert policy_b == "'self' https://b-partner.test"
      refute policy_a =~ "b-partner"
      refute policy_b =~ "a-partner"
      refute policy_a =~ "embedder.test"
      refute policy_b =~ "embedder.test"
    end

    test "a form's own list still overrides the org default", %{conn: conn} do
      actor = admin()
      a = org("epol-override-a")
      save_org_default!(["https://org-default.test"], a.id)

      form = form!(%{embed_origins: ["https://form-own.test"]}, actor: actor, tenant: a)

      policy =
        conn
        |> unique_ip()
        |> org_conn(a)
        |> get("/forms/#{form.slug}/embed")
        |> frame_ancestors()

      assert policy == "'self' https://form-own.test"
      refute policy =~ "org-default"
    end

    test "a form's own explicit close ([]) overrides the org default too", %{conn: conn} do
      actor = admin()
      a = org("epol-override-close-a")
      save_org_default!(["https://org-default.test"], a.id)

      form = form!(%{embed_origins: []}, actor: actor, tenant: a)

      policy =
        conn
        |> unique_ip()
        |> org_conn(a)
        |> get("/forms/#{form.slug}/embed")
        |> frame_ancestors()

      assert policy == "'self'"
    end

    test "an org with no default configured still inherits the deployment's", %{conn: conn} do
      actor = admin()
      a = org("epol-no-default-a")

      form = form!(%{}, actor: actor, tenant: a)

      policy =
        conn
        |> unique_ip()
        |> org_conn(a)
        |> get("/forms/#{form.slug}/embed")
        |> frame_ancestors()

      assert policy == "'self' https://embedder.test"
    end

    test "an org default of [] closes every form in that org that has none of its own",
         %{conn: conn} do
      actor = admin()
      a = org("epol-closed-default-a")
      save_org_default!([], a.id)

      form = form!(%{}, actor: actor, tenant: a)

      policy =
        conn
        |> unique_ip()
        |> org_conn(a)
        |> get("/forms/#{form.slug}/embed")
        |> frame_ancestors()

      assert policy == "'self'"
    end
  end
end
