defmodule KilnCMS.Analytics.FunnelSystemActorTest do
  @moduledoc """
  The funnel-definition reads system code makes (#1659 batch 11b): the
  experiment engine resolving a `:funnel_completion` goal — delivery's cached
  target map and the `:start` guard — and `mix kiln.experiment` resolving
  `--goal-funnel SLUG`. Each runs as `KilnCMS.Analytics.system/1` under a
  read-only grant on `Funnel` and `FunnelStep`, and each fails CLOSED when the
  grant is missing (`KilnCMS.Analytics.with_actor/2` takes it away).

  `async: false`: `with_actor/2` and the experiments config are VM-global, and
  the mix task writes through `Mix.shell()`.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias KilnCMS.Analytics
  alias KilnCMS.Analytics.Funnel
  alias KilnCMS.Analytics.FunnelStep
  alias KilnCMS.ExperimentFixtures
  alias KilnCMS.Experiments

  setup do
    actor =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "funnel-sa-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    [first, last, landing] = for _ <- 1..3, do: published_page(actor)
    org_id = landing.org_id
    funnel = ExperimentFixtures.funnel_ending_at(first, last, org_id)

    %{org_id: org_id, funnel: funnel, first: first, last: last, landing: landing}
  end

  defp published_page(actor) do
    %{title: "Funnel SA", slug: "funnel-sa-#{System.unique_integer([:positive])}"}
    |> KilnCMS.CMS.create_page!(actor: actor)
    |> KilnCMS.CMS.publish_page!(%{}, actor: actor)
  end

  describe "the grant" do
    test "admits the system actor to the primary read of Funnel and FunnelStep", ctx do
      system = Analytics.system(:experiments)

      # Real reads, failing closed: `Ash.can?/3` on a read answers `true` for
      # any actor whose refusal would merely filter, so it proves nothing here.
      assert [_, _] =
               Ash.read!(FunnelStep, actor: system, authorize_with: :error, tenant: ctx.org_id)

      assert [%{id: id, steps: [_, _]}] =
               Analytics.list_funnels!(
                 actor: system,
                 authorize_with: :error,
                 tenant: ctx.org_id,
                 load: [:steps]
               )

      assert id == ctx.funnel.id
    end

    test "refuses the system actor every write, and the builder's :for_funnel read", ctx do
      system = Analytics.system(:experiments)

      [step | _] =
        Analytics.funnel_steps_for!(ctx.funnel.id, authorize?: false, tenant: ctx.org_id)

      refute Ash.can?({Funnel, :create, %{name: "X", slug: "x"}}, system, tenant: ctx.org_id)
      refute Ash.can?({ctx.funnel, :update, %{active: false}}, system, tenant: ctx.org_id)
      refute Ash.can?({ctx.funnel, :destroy}, system, tenant: ctx.org_id)

      refute Ash.can?({FunnelStep, :create, %{}}, system, tenant: ctx.org_id)
      refute Ash.can?({step, :update, %{position: 5}}, system, tenant: ctx.org_id)
      refute Ash.can?({step, :destroy}, system, tenant: ctx.org_id)

      assert {:error, %Ash.Error.Forbidden{}} =
               Analytics.funnel_steps_for(ctx.funnel.id,
                 actor: system,
                 authorize_with: :error,
                 tenant: ctx.org_id
               )
    end
  end

  describe "Experiments.funnel_targets/1 (delivery)" do
    test "resolves each funnel's last step as the system actor", ctx do
      KilnCMS.Cache.bust_funnel_targets(ctx.org_id)

      assert Experiments.funnel_targets(ctx.org_id) == %{
               ctx.funnel.id => {"page", ctx.last.id}
             }
    end

    test "fails closed without the grant: logged and not cached, never an empty map kept",
         ctx do
      KilnCMS.Cache.bust_funnel_targets(ctx.org_id)

      log =
        capture_log(fn ->
          assert Analytics.with_actor(nil, fn -> Experiments.funnel_targets(ctx.org_id) end) ==
                   %{}
        end)

      assert log =~ "funnel_targets/1 could not read"

      # A refused read that filtered to `[]` would have been committed to the
      # cache as `%{}`; the retry here proves nothing was kept.
      assert Experiments.funnel_targets(ctx.org_id) == %{
               ctx.funnel.id => {"page", ctx.last.id}
             }
    end
  end

  describe "the :start guard (GoalConfigured)" do
    setup do
      ExperimentFixtures.put_config(sticky: false)
      :ok
    end

    # Sticky assignment is off, so a funnel that the guard CAN read is refused
    # for that, later in the chain; one it cannot read is refused as missing.
    test "reads the goal funnel as the system actor", ctx do
      assert {:error, error} = start_funnel(ctx)
      assert Exception.message(error) =~ "sticky"
    end

    test "fails closed without the grant", ctx do
      assert {:error, error} = Analytics.with_actor(nil, fn -> start_funnel(ctx) end)
      assert Exception.message(error) =~ "no funnel"
    end
  end

  describe "mix kiln.experiment --goal-funnel SLUG" do
    setup do
      ExperimentFixtures.put_config(sticky: true)
      :ok
    end

    test "resolves the slug as the operator", ctx do
      name = "fsa-#{System.unique_integer([:positive])}"

      capture_io(fn -> run_create(ctx, name) end)

      assert [%{goal_funnel_id: funnel_id}] =
               Experiments.list_experiments!(authorize?: false, tenant: ctx.org_id)
               |> Enum.filter(&(&1.name == name))

      assert funnel_id == ctx.funnel.id
    end

    test "fails closed without the grant: an error, not \"No funnel with id or slug\"", ctx do
      error =
        assert_raise Ash.Error.Forbidden, fn ->
          Analytics.with_actor(nil, fn ->
            capture_io(fn -> run_create(ctx, "fsa-#{System.unique_integer([:positive])}") end)
          end)
        end

      refute Exception.message(error) =~ "No funnel"
    end
  end

  # Not a funnel read, but the same batch: `mix kiln.gen.content --from NAME`
  # reads the dynamic type's definition as the operator, under
  # `TypeDefinition`'s existing read-only system-actor grant, where it used to
  # pass `authorize?: false`. The call below is the task's own call.
  describe "mix kiln.gen.content --from NAME" do
    test "reads the type definition as the operator; no actor reads nothing", ctx do
      name = "sa#{System.unique_integer([:positive])}"

      KilnCMS.CMS.create_type_definition!(%{name: name, label: "SA"},
        authorize?: false,
        tenant: ctx.org_id
      )

      operator = KilnCMS.SystemActor.new(:operator)
      assert %{name: ^name} = KilnCMS.CMS.get_type_definition_by_name!(name, actor: operator)

      assert_raise Ash.Error.Invalid, fn ->
        KilnCMS.CMS.get_type_definition_by_name!(name, actor: nil)
      end
    end
  end

  defp run_create(ctx, name) do
    Mix.Tasks.Kiln.Experiment.run([
      "create",
      name,
      "--org-id",
      ctx.org_id,
      "--type",
      "page",
      "--document",
      ctx.landing.id,
      "--goal",
      "funnel_completion",
      "--goal-funnel",
      ctx.funnel.slug
    ])
  end

  defp start_funnel(ctx) do
    experiment =
      Experiments.create_experiment!(
        %{
          name: "fsa-#{System.unique_integer([:positive])}",
          content_type: "page",
          document_id: ctx.landing.id,
          goal: :funnel_completion,
          goal_funnel_id: ctx.funnel.id
        },
        authorize?: false,
        tenant: ctx.org_id
      )

    ExperimentFixtures.variant!(experiment, "Control", %{}, ctx.org_id, control: true)
    ExperimentFixtures.variant!(experiment, "Treatment", %{}, ctx.org_id, [])

    Experiments.start_experiment(experiment, authorize?: false, tenant: ctx.org_id)
  end
end
