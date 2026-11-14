defmodule KilnCMS.Docs.EditorialWorkflowTest do
  @moduledoc """
  docs/editorial-workflow.md (#2158) promises who may do what. Its role
  table is checked against the policies here, cell by cell: every row names
  the action it is about, and each row maps to a check below that runs that
  action as a viewer, an editor and an admin of one site, with the
  "editors can publish" switch off and then on. A table that drifts from the
  code fails, and so does a row nobody has mapped to a check.

  The guide's screenshots are budgeted with every other guide's, in
  `KilnCMS.Docs.GuideImagesTest` (#2460).

  Every actor is an org member with the tier on that membership, as in
  `KilnCMS.CMS.EditorsCanPublishTest`: a membership-less account resolves to
  no tier at all, and a "refused" cell would pass for the wrong reason.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.CMS.{EditorialSettings, PreviewToken}

  @guide "docs/editorial-workflow.md"
  @tiers [:viewer, :editor, :admin]

  # A guide read in five minutes.
  @max_words 1_300

  # Row label → the check that proves it. Explicit on purpose: a new row needs
  # a check before the table may claim it.
  @checks %{
    "Read published content" => :read_published,
    "Create and edit drafts (`create`, `update`)" => :create_and_update,
    "Preview a draft and copy a preview link" => :preview_link,
    "Submit for review (`submit_for_review`)" => :submit_for_review,
    "Publish now or on a date (`publish`, `publish_scheduled`)" => :publish,
    "Set the publish date (`scheduled_at`)" => :scheduled_at,
    "Propose a publish date (`proposed_publish_at`)" => :proposed_publish_at,
    "Request changes (`return_to_draft`)" => :return_to_draft,
    "Put edits to a live page live (`publish_changes`)" => :publish_changes,
    "Unpublish or archive (`unpublish`, `archive`)" => :unpublish_and_archive,
    "Set the unpublish date of a live page (`unpublish_at`)" => :unpublish_at,
    "Restore an earlier version (`restore_version`)" => :restore_version,
    "Delete, and restore from the trash (`destroy`, `restore`)" => :destroy_and_restore,
    "Turn the Team → Publishing switch on or off" => :publishing_switch
  }

  describe "the role table" do
    setup do
      %{rows: role_rows(File.read!(@guide))}
    end

    test "maps every row to a check, and every check to a row", %{rows: rows} do
      assert rows |> Enum.map(&elem(&1, 0)) |> Enum.sort() == @checks |> Map.keys() |> Enum.sort()
    end

    for switch <- [:off, :on] do
      @tag switch: switch
      test "matches the policies with Team → Publishing #{switch}", %{rows: rows, switch: switch} do
        org = seed_org()
        ctx = %{org: org, admin: member(org, :admin)}
        allow_editors!(org, ctx.admin, switch == :on)

        actors = Map.new(@tiers, &{&1, if(&1 == :admin, do: ctx.admin, else: member(org, &1))})

        for {label, cells} <- rows, {tier, cell} <- Enum.zip(@tiers, cells) do
          expected = expected(cell, switch)
          actual = run(Map.fetch!(@checks, label), actors[tier], Map.put(ctx, :switch, switch))

          assert actual == expected,
                 "#{label}: #{tier} with publishing #{switch} is #{actual}, the guide says #{cell}"
        end
      end
    end

    test "an unknown cell is a failure, not a pass" do
      assert_raise ArgumentError, fn -> expected("Sometimes", :off) end
    end

    test "a row the checks do not know fails the mapping" do
      rows =
        role_rows("""
        <!-- role-matrix:start -->
        | Action | Viewer | Editor | Admin |
        |---|---|---|---|
        | Fly to the moon (`moon`) | No | No | Yes |
        <!-- role-matrix:end -->
        """)

      refute Map.has_key?(@checks, rows |> hd() |> elem(0))
    end
  end

  test "reads in five minutes" do
    words = @guide |> File.read!() |> String.split(~r/\s+/, trim: true) |> length()

    assert words <= @max_words, "#{words} words"
  end

  # ── The table ──────────────────────────────────────────────────────────────

  # `[{label, [viewer, editor, admin]}]` from the block between the markers.
  defp role_rows(markdown) do
    [_, rest] = String.split(markdown, "<!-- role-matrix:start -->")
    [table, _] = String.split(rest, "<!-- role-matrix:end -->")

    table
    |> String.split("\n", trim: true)
    |> Enum.drop(2)
    |> Enum.map(fn line ->
      [label | cells] =
        line |> String.trim() |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1)

      {label, cells}
    end)
  end

  defp expected("Yes", _switch), do: :ok
  defp expected("No", _switch), do: :forbidden
  defp expected("If editors may publish", :off), do: :forbidden
  defp expected("If editors may publish", :on), do: :ok
  defp expected(cell, _switch), do: raise(ArgumentError, "unknown cell #{inspect(cell)}")

  # ── The checks ─────────────────────────────────────────────────────────────

  defp run(:read_published, actor, ctx),
    do: ctx |> published!() |> then(&CMS.get_page(&1.id, opts(actor, ctx))) |> outcome()

  defp run(:create_and_update, actor, ctx) do
    both([
      CMS.create_page(%{title: "Mine", slug: slug()}, opts(actor, ctx)),
      CMS.update_page(draft!(ctx), %{title: "Edited"}, opts(actor, ctx))
    ])
  end

  defp run(:preview_link, actor, ctx) do
    case PreviewToken.mint(:page, draft!(ctx).id, opts(actor, ctx)) do
      {:ok, _minted} -> :ok
      {:error, reason} when reason in [:forbidden, :not_found] -> :forbidden
    end
  end

  defp run(:submit_for_review, actor, ctx),
    do: ctx |> draft!() |> CMS.submit_page_for_review(opts(actor, ctx)) |> outcome()

  defp run(:publish, actor, ctx) do
    both([
      ctx |> draft!() |> CMS.publish_page(opts(actor, ctx)),
      ctx
      |> draft!(%{scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day)})
      |> CMS.publish_scheduled_page(opts(actor, ctx))
    ])
  end

  defp run(:scheduled_at, actor, ctx),
    do:
      ctx
      |> draft!()
      |> CMS.update_page(%{scheduled_at: tomorrow()}, opts(actor, ctx))
      |> outcome()

  defp run(:proposed_publish_at, actor, ctx) do
    ctx
    |> draft!()
    |> CMS.update_page(%{proposed_publish_at: tomorrow()}, opts(actor, ctx))
    |> outcome()
  end

  defp run(:return_to_draft, actor, ctx) do
    ctx
    |> draft!()
    |> CMS.submit_page_for_review!(opts(ctx.admin, ctx))
    |> CMS.return_page_to_draft(opts(actor, ctx))
    |> outcome()
  end

  defp run(:publish_changes, actor, ctx) do
    ctx
    |> published!()
    |> CMS.save_page_working_copy!(%{working_title: "Held title"}, opts(ctx.admin, ctx))
    |> CMS.publish_page_changes(opts(actor, ctx))
    |> outcome()
  end

  defp run(:unpublish_and_archive, actor, ctx) do
    both([
      ctx |> published!() |> CMS.unpublish_page(opts(actor, ctx)),
      ctx |> published!() |> CMS.archive_page(opts(actor, ctx)),
      # Archive is gated from every state, not only from published (#2134).
      ctx |> draft!() |> CMS.archive_page(opts(actor, ctx))
    ])
  end

  # A live page's unpublish date is an unpublish (#2134); on a draft it is
  # anyone's to edit, so the row is about a published record.
  defp run(:unpublish_at, actor, ctx),
    do:
      ctx
      |> published!()
      |> CMS.update_page(%{unpublish_at: tomorrow()}, opts(actor, ctx))
      |> outcome()

  defp run(:restore_version, actor, ctx) do
    page = draft!(ctx)
    edited = CMS.update_page!(page, %{title: "Second"}, opts(ctx.admin, ctx))

    [first | _] =
      CMS.list_page_versions!(opts(ctx.admin, ctx))
      |> Enum.filter(&(&1.version_source_id == page.id))
      |> Enum.sort_by(& &1.version_inserted_at, DateTime)

    edited |> CMS.restore_page_version(%{version_id: first.id}, opts(actor, ctx)) |> outcome()
  end

  defp run(:destroy_and_restore, actor, ctx) do
    trashed = draft!(ctx)
    :ok = CMS.destroy_page!(trashed, opts(ctx.admin, ctx))

    [in_trash] =
      CMS.list_trashed_pages!(opts(ctx.admin, ctx) ++ [query: [filter: [id: trashed.id]]])

    both([
      ctx |> draft!() |> CMS.destroy_page(opts(actor, ctx)),
      CMS.restore_page(in_trash, opts(actor, ctx))
    ])
  end

  # Saves the value the site already has, so the switch is checked without
  # flipping the mode the other rows run under.
  defp run(:publishing_switch, actor, ctx) do
    %{editors_can_publish: ctx.switch == :on}
    |> EditorialSettings.save(opts(actor, ctx))
    |> outcome()
  end

  # A compound row holds only when each of its actions agrees with the cell.
  defp both(results) do
    case results |> Enum.map(&outcome/1) |> Enum.uniq() do
      [one] -> one
      mixed -> flunk("the actions of one row disagree: #{inspect(mixed)}")
    end
  end

  defp outcome(:ok), do: :ok
  defp outcome({:ok, _}), do: :ok
  defp outcome({:error, %Ash.Error.Forbidden{}}), do: :forbidden
  defp outcome({:error, other}), do: flunk("expected ok or forbidden, got #{inspect(other)}")

  # ── Fixtures ───────────────────────────────────────────────────────────────

  defp opts(actor, ctx), do: [actor: actor, tenant: ctx.org.id]

  defp draft!(ctx, attrs \\ %{}),
    do: CMS.create_page!(Map.merge(%{title: "Draft", slug: slug()}, attrs), opts(ctx.admin, ctx))

  defp published!(ctx), do: ctx |> draft!() |> CMS.publish_page!(opts(ctx.admin, ctx))

  defp slug, do: "workflow-#{System.unique_integer([:positive])}"

  defp tomorrow, do: DateTime.add(DateTime.utc_now(), 1, :day)

  defp seed_org do
    Ash.Seed.seed!(Accounts.Organization, %{
      name: "Workflow Guide Site",
      slug: "workflow-guide-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  # A global `:viewer` whose tier on `org` comes from the membership alone.
  defp member(org, tier) do
    user =
      Ash.Seed.seed!(Accounts.User, %{
        email: "workflow-#{tier}-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :viewer
      })

    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: tier
    })

    user
  end

  defp allow_editors!(org, admin, value) do
    {:ok, _} = EditorialSettings.save(%{editors_can_publish: value}, actor: admin, tenant: org.id)
  end
end
