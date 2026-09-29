defmodule KilnCMS.Experiments.SystemActorAuthorizationTest do
  @moduledoc """
  What the experiment engine's own bookkeeping is *authorized* to do, now that
  delivery, the `:start` and variant-write guards and `mix kiln.experiment`
  run as `KilnCMS.Experiments.system/0` instead of
  `authorize?: false` (#1659, batch 5).

  Two halves, and both are the point:

    * **Grant and refusal.** Each of `Experiment`, `Variant` and `VariantDay`
      admits the system actor for a named list of actions. Every grant here
      sits next to a refusal: the system may start an experiment but not
      archive, edit or delete one; it may add a variant but not re-weight or
      remove one; it may bump the counters but not erase them. And the
      narrowing never leaks to a person below admin. Reads assert on the ROW,
      never on `{:ok, _}`, because a refused read under a filter policy comes
      back `{:ok, []}`.
    * **Failing closed.** Each read backs a decision whose permissive answer is
      `[]`: "nothing is running here", "0 served, 0 converted", "No experiments
      on this site". With the grant taken away (`Experiments.with_actor(nil,
      ...)`), each must raise or refuse — and delivery, which must never fail a
      page, must serve the canonical document and SAY so in the log.

  Removing any `KilnCMS.Checks.SystemActor` clause, any `forbid_unless`
  narrowing, or an `authorize_with: :error` at a call site must turn a test
  here red.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias KilnCMS.CMS
  alias KilnCMS.ExperimentFixtures
  alias KilnCMS.Experiments
  alias KilnCMS.Experiments.Delivery
  alias KilnCMS.Experiments.Promotion
  alias KilnCMS.Experiments.Results
  alias KilnCMS.SystemActor

  @moduletag :capture_log

  setup do
    org_id = KilnCMS.Accounts.default_org_id()
    KilnCMS.Cache.bust_experiments(org_id)
    %{org_id: org_id, admin: user(:admin)}
  end

  defp uniq, do: System.unique_integer([:positive])
  defp system, do: Experiments.system()

  # `mix kiln.experiment` (#1747): the writes and the results read are the
  # operator's alone, not delivery's.
  defp operator, do: Experiments.system(:operator)

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "xsa-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp page(admin) do
    %{title: "Target", slug: "xsa-#{uniq()}"}
    |> CMS.create_page!(actor: admin)
    |> CMS.publish_page!(%{}, actor: admin)
  end

  defp draft(org_id, admin, opts \\ []) do
    doc = Keyword.get_lazy(opts, :doc, fn -> page(admin) end)

    Experiments.create_experiment!(
      %{
        name: "xsa-#{uniq()}",
        content_type: "page",
        document_id: doc.id,
        goal: :form_submission,
        goal_form_id: ExperimentFixtures.goal_form!(org_id).id
      },
      actor: admin,
      tenant: org_id
    )
  end

  defp with_arms(experiment, org_id) do
    ExperimentFixtures.variant!(experiment, "Control", %{}, org_id, control: true)
    ExperimentFixtures.variant!(experiment, "Treatment", %{}, org_id, [])
    experiment
  end

  defp ids(rows), do: Enum.map(rows, & &1.id)

  test "system/0 is a system actor labelled :experiments; the task labels itself :operator" do
    assert %SystemActor{subsystem: :experiments} = Experiments.system()
    assert %SystemActor{subsystem: :operator} = Experiments.system(:operator)
  end

  test "with_actor/2 restores the real actor afterwards, even when the block raises" do
    assert_raise RuntimeError, fn -> Experiments.with_actor(nil, fn -> raise "boom" end) end
    assert %SystemActor{subsystem: :experiments} = Experiments.system()
  end

  describe "Experiment: read, create, start, conclude — never edit, archive or delete" do
    test "the system reads the running set and a single experiment", ctx do
      {experiment, _control, _treatment} =
        ExperimentFixtures.running!(page(ctx.admin), "page", %{})

      assert experiment.id in ids(
               Experiments.running_experiments!(actor: system(), tenant: ctx.org_id)
             )

      assert {:ok, %{id: id}} =
               Experiments.get_experiment(experiment.id, actor: system(), tenant: ctx.org_id)

      assert id == experiment.id
    end

    test "the system creates, starts and concludes an experiment", ctx do
      doc = page(ctx.admin)

      created =
        Experiments.create_experiment!(
          %{
            name: "xsa-sys-#{uniq()}",
            content_type: "page",
            document_id: doc.id,
            goal_form_id: ExperimentFixtures.goal_form!(ctx.org_id).id
          },
          actor: operator(),
          tenant: ctx.org_id
        )

      with_arms(created, ctx.org_id)

      assert {:ok, %{state: :running} = started} =
               Experiments.start_experiment(created, actor: operator(), tenant: ctx.org_id)

      assert {:ok, %{state: :concluded}} =
               Experiments.conclude_experiment(started, nil,
                 actor: operator(),
                 tenant: ctx.org_id
               )
    end

    test "delivery's actor may not create, start or conclude one", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               Experiments.create_experiment(
                 %{
                   name: "xsa-dlv-#{uniq()}",
                   content_type: "page",
                   document_id: page(ctx.admin).id,
                   goal_form_id: ExperimentFixtures.goal_form!(ctx.org_id).id
                 },
                 actor: system(),
                 tenant: ctx.org_id
               )

      armed = ctx.org_id |> draft(ctx.admin) |> with_arms(ctx.org_id)

      assert {:error, %Ash.Error.Forbidden{}} =
               Experiments.start_experiment(armed, actor: system(), tenant: ctx.org_id)
    end

    test "the system may not edit, archive or delete an experiment", ctx do
      experiment = draft(ctx.org_id, ctx.admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               Experiments.update_experiment(experiment, %{name: "renamed"},
                 actor: system(),
                 tenant: ctx.org_id
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Experiments.archive_experiment(experiment, actor: system(), tenant: ctx.org_id)

      assert {:error, %Ash.Error.Forbidden{}} =
               Experiments.destroy_experiment(experiment, actor: system(), tenant: ctx.org_id)
    end

    test "the narrowing admits no person below admin", ctx do
      editor = user(:editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               Experiments.create_experiment(
                 %{
                   name: "xsa-ed-#{uniq()}",
                   content_type: "page",
                   document_id: Ash.UUID.generate()
                 },
                 actor: editor,
                 tenant: ctx.org_id
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               ctx.org_id
               |> draft(ctx.admin)
               |> with_arms(ctx.org_id)
               |> Experiments.start_experiment(actor: editor, tenant: ctx.org_id)
    end
  end

  describe "Variant: read and create — never re-weight or remove" do
    test "the system reads and adds a variant", ctx do
      experiment = draft(ctx.org_id, ctx.admin)

      variant =
        Experiments.create_variant!(
          %{experiment_id: experiment.id, name: "Sys", control: true},
          actor: operator(),
          tenant: ctx.org_id
        )

      assert variant.id in ids(Experiments.list_variants!(actor: system(), tenant: ctx.org_id))
    end

    test "the system may not update or destroy a variant, and an editor may not add one", ctx do
      experiment = draft(ctx.org_id, ctx.admin)
      variant = ExperimentFixtures.variant!(experiment, "Control", %{}, ctx.org_id, control: true)

      assert {:error, %Ash.Error.Forbidden{}} =
               Experiments.update_variant(variant, %{weight: 5},
                 actor: system(),
                 tenant: ctx.org_id
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Experiments.destroy_variant(variant, actor: system(), tenant: ctx.org_id)

      assert {:error, %Ash.Error.Forbidden{}} =
               Experiments.create_variant(
                 %{experiment_id: experiment.id, name: "Ed"},
                 actor: user(:editor),
                 tenant: ctx.org_id
               )
    end
  end

  describe "VariantDay: the two counters and a read — never erase a result" do
    test "the system bumps both counters and reads the row back", ctx do
      variant_id = Ash.UUID.generate()

      Experiments.record_impression!(variant_id, actor: system(), tenant: ctx.org_id)
      Experiments.record_conversion!(variant_id, actor: system(), tenant: ctx.org_id)

      assert [%{impressions: 1, conversions: 1}] =
               Experiments.list_variant_days!(
                 query: [filter: [variant_id: variant_id]],
                 actor: operator(),
                 tenant: ctx.org_id
               )
    end

    test "the system may not destroy a counter row, and an editor may not write one", ctx do
      variant_id = Ash.UUID.generate()
      row = Experiments.record_impression!(variant_id, actor: system(), tenant: ctx.org_id)

      assert {:error, %Ash.Error.Forbidden{}} =
               Experiments.destroy_variant_day(row, actor: system(), tenant: ctx.org_id)

      assert {:error, %Ash.Error.Forbidden{}} =
               Experiments.record_impression(variant_id, actor: user(:editor), tenant: ctx.org_id)
    end
  end

  describe "failing closed when the grant is missing" do
    test "delivery serves the canonical document and LOGS it, rather than going quiet", ctx do
      ExperimentFixtures.enable!()
      doc = page(ctx.admin)
      {_experiment, _control, treatment} = ExperimentFixtures.pinned!(doc, "page", %{})

      # With the grant: the pinned arm is served, and its impression counted.
      assert %{id: served} = Delivery.assign_keyed("page", doc, "visitor-1")
      assert served == treatment.id

      assert [%{impressions: 1}] =
               Experiments.list_variant_days!(
                 query: [filter: [variant_id: treatment.id]],
                 actor: operator(),
                 tenant: ctx.org_id
               )

      # Without it: the running-set read raises (not `[]`) into the rescue,
      # which serves the canonical document and says why. The cache stays ON —
      # the loader runs in the courier process, the production shape.
      KilnCMS.Cache.bust_experiments(ctx.org_id)

      log =
        capture_log(fn ->
          assert Experiments.with_actor(nil, fn -> Delivery.assign_keyed("page", doc, "v-2") end) ==
                   nil
        end)

      assert log =~ "Experiments.running/1 could not read"

      # And the failure was not cached as "nothing is running": with the grant
      # back, the very next request serves the arm again.
      assert %{id: ^served} = Delivery.assign_keyed("page", doc, "visitor-1")
    end

    test "a refused counter write is logged, not swallowed", ctx do
      ExperimentFixtures.enable!()
      doc = page(ctx.admin)
      {_experiment, _control, treatment} = ExperimentFixtures.pinned!(doc, "page", %{})

      # Warm the running set with the grant, so only the WRITE is refused.
      assert Experiments.running(ctx.org_id) != []

      log =
        capture_log(fn ->
          Experiments.with_actor(nil, fn -> Delivery.assign_keyed("page", doc, "v-3") end)
        end)

      assert log =~ "could not record an impression"

      assert [] =
               Experiments.list_variant_days!(
                 query: [filter: [variant_id: treatment.id]],
                 actor: operator(),
                 tenant: ctx.org_id
               )
    end

    test "`:start` is refused as Forbidden, not a plausible-looking validation error", ctx do
      experiment = ctx.org_id |> draft(ctx.admin) |> with_arms(ctx.org_id)

      # Returned, not raised, so `start_experiment/2` keeps its tuple contract.
      assert {:error, %Ash.Error.Forbidden{}} =
               Experiments.with_actor(nil, fn ->
                 Experiments.start_experiment(experiment, actor: ctx.admin, tenant: ctx.org_id)
               end)

      assert {:ok, %{state: :running}} =
               Experiments.start_experiment(experiment, actor: ctx.admin, tenant: ctx.org_id)
    end

    test "a variant write whose parent cannot be read is refused", ctx do
      experiment = draft(ctx.org_id, ctx.admin)

      assert {:error, error} =
               Experiments.with_actor(nil, fn ->
                 Experiments.create_variant(
                   %{experiment_id: experiment.id, name: "Blind", control: true},
                   actor: ctx.admin,
                   tenant: ctx.org_id
                 )
               end)

      assert Exception.message(error) =~ "could not read experiment"
    end

    test "the results panel raises rather than reporting 0 served on every arm", ctx do
      {experiment, control, _treatment} =
        ExperimentFixtures.running!(page(ctx.admin), "page", %{})

      Experiments.record_impression!(control.id, actor: system(), tenant: ctx.org_id)

      loaded =
        Experiments.get_experiment!(experiment.id,
          load: [:variants],
          actor: ctx.admin,
          tenant: ctx.org_id
        )

      assert Results.summarize(loaded, ctx.org_id, ctx.admin).total_impressions == 1

      # Read as the viewer: one who may not read the counters gets a raise.
      assert_raise Ash.Error.Forbidden, fn ->
        Results.summarize(loaded, ctx.org_id, user(:viewer))
      end
    end

    test "mix kiln.experiment raises rather than answering \"No experiments\"", ctx do
      experiment = draft(ctx.org_id, ctx.admin)

      assert capture_io(fn -> Mix.Tasks.Kiln.Experiment.run(["list"]) end) =~ experiment.name

      assert_raise Ash.Error.Forbidden, fn ->
        Experiments.with_actor(nil, fn ->
          capture_io(fn -> Mix.Tasks.Kiln.Experiment.run(["list"]) end)
        end)
      end
    end
  end

  describe "promotion reads the winner as the promoting editor" do
    test "an actor who cannot read the variants gets :winner_missing, never a guess", ctx do
      doc = page(ctx.admin)
      {experiment, _control, treatment} = ExperimentFixtures.running!(doc, "page", %{})

      concluded =
        Experiments.conclude_experiment!(experiment, treatment.id,
          actor: ctx.admin,
          tenant: ctx.org_id
        )

      # Variants not loaded on the struct, so `Promotion` loads them itself.
      assert {:error, :winner_missing} =
               Promotion.promote(concluded, actor: user(:viewer), tenant: ctx.org_id)
    end
  end
end
