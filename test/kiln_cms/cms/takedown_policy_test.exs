defmodule KilnCMS.CMS.TakedownPolicyTest do
  @moduledoc """
  Taking content down needs the same permission as putting it up (#2134):
  `:unpublish`, `:archive` (from every state) and their scheduled twins, plus
  `unpublish_at` / `expiry_action` changes on a record that is live or
  scheduled to go live — an admin,
  or an editor where the site lets editors publish
  (`SiteEditorialSettings.editors_can_publish`). `:unarchive` lands on draft and
  stays an editor's.

  Every actor is an org **member** with the tier on that membership, as in
  `KilnCMS.CMS.EditorsCanPublishTest`: a membership-less account off the default
  org resolves to `:none`, so a "refused" test written with one would pass even
  if the gate admitted every editor. The API-key cases run on the default org,
  where keys are minted.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.CMS.EditorialSettings

  setup do
    org = seed_org()

    %{
      org: org,
      admin: member(org, :admin),
      editor: member(org, :editor),
      viewer: member(org, :viewer)
    }
  end

  # name → {transition, how to build the record it runs on (as the admin)}
  @takedowns [
    unpublish: {:unpublish_post, :published},
    archive_published: {:archive_post, :published},
    archive_draft: {:archive_post, :draft},
    archive_in_review: {:archive_post, :in_review},
    unpublish_scheduled: {:unpublish_scheduled_post, :published},
    archive_scheduled: {:archive_scheduled_post, :published}
  ]

  for {name, {fun, from}} <- @takedowns do
    describe "#{name} (#{fun} from #{from})" do
      @describetag fun: fun, from: from

      test "an admin may, with the switch off or on", ctx do
        assert {:ok, _} = run(ctx, ctx.admin)

        allow_editors!(ctx, true)
        assert {:ok, _} = run(ctx, ctx.admin)
      end

      test "an editor is refused while publishing needs an admin, and the record is unchanged",
           ctx do
        record = record!(ctx)

        assert {:error, %Ash.Error.Forbidden{}} =
                 apply(CMS, ctx.fun, [record, %{}, opts(ctx, ctx.editor)])

        assert reload(ctx, record).state == ctx.from
      end

      test "an editor may once the site lets editors publish", ctx do
        allow_editors!(ctx, true)
        assert {:ok, _} = run(ctx, ctx.editor)
      end

      test "a viewer is refused even where editors may publish", ctx do
        allow_editors!(ctx, true)
        assert {:error, %Ash.Error.Forbidden{}} = run(ctx, ctx.viewer)
      end

      test "an anonymous caller is refused", ctx do
        assert {:error, %Ash.Error.Forbidden{}} = run(ctx, nil)
      end

      test "an editor scoped to another content type is refused even where editors may publish",
           ctx do
        allow_editors!(ctx, true)
        assert {:error, %Ash.Error.Forbidden{}} = run(ctx, member(ctx.org, :editor, ["page"]))
      end

      test "another site's switch does not reach this one", ctx do
        other = seed_org()
        editor = ctx.editor

        Ash.Seed.seed!(Accounts.OrgMembership, %{
          user_id: editor.id,
          organization_id: other.id,
          role: :editor
        })

        {:ok, _} =
          EditorialSettings.save(%{editors_can_publish: true},
            actor: member(other, :admin),
            tenant: other.id
          )

        assert {:error, %Ash.Error.Forbidden{}} = run(ctx, editor)
      end
    end
  end

  describe "unarchive" do
    test "stays an editor's, with the switch off", ctx do
      archived = ctx |> post!() |> CMS.archive_post!(%{}, opts(ctx, ctx.admin))

      assert {:ok, %{state: :draft}} =
               CMS.unarchive_post(archived, %{}, opts(ctx, ctx.editor))
    end
  end

  # The scheduler retires whatever `unpublish_at` names through its bypass, so
  # on a live record the date carries the unpublish permission. On a draft it
  # does nothing until a publisher publishes the whole record.
  describe "unpublish_at" do
    test "an editor is refused setting, moving or clearing it on a published record", ctx do
      live = published!(ctx)
      dated = published!(ctx, %{unpublish_at: in_days(3)})

      for {record, at} <- [{live, in_days(2)}, {dated, in_days(5)}, {dated, nil}] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 CMS.update_post(record, %{unpublish_at: at}, opts(ctx, ctx.editor))

        assert_same_instant(reload(ctx, record).unpublish_at, record.unpublish_at)
      end
    end

    test "an editor may once editors may publish, and an admin always may", ctx do
      assert {:ok, _} =
               CMS.update_post(published!(ctx), %{unpublish_at: in_days(2)}, opts(ctx, ctx.admin))

      allow_editors!(ctx, true)

      assert {:ok, updated} =
               CMS.update_post(
                 published!(ctx),
                 %{unpublish_at: in_days(2)},
                 opts(ctx, ctx.editor)
               )

      assert updated.unpublish_at
    end

    test "an editor may still edit a live record that has one, leaving the date alone", ctx do
      dated = published!(ctx, %{unpublish_at: in_days(3)})

      assert {:ok, updated} =
               CMS.update_post(dated, %{title: "Retitled"}, opts(ctx, ctx.editor))

      assert updated.title == "Retitled"
      assert_same_instant(updated.unpublish_at, dated.unpublish_at)
    end

    test "an editor may resend the date a live record already has", ctx do
      dated = published!(ctx, %{unpublish_at: in_days(3)})

      assert {:ok, _} =
               CMS.update_post(dated, %{unpublish_at: dated.unpublish_at}, opts(ctx, ctx.editor))
    end

    test "an editor may set, move and clear it on a draft and on a record in review", ctx do
      draft = CMS.create_post!(post_attrs(), opts(ctx, ctx.editor))
      in_review = ctx |> post!() |> CMS.submit_post_for_review!(%{}, opts(ctx, ctx.admin))

      for record <- [draft, in_review] do
        assert {:ok, set} =
                 CMS.update_post(record, %{unpublish_at: in_days(2)}, opts(ctx, ctx.editor))

        assert {:ok, moved} =
                 CMS.update_post(set, %{unpublish_at: in_days(4)}, opts(ctx, ctx.editor))

        assert {:ok, cleared} =
                 CMS.update_post(moved, %{unpublish_at: nil}, opts(ctx, ctx.editor))

        assert is_nil(cleared.unpublish_at)
      end
    end

    # A scheduled draft goes live without anybody approving it again, so a
    # date on it is a takedown that follows the scheduled publish.
    test "an editor is refused setting or clearing it on a draft an admin scheduled", ctx do
      scheduled = scheduled!(ctx)
      dated = scheduled!(ctx, %{unpublish_at: in_days(3)})

      for {record, at} <- [{scheduled, in_days(2)}, {dated, in_days(5)}, {dated, nil}] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 CMS.update_post(record, %{unpublish_at: at}, opts(ctx, ctx.editor))

        assert_same_instant(reload(ctx, record).unpublish_at, record.unpublish_at)
      end

      allow_editors!(ctx, true)

      assert {:ok, %{unpublish_at: %DateTime{}}} =
               CMS.update_post(
                 scheduled!(ctx),
                 %{unpublish_at: in_days(2)},
                 opts(ctx, ctx.editor)
               )
    end

    test "an editor may create a draft with one, or with an explicit nil", ctx do
      assert {:ok, _} =
               CMS.create_post(
                 Map.put(post_attrs(), :unpublish_at, in_days(2)),
                 opts(ctx, ctx.editor)
               )

      assert {:ok, _} =
               CMS.create_post(Map.put(post_attrs(), :unpublish_at, nil), opts(ctx, ctx.editor))
    end

    test "changing only scheduled_at stays refused (the policies are separate)", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_post(post!(ctx), %{scheduled_at: in_days(1)}, opts(ctx, ctx.editor))
    end
  end

  # `expiry_action` says what the scheduler does when `unpublish_at` passes —
  # flipping a past-dated `:flag` record to `:unpublish` retires it a minute later.
  describe "expiry_action" do
    test "an editor is refused changing it on a published record", ctx do
      live = published!(ctx, %{expiry_action: :flag})

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_post(live, %{expiry_action: :unpublish}, opts(ctx, ctx.editor))

      assert reload(ctx, live).expiry_action == :flag
    end

    test "an admin may change it on a published record, and an editor once editors may publish",
         ctx do
      assert {:ok, %{expiry_action: :archive}} =
               CMS.update_post(published!(ctx), %{expiry_action: :archive}, opts(ctx, ctx.admin))

      allow_editors!(ctx, true)

      assert {:ok, %{expiry_action: :archive}} =
               CMS.update_post(published!(ctx), %{expiry_action: :archive}, opts(ctx, ctx.editor))
    end

    test "an editor is refused changing it on a draft an admin scheduled", ctx do
      scheduled = scheduled!(ctx, %{unpublish_at: in_days(3), expiry_action: :flag})

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_post(scheduled, %{expiry_action: :archive}, opts(ctx, ctx.editor))

      assert reload(ctx, scheduled).expiry_action == :flag
    end

    test "an editor may create a draft (the default) and change it on a draft", ctx do
      assert {:ok, draft} = CMS.create_post(post_attrs(), opts(ctx, ctx.editor))
      assert draft.expiry_action == :unpublish

      assert {:ok, %{expiry_action: :archive}} =
               CMS.update_post(draft, %{expiry_action: :archive}, opts(ctx, ctx.editor))
    end
  end

  # API keys run on the default org, where they are minted.
  describe "API keys" do
    test "a :read_write key on an editor account cannot unpublish or archive" do
      admin = default_org_user(:admin)
      key = key_actor(default_org_user(:editor), :read_write)
      live = CMS.create_post!(post_attrs(), actor: admin) |> CMS.publish_post!(%{}, actor: admin)

      assert {:error, %Ash.Error.Forbidden{}} = CMS.unpublish_post(live, %{}, actor: key)
      assert {:error, %Ash.Error.Forbidden{}} = CMS.archive_post(live, %{}, actor: key)
      assert CMS.get_post!(live.id, actor: admin).state == :published
    end

    test "a :draft_write key cannot archive even its own draft" do
      owner = default_org_user(:viewer)
      key = key_actor(owner, :draft_write)
      {:ok, draft} = CMS.create_post(post_attrs(), actor: key)

      assert {:error, %Ash.Error.Forbidden{}} = CMS.archive_post(draft, %{}, actor: key)
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp run(ctx, actor), do: apply(CMS, ctx.fun, [record!(ctx), %{}, opts(ctx, actor)])

  defp record!(%{from: :published} = ctx), do: published!(ctx)
  defp record!(%{from: :draft} = ctx), do: post!(ctx)

  defp record!(%{from: :in_review} = ctx),
    do: ctx |> post!() |> CMS.submit_post_for_review!(%{}, opts(ctx, ctx.admin))

  defp post!(ctx, attrs \\ %{}),
    do: CMS.create_post!(Map.merge(post_attrs(), attrs), opts(ctx, ctx.admin))

  defp published!(ctx, attrs \\ %{}),
    do: ctx |> post!(attrs) |> CMS.publish_post!(%{}, opts(ctx, ctx.admin))

  # A draft with a publish date, set by the admin (setting one takes the
  # publish permission).
  defp scheduled!(ctx, attrs \\ %{}),
    do: post!(ctx, Map.put(attrs, :scheduled_at, in_days(1)))

  defp reload(ctx, record), do: CMS.get_post!(record.id, opts(ctx, ctx.admin))

  defp post_attrs,
    do: %{title: "Takedown", slug: "takedown-#{System.unique_integer([:positive])}"}

  defp opts(ctx, actor), do: [actor: actor, tenant: ctx.org.id]

  defp in_days(n), do: DateTime.add(DateTime.utc_now(), n, :day)

  defp assert_same_instant(nil, nil), do: :ok
  defp assert_same_instant(a, b), do: assert(DateTime.compare(a, b) == :eq)

  defp allow_editors!(ctx, value) do
    {:ok, _} =
      EditorialSettings.save(%{editors_can_publish: value}, actor: ctx.admin, tenant: ctx.org.id)
  end

  defp seed_org do
    Ash.Seed.seed!(Accounts.Organization, %{
      name: "Takedown Site",
      slug: "takedown-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  # A global `:viewer` whose tier on `org` comes from the membership alone.
  defp member(org, tier, editable_types \\ []) do
    user = seed_user(:viewer, "takedown-#{tier}")

    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: tier,
      editable_types: editable_types
    })

    user
  end

  # A membership-less account on the default org, whose tier is `User.role`.
  defp default_org_user(role), do: seed_user(role, "takedown-key-#{role}")

  defp seed_user(role, prefix) do
    Ash.Seed.seed!(Accounts.User, %{
      email: "#{prefix}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  # The actor a request authenticated by a fresh key of `access` on `owner` runs as.
  defp key_actor(owner, access) do
    key =
      Accounts.mint_api_key!(
        owner.id,
        "takedown",
        DateTime.add(DateTime.utc_now(), 7, :day),
        %{access: access},
        actor: default_org_user(:admin)
      )

    {:ok, actor} =
      key |> Ash.Resource.get_metadata(:plaintext_api_key) |> Accounts.actor_from_api_key()

    actor
  end
end
