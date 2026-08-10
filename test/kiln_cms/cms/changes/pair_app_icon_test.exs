defmodule KilnCMS.CMS.Changes.PairAppIconTest do
  @moduledoc """
  The one rule that keeps a measured `app_icon_size` describing the
  `app_icon_url` it was measured from (#629).

  This is tested against the **resource**, not through the settings LiveView,
  because the whole reason the change exists is that the LiveView is not the
  only writer. A seed, a Mix task, `ash_admin`, an import or a future API all
  reach the same actions, and before this change the pairing was a convention
  living in one `handle_event` clause.

  The failure it prevents is silent and total: a manifest that declares
  `sizes: "1024x1024"` about a 300px image does not degrade — Chromium stops
  offering the install prompt and reports nothing anywhere.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  setup do
    org = seed_org()
    on_exit(fn -> KilnCMS.Cache.bust_branding(org.id) end)
    %{org: org, admin: platform_admin()}
  end

  defp save(ctx, attrs), do: CMS.save_site_branding!(attrs, actor: ctx.admin, tenant: ctx.org)

  defp row!(ctx) do
    {:ok, [row]} = CMS.list_site_branding(tenant: ctx.org, authorize?: false)
    row
  end

  describe "a measurement only survives with the URL it measured" do
    test "both together is the normal case", ctx do
      save(ctx, %{app_icon_url: "/uploads/icon.png", app_icon_size: 512})

      assert %{app_icon_url: "/uploads/icon.png", app_icon_size: 512} = row!(ctx)
    end

    test "changing the URL without a new measurement drops the old one", ctx do
      save(ctx, %{app_icon_url: "/uploads/old.png", app_icon_size: 1024})

      # The dangerous write: a caller that knows about the URL but not about the
      # size. `upsert_fields` does NOT prevent this — AshPostgres filters it down
      # to the attributes actually in the changeset, so the old size would simply
      # stay in the row underneath the new icon.
      save(ctx, %{app_icon_url: "/uploads/new.png"})

      row = row!(ctx)
      assert row.app_icon_url == "/uploads/new.png"
      assert row.app_icon_size == nil
    end

    test "clearing the URL clears the size", ctx do
      save(ctx, %{app_icon_url: "/uploads/icon.png", app_icon_size: 512})

      save(ctx, %{app_icon_url: nil})

      assert %{app_icon_url: nil, app_icon_size: nil} = row!(ctx)
    end

    test "a size with no URL is not stored — it would be a claim about nothing", ctx do
      save(ctx, %{app_icon_size: 512})

      assert row!(ctx).app_icon_size == nil
    end

    test "a blank URL counts as cleared, not as an icon", ctx do
      save(ctx, %{app_icon_url: "/uploads/icon.png", app_icon_size: 512})

      save(ctx, %{app_icon_url: "", app_icon_size: 512})

      assert row!(ctx).app_icon_size == nil
    end

    test "the same rule holds on :update, not just the settings upsert", ctx do
      save(ctx, %{app_icon_url: "/uploads/icon.png", app_icon_size: 512})

      row!(ctx)
      |> Ash.Changeset.for_update(:update, %{app_icon_url: "/uploads/other.png"},
        actor: ctx.admin,
        tenant: ctx.org
      )
      |> Ash.update!()

      assert row!(ctx).app_icon_size == nil
    end
  end

  describe "a size that could not have been measured is refused" do
    test "zero and negatives never reach the column", ctx do
      # `sizes: "0x0"` and `sizes: "-1x-1"` are the same class of false
      # declaration as a wrong size, reached through a different door.
      for bogus <- [0, -1] do
        save(ctx, %{app_icon_url: "/uploads/icon.png", app_icon_size: bogus})

        assert row!(ctx).app_icon_size == nil, "expected #{bogus} to be refused"
      end
    end
  end

  describe "the column is not writable as an attribute" do
    test "only the argument can set it" do
      # If `app_icon_size` were accepted as an attribute, the argument and the
      # change would both be bypassable by anything that builds a changeset
      # directly — which is every writer that is not the settings form.
      refute :app_icon_size in Ash.Resource.Info.action(CMS.SiteBranding, :save).accept
    end
  end

  defp seed_org do
    Ash.Seed.seed!(Accounts.Organization, %{
      name: "Pair Icon Org",
      slug: "pair-icon-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp platform_admin do
    Ash.Seed.seed!(Accounts.User, %{
      email: "pair-icon-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password1234!"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end
end
