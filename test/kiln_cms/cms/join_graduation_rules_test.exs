defmodule KilnCMS.CMS.JoinGraduationRulesTest do
  @moduledoc """
  A graduated field keeps its target rules (#2024): the join resource
  `mix kiln.gen.join` generates for a field with `on_target_delete:
  :restrict` still refuses the purge of a connected target, with the field's
  own error, and one for a field with `max_sources` still refuses the
  connection past the cap.

  The resource is the generator's own output over a throwaway table
  (`KilnCMS.JoinProbe`). The race under the cap is in
  `KilnCMS.CMS.JoinSourceCapRaceTest`.

  Not async: the probe's domain joins the VM-global `:ash_domains`.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Errors.TargetStillConnected
  alias KilnCMS.CMS.JoinGraduation
  alias KilnCMS.CMS.Preparations.SkipRestrictedTargets
  alias KilnCMS.JoinProbe

  defp admin! do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "graduated-rules-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "graduated-#{System.unique_integer([:positive])}"

  defp page!(admin), do: CMS.create_page!(%{title: "Target", slug: slug()}, actor: admin)
  defp post!(admin), do: CMS.create_post!(%{title: "Source", slug: slug()}, actor: admin)

  # A reference field of post → page with `rules`, graduated: its join
  # resource and table. Retired too, as graduation ends: from here the join
  # table is the one copy, and the rule must hold there alone.
  defp graduate!(admin, rules) do
    name = "seats#{System.unique_integer([:positive])}"

    field =
      CMS.create_field_definition!(
        Map.merge(
          %{
            content_type: :post,
            name: name,
            label: "Seats",
            field_type: :reference,
            target_type: "page"
          },
          rules
        ),
        actor: admin
      )

    {:ok, spec} = JoinGraduation.resolve("post.#{name}")
    spec = JoinProbe.build!(spec)
    CMS.destroy_field_definition!(field, actor: admin)
    spec
  end

  setup do
    admin = admin!()
    %{admin: admin, opts: [actor: admin, tenant: KilnCMS.Accounts.default_org_id()]}
  end

  describe "on_target_delete: :restrict, graduated" do
    setup %{admin: admin} do
      %{spec: graduate!(admin, %{on_target_delete: :restrict, label: "Seats"})}
    end

    test "refuses the purge of a connected target, with the field's own error", ctx do
      target = page!(ctx.admin)
      {:ok, _} = JoinProbe.connect(ctx.spec, post!(ctx.admin), target, ctx.opts)
      {:ok, _} = JoinProbe.connect(ctx.spec, post!(ctx.admin), target, ctx.opts)

      assert JoinGraduation.join_resources() |> Enum.member?(ctx.spec.module)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               CMS.purge_page(target, actor: ctx.admin)

      assert [%TargetStillConnected{field_label: "Seats", count: 2}] =
               Enum.filter(errors, &match?(%TargetStillConnected{}, &1))

      assert {:ok, _still_there} = CMS.get_page(target.id, actor: ctx.admin)
    end

    test "lets the target go once nothing connects to it", ctx do
      target = page!(ctx.admin)
      {:ok, link} = JoinProbe.connect(ctx.spec, post!(ctx.admin), target, ctx.opts)
      Ash.destroy!(link, ctx.opts)

      assert :ok = CMS.purge_page!(target, actor: ctx.admin)
    end

    test "a self-connection does not hold the record", ctx do
      assert JoinGraduation.check_restrict(post!(ctx.admin)) == :ok
    end

    test "purging the source is not refused, and takes its connections", ctx do
      target = page!(ctx.admin)
      source = post!(ctx.admin)
      {:ok, _} = JoinProbe.connect(ctx.spec, source, target, ctx.opts)

      assert :ok = CMS.purge_post!(source, actor: ctx.admin)
      assert JoinGraduation.connected_sources(ctx.spec.module, target.id, target.org_id) == []
    end

    test "the nightly purge leaves the held target out", ctx do
      held = page!(ctx.admin)
      free = page!(ctx.admin)
      {:ok, _} = JoinProbe.connect(ctx.spec, post!(ctx.admin), held, ctx.opts)

      ids = SkipRestrictedTargets.restricted_target_ids(held.org_id)
      assert held.id in ids
      refute free.id in ids
    end
  end

  describe "on_target_delete: :clear, graduated" do
    test "the target's purge takes its connections with it", ctx do
      spec = graduate!(ctx.admin, %{on_target_delete: :clear})
      target = page!(ctx.admin)
      {:ok, _} = JoinProbe.connect(spec, post!(ctx.admin), target, ctx.opts)

      assert :ok = CMS.purge_page!(target, actor: ctx.admin)
      assert JoinGraduation.connected_sources(spec.module, target.id, target.org_id) == []
    end
  end

  describe "max_sources, graduated" do
    setup %{admin: admin} do
      %{spec: graduate!(admin, %{max_sources: 2})}
    end

    test "refuses a connection past the cap, naming the count", ctx do
      target = page!(ctx.admin)
      {:ok, _} = JoinProbe.connect(ctx.spec, post!(ctx.admin), target, ctx.opts)
      {:ok, _} = JoinProbe.connect(ctx.spec, post!(ctx.admin), target, ctx.opts)

      assert {:error, %Ash.Error.Invalid{} = error} =
               JoinProbe.connect(ctx.spec, post!(ctx.admin), target, ctx.opts)

      assert Exception.message(error) =~
               "Seats (#{ctx.spec.field}) — the chosen record is full: it already has " <>
                 "2 of 2 connected through this field"

      assert length(JoinGraduation.connected_sources(ctx.spec.module, target.id, target.org_id)) ==
               2
    end

    test "counts per target", ctx do
      [one, two] = [page!(ctx.admin), page!(ctx.admin)]

      for target <- [one, one, two, two] do
        assert {:ok, _} = JoinProbe.connect(ctx.spec, post!(ctx.admin), target, ctx.opts)
      end
    end

    test "frees the slot when a connection goes", ctx do
      target = page!(ctx.admin)
      {:ok, first} = JoinProbe.connect(ctx.spec, post!(ctx.admin), target, ctx.opts)
      {:ok, _} = JoinProbe.connect(ctx.spec, post!(ctx.admin), target, ctx.opts)
      Ash.destroy!(first, ctx.opts)

      assert {:ok, _} = JoinProbe.connect(ctx.spec, post!(ctx.admin), target, ctx.opts)
    end
  end

  test "no max_sources: no cap", ctx do
    spec = graduate!(ctx.admin, %{})
    target = page!(ctx.admin)

    for _ <- 1..4 do
      assert {:ok, _} = JoinProbe.connect(spec, post!(ctx.admin), target, ctx.opts)
    end
  end
end
