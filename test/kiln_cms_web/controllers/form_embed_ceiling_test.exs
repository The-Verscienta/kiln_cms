defmodule KilnCMSWeb.FormEmbedCeilingTest do
  @moduledoc """
  The operator's ceiling over tenant framing (#1133), through the real
  resources and the real request pipeline.

  `config/test.exs` pins `:embed_origins` (the deployment default, and under
  the cap the ceiling) to `["https://embedder.test"]`. The cap itself is
  application env, so this file is `async: false` and restores it after every
  test — with the cap OFF, which is what a deployment ships with, every test
  here must reproduce #1130/#1131 behaviour unchanged.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures

  alias KilnCMS.CMS

  setup do
    previous = Application.get_env(:kiln_cms, :embed_origins_locked)
    on_exit(fn -> restore_lock(previous) end)
    :ok
  end

  defp restore_lock(nil), do: Application.delete_env(:kiln_cms, :embed_origins_locked)
  defp restore_lock(value), do: Application.put_env(:kiln_cms, :embed_origins_locked, value)

  defp lock!, do: Application.put_env(:kiln_cms, :embed_origins_locked, true)
  defp unlock!, do: Application.put_env(:kiln_cms, :embed_origins_locked, false)

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fec-#{System.unique_integer([:positive])}@example.com",
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
            slug: "fec-#{System.unique_integer([:positive])}",
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

  defp frame_ancestors(conn) do
    [_head, sources] =
      conn
      |> get_resp_header("content-security-policy")
      |> List.first()
      |> String.split("frame-ancestors ")

    sources
  end

  defp embed_policy(conn, org, form) do
    conn |> unique_ip() |> org_conn(org) |> get("/forms/#{form.slug}/embed") |> frame_ancestors()
  end

  describe "an org admin's form write" do
    test "is refused under the cap when it names an origin outside the ceiling, and accepted without" do
      actor = admin()
      org = org("fec-write")
      form = form!(%{}, actor: actor, tenant: org)

      lock!()

      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.update_form(
                 form,
                 %{embed_origins: ["https://embedder.test", "https://other.test"]},
                 actor: actor,
                 tenant: org
               )

      message = Exception.message(error)
      # Names the offender…
      assert message =~ "https://other.test"
      assert message =~ "capped"
      # …and never the ceiling, which on a shared deployment is every org's partners.
      refute message =~ "embedder.test",
             "the refusal must not enumerate the deployment ceiling"

      unlock!()

      assert {:ok, %{embed_origins: ["https://embedder.test", "https://other.test"]}} =
               CMS.update_form(
                 form,
                 %{embed_origins: ["https://embedder.test", "https://other.test"]},
                 actor: actor,
                 tenant: org
               )
    end

    test "under the cap, narrowing is still allowed: a subset, or an explicit close" do
      actor = admin()
      org = org("fec-narrow")
      form = form!(%{}, actor: actor, tenant: org)
      lock!()

      assert {:ok, %{embed_origins: ["https://embedder.test"]} = form} =
               CMS.update_form(form, %{embed_origins: ["https://embedder.test"]},
                 actor: actor,
                 tenant: org
               )

      assert {:ok, %{embed_origins: []} = form} =
               CMS.update_form(form, %{embed_origins: []}, actor: actor, tenant: org)

      # And back to inherit — `nil` is the ceiling itself, never outside it.
      assert {:ok, %{embed_origins: nil}} =
               CMS.update_form(form, %{embed_origins: nil}, actor: actor, tenant: org)
    end

    test "under the cap, an unrelated edit to a form carrying a stale wider list still saves" do
      # Written before the cap; the served header is clamped meanwhile (below),
      # so refusing a rename until the list is fixed would buy nothing.
      actor = admin()
      org = org("fec-stale")
      form = form!(%{embed_origins: ["https://other.test"]}, actor: actor, tenant: org)
      lock!()

      assert {:ok, %{name: "Renamed", embed_origins: ["https://other.test"]}} =
               CMS.update_form(form, %{name: "Renamed"}, actor: actor, tenant: org)
    end

    test "with EMBED_ORIGINS=* the cap is a ceiling of everything" do
      previous = Application.get_env(:kiln_cms, :embed_origins)
      on_exit(fn -> Application.put_env(:kiln_cms, :embed_origins, previous) end)
      Application.put_env(:kiln_cms, :embed_origins, :all)

      actor = admin()
      org = org("fec-all")
      form = form!(%{}, actor: actor, tenant: org)
      lock!()

      assert {:ok, %{embed_origins: ["https://anywhere.test"]}} =
               CMS.update_form(form, %{embed_origins: ["https://anywhere.test"]},
                 actor: actor,
                 tenant: org
               )
    end
  end

  describe "an org admin's site-default write" do
    test "is refused under the cap and accepted without — same boundary, second rung" do
      org = org("fec-site")
      lock!()

      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.save_site_embed_settings(%{embed_origins: ["https://other.test"]},
                 authorize?: false,
                 tenant: org.id
               )

      assert Exception.message(error) =~ "https://other.test"

      assert {:ok, %{embed_origins: ["https://embedder.test"]}} =
               CMS.save_site_embed_settings(%{embed_origins: ["https://embedder.test"]},
                 authorize?: false,
                 tenant: org.id
               )

      unlock!()

      assert {:ok, %{embed_origins: ["https://other.test"]}} =
               CMS.save_site_embed_settings(%{embed_origins: ["https://other.test"]},
                 authorize?: false,
                 tenant: org.id
               )
    end
  end

  describe "the served header" do
    test "cap off: a form's own wider list is served as-is (#1130 unchanged)", %{conn: conn} do
      unlock!()
      actor = admin()
      org = org("fec-serve-off")
      form = form!(%{embed_origins: ["https://other.test"]}, actor: actor, tenant: org)

      assert embed_policy(conn, org, form) == "'self' https://other.test"
    end

    test "cap on: a list saved before the cap is clamped to the ceiling on the read", %{
      conn: conn
    } do
      actor = admin()
      org = org("fec-serve-clamp")

      form =
        form!(%{embed_origins: ["https://embedder.test", "https://other.test"]},
          actor: actor,
          tenant: org
        )

      lock!()

      assert embed_policy(conn, org, form) == "'self' https://embedder.test"
    end

    test "cap on: a list entirely outside the ceiling serves same-origin only", %{conn: conn} do
      actor = admin()
      org = org("fec-serve-closed")
      form = form!(%{embed_origins: ["https://other.test"]}, actor: actor, tenant: org)
      lock!()

      assert embed_policy(conn, org, form) == "'self'"
    end

    test "cap on: the org rung is clamped too", %{conn: conn} do
      actor = admin()
      org = org("fec-serve-org")

      CMS.save_site_embed_settings!(
        %{embed_origins: ["https://other.test", "https://embedder.test"]},
        authorize?: false,
        tenant: org.id
      )

      form = form!(%{}, actor: actor, tenant: org)
      lock!()

      assert embed_policy(conn, org, form) == "'self' https://embedder.test"
    end

    test "cap on: a form that inherits serves the deployment list, which IS the ceiling",
         %{conn: conn} do
      actor = admin()
      org = org("fec-serve-inherit")
      form = form!(%{}, actor: actor, tenant: org)
      lock!()

      assert embed_policy(conn, org, form) == "'self' https://embedder.test"
    end
  end
end
