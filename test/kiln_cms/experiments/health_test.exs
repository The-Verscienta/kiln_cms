defmodule KilnCMS.Experiments.HealthTest do
  @moduledoc """
  A running experiment that can no longer convert says so (#1008).

  Most cases here start from an experiment that `:start` accepted, and then break
  one premise the way an operator or an editor actually would: turning sticky
  off, unpublishing a document, deactivating the goal form, re-ordering the
  funnel. The experiment still reads `running` afterwards, and before this
  module nothing anywhere said the numbers had stopped meaning anything.

  **Four cases are not like that**, and it is worth saying which. `:goal_is_self`,
  `:no_target`, `:no_goal_form` and `:no_goal_funnel` cannot be produced by any
  supported write to a *running* experiment: `GoalConfigured` refuses each at
  `:start`, and `update :update` carries `validate attribute_equals(:state,
  :draft)` while `:start`/`:conclude`/`:archive` all `accept []`. Their tests
  therefore build the struct by hand, which is defensive coverage of a guard —
  not evidence of a live path. They are kept because the cost is one comparison
  and the alternative is trusting that no legacy row, seed or direct-SQL write
  ever produced one.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.ExperimentFixtures
  alias KilnCMS.Experiments

  setup do
    ExperimentFixtures.enable!()
    org_id = KilnCMS.Accounts.default_org_id()
    %{org_id: org_id, actor: admin()}
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "health-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp put_experiments(overrides) do
    original = Application.get_env(:kiln_cms, KilnCMS.Experiments, [])
    Application.put_env(:kiln_cms, KilnCMS.Experiments, Keyword.merge(original, overrides))
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Experiments, original) end)
  end

  # PUBLISHED, because a draft page serves nobody and is now a reason in its own
  # right. Every test that wants a healthy experiment therefore has to publish
  # both documents — which is the honest fixture: this is what a real running
  # experiment looks like.
  defp page(actor, title \\ "Page") do
    %{title: title, slug: "health-#{System.unique_integer([:positive])}"}
    |> CMS.create_page!(actor: actor)
    |> CMS.publish_page!(%{}, actor: actor)
  end

  defp draft_page(actor) do
    CMS.create_page!(
      %{title: "Draft", slug: "health-draft-#{System.unique_integer([:positive])}"},
      actor: actor
    )
  end

  # Re-read from the database so the struct under test is the one a surface
  # would hold, not the one the fixture happened to return.
  defp reload(experiment, org_id) do
    Experiments.get_experiment!(experiment.id, authorize?: false, tenant: org_id)
  end

  # The struct the surfaces ACTUALLY hold: `blocked/1`, the overview strip and
  # `mix kiln.experiment list` all read through `Experiments.running/1`, never
  # through the struct `start_experiment` returned. Tests that only ever pass
  # the fixture's struct cannot see a `select` narrowing the `:running` read —
  # the exact regression that made #1000's fix inert.
  defp as_surfaces_see(experiment, org_id) do
    org_id
    |> Experiments.running()
    |> Enum.find(&(&1.id == experiment.id))
  end

  describe "a healthy experiment" do
    test "reports nothing", ctx do
      {experiment, _control, _treatment} =
        ExperimentFixtures.running!(page(ctx.actor), "page", %{}, org_id: ctx.org_id)

      assert Experiments.blocked_reason(experiment) == nil
      assert Experiments.blocked(ctx.org_id) == []
    end

    test "a draft is never reported, however broken its goal", ctx do
      # A draft with no goal form is unfinished, not broken, and `:start` is
      # where that is caught. Reporting it here would put a permanent warning
      # next to every half-built experiment — the fastest way to teach an editor
      # to ignore the one that matters.
      draft =
        Experiments.create_experiment!(
          %{
            name: "d-#{System.unique_integer([:positive])}",
            content_type: "page",
            document_id: Ash.UUID.generate()
          },
          authorize?: false,
          tenant: ctx.org_id
        )

      assert draft.state == :draft
      assert draft.goal_form_id == nil
      assert Experiments.blocked_reason(draft) == nil
    end
  end

  describe "the deployment switch" do
    test "is not a per-experiment reason, and does not mask a real one", ctx do
      # It is a SITE-WIDE fact, and folding it in here made every row say the
      # same thing on a deployment whose default is off — and, because it
      # short-circuited, hid the real reasons until the flag was flipped. Each
      # surface reports it once instead.
      form = ExperimentFixtures.goal_form!(ctx.org_id)

      {experiment, _control, _treatment} =
        ExperimentFixtures.running!(page(ctx.actor), "page", %{},
          org_id: ctx.org_id,
          goal_form_id: form.id
        )

      put_experiments(enabled: false)

      assert Experiments.blocked_reason(experiment) == nil

      # …and the real reason underneath is still reported, not concealed.
      CMS.destroy_form!(form, authorize?: false, tenant: ctx.org_id)

      assert {:goal_form_missing, _sentence} = Experiments.blocked_reason(experiment)
    end
  end

  describe "the experimented document" do
    test "a draft document blocks the experiment — no arm is ever served", ctx do
      # Delivery only reaches `for_document/3` from a published render, so an
      # experiment on a draft page serves nobody: zero impressions, zero
      # conversions, and before this every goal check below it read healthy.
      {experiment, _control, _treatment} =
        ExperimentFixtures.running!(draft_page(ctx.actor), "page", %{}, org_id: ctx.org_id)

      assert {:document_unpublished, sentence} = Experiments.blocked_reason(experiment)
      assert sentence =~ "draft"
    end

    test "unpublishing the document under test blocks it", ctx do
      # The most ordinary thing an editor does to the page under test, and the
      # one input nothing here used to look at. No write to the experiment.
      document = page(ctx.actor)

      {experiment, _control, _treatment} =
        ExperimentFixtures.running!(document, "page", %{}, org_id: ctx.org_id)

      assert Experiments.blocked_reason(experiment) == nil

      CMS.unpublish_page!(document, actor: ctx.actor)

      assert {:document_unpublished, _sentence} = Experiments.blocked_reason(experiment)
    end

    test "deleting the document under test blocks it", ctx do
      document = page(ctx.actor)

      {experiment, _control, _treatment} =
        ExperimentFixtures.running!(document, "page", %{}, org_id: ctx.org_id)

      CMS.destroy_page!(document, actor: ctx.actor)

      assert {:document_missing, _sentence} = Experiments.blocked_reason(experiment)
    end
  end

  describe "an unrecognised goal" do
    test "fails closed rather than reading as healthy", ctx do
      # A goal added to the resource without a clause in `Health` must not be
      # reported healthy forever — silence is what this module exists to end.
      {experiment, _control, _treatment} =
        ExperimentFixtures.running!(page(ctx.actor), "page", %{}, org_id: ctx.org_id)

      assert {:unknown_goal, _sentence} =
               Experiments.blocked_reason(%{experiment | goal: :scroll_depth})
    end
  end

  describe "sticky assignment turned off underneath a later-page goal" do
    setup ctx do
      put_experiments(sticky: true)
      goal = page(ctx.actor, "Goal")

      {experiment, _control, _treatment} =
        ExperimentFixtures.running!(page(ctx.actor), "page", %{},
          org_id: ctx.org_id,
          goal: :content_view,
          goal_content_type: "page",
          goal_document_id: goal.id
        )

      %{experiment: experiment}
    end

    test "is healthy while sticky is on", ctx do
      assert Experiments.blocked_reason(ctx.experiment) == nil
    end

    test "is blocked the moment sticky goes off — no write to the experiment", ctx do
      # This is the motivating case. `docs/data-flows.md` actively invites an
      # operator to gate `sticky` on their consent mechanism, so the flag going
      # off is a supported operation, not a mistake — and nothing about the
      # experiment row changes when it does.
      put_experiments(sticky: false)

      assert {:sticky_off, sentence} = Experiments.blocked_reason(ctx.experiment)
      assert sentence =~ "sticky"
      assert reload(ctx.experiment, ctx.org_id).state == :running
    end

    test "a form-submission goal is unaffected by sticky", ctx do
      # A form submission travels with the page that carried it, so it needs no
      # bucket cookie. Reporting it as blocked would be a false alarm on the
      # goal most experiments use.
      {form_experiment, _control, _treatment} =
        ExperimentFixtures.running!(page(ctx.actor), "page", %{}, org_id: ctx.org_id)

      put_experiments(sticky: false)

      assert Experiments.blocked_reason(form_experiment) == nil
    end
  end

  describe "a form goal that goes away" do
    test "a deleted goal form blocks the experiment", ctx do
      form = ExperimentFixtures.goal_form!(ctx.org_id)

      {experiment, _control, _treatment} =
        ExperimentFixtures.running!(page(ctx.actor), "page", %{},
          org_id: ctx.org_id,
          goal_form_id: form.id
        )

      assert Experiments.blocked_reason(experiment) == nil

      CMS.destroy_form!(form, authorize?: false, tenant: ctx.org_id)

      assert {:goal_form_missing, sentence} = Experiments.blocked_reason(experiment)
      assert sentence =~ form.id
    end

    test "a DEACTIVATED goal form blocks the experiment", ctx do
      # `Forms.submit/3` refuses an inactive form before `record/4`, the only
      # caller that counts a conversion. Deactivating is the reversible, common
      # action; deleting is the rare one, and only deleting used to be caught.
      form = ExperimentFixtures.goal_form!(ctx.org_id)

      {experiment, _control, _treatment} =
        ExperimentFixtures.running!(page(ctx.actor), "page", %{},
          org_id: ctx.org_id,
          goal_form_id: form.id
        )

      assert Experiments.blocked_reason(experiment) == nil

      CMS.update_form!(form, %{active: false}, authorize?: false, tenant: ctx.org_id)

      assert {:goal_form_inactive, sentence} = Experiments.blocked_reason(experiment)
      assert sentence =~ form.id
    end
  end

  describe "a content-view goal that goes away" do
    setup ctx do
      put_experiments(sticky: true)
      goal = page(ctx.actor, "Goal")

      {experiment, _control, _treatment} =
        ExperimentFixtures.running!(page(ctx.actor), "page", %{},
          org_id: ctx.org_id,
          goal: :content_view,
          goal_content_type: "page",
          goal_document_id: goal.id
        )

      %{experiment: experiment, goal: goal}
    end

    test "a deleted goal document blocks the experiment", ctx do
      CMS.destroy_page!(ctx.goal, actor: ctx.actor)

      assert {:goal_document_missing, sentence} = Experiments.blocked_reason(ctx.experiment)
      assert sentence =~ ctx.goal.id
    end

    test "an UNPUBLISHED goal document blocks the experiment", ctx do
      # `get_record/3` runs the primary read, which happily returns a draft —
      # but every conversion path resolves through a published-only read, so a
      # goal page that is merely unpublished converts nothing. Reachable with no
      # write to the experiment at all, including automatically by the
      # `unpublish_at` trigger.
      assert Experiments.blocked_reason(ctx.experiment) == nil

      CMS.unpublish_page!(ctx.goal, actor: ctx.actor)

      assert {:goal_document_unpublished, sentence} = Experiments.blocked_reason(ctx.experiment)
      assert sentence =~ "draft"
    end

    test "an unknown goal content type blocks the experiment", ctx do
      # Reachable after the fact by deleting a dynamic content type (D17) that a
      # running experiment converts on.
      broken = %{ctx.experiment | goal_content_type: "not-a-type"}

      assert {:goal_type_unknown, sentence} = Experiments.blocked_reason(broken)
      assert sentence =~ "not-a-type"
    end

    test "a goal that is the experimented document itself blocks it", ctx do
      broken = %{
        ctx.experiment
        | goal_content_type: ctx.experiment.content_type,
          goal_document_id: ctx.experiment.document_id
      }

      assert {:goal_is_self, sentence} = Experiments.blocked_reason(broken)
      assert sentence =~ "itself"
    end

    test "no goal document at all blocks it", ctx do
      broken = %{ctx.experiment | goal_document_id: nil}

      assert {:no_target, _sentence} = Experiments.blocked_reason(broken)
    end
  end

  describe "a funnel goal that moves" do
    setup ctx do
      put_experiments(sticky: true)
      document = page(ctx.actor, "Document")
      first = page(ctx.actor, "First")
      last = page(ctx.actor, "Last")
      funnel = ExperimentFixtures.funnel_ending_at(first, last, ctx.org_id)

      {experiment, _control, _treatment} =
        ExperimentFixtures.running!(document, "page", %{},
          org_id: ctx.org_id,
          goal: :funnel_completion,
          goal_funnel_id: funnel.id
        )

      %{experiment: experiment, funnel: funnel, last: last, document: document}
    end

    test "is healthy while the funnel ends elsewhere", ctx do
      assert Experiments.blocked_reason(ctx.experiment) == nil
    end

    test "a deleted last step's document blocks it", ctx do
      # `FunnelStep` is FK-less by design, so the step survives the document and
      # the funnel keeps resolving to an id nothing answers to.
      CMS.destroy_page!(ctx.last, actor: ctx.actor)
      KilnCMS.Cache.bust_funnel_targets(ctx.org_id)

      assert {:funnel_target_missing, sentence} = Experiments.blocked_reason(ctx.experiment)
      assert sentence =~ ctx.last.id
    end

    test "a funnel re-ordered to end on the experimented document blocks it", ctx do
      # Editing the funnel edits the goal — that is the feature (#1010), and it
      # is also how a healthy experiment becomes an unservable one with nobody
      # touching the experiment.
      KilnCMS.Analytics.create_funnel_step!(
        %{
          funnel_id: ctx.funnel.id,
          content_type: "page",
          content_id: ctx.document.id,
          position: 99
        },
        authorize?: false,
        tenant: ctx.org_id
      )

      KilnCMS.Cache.bust_funnel_targets(ctx.org_id)

      assert {:funnel_ends_here, sentence} = Experiments.blocked_reason(ctx.experiment)
      assert sentence =~ "itself"
    end

    test "no funnel at all blocks it", ctx do
      broken = %{ctx.experiment | goal_funnel_id: nil}

      assert {:no_goal_funnel, _sentence} = Experiments.blocked_reason(broken)
    end
  end

  describe "the struct the surfaces hold" do
    test "blocked_reason/1 agrees on the struct Experiments.running/1 returns", ctx do
      # `blocked/1`, the overview strip and `mix kiln.experiment list` all read
      # through `running/1`. If that action ever narrows its select, the fixture
      # struct would still carry the goal attributes and every other test here
      # would stay green while every surface reported a false reason.
      put_experiments(sticky: true)
      goal = page(ctx.actor, "Goal")

      {experiment, _control, _treatment} =
        ExperimentFixtures.running!(page(ctx.actor), "page", %{},
          org_id: ctx.org_id,
          goal: :content_view,
          goal_content_type: "page",
          goal_document_id: goal.id
        )

      served = as_surfaces_see(experiment, ctx.org_id)

      assert served, "the experiment is not in Experiments.running/1"
      assert Experiments.blocked_reason(served) == Experiments.blocked_reason(experiment)
      assert Experiments.blocked_reason(served) == nil

      CMS.unpublish_page!(goal, actor: ctx.actor)
      KilnCMS.Cache.bust_experiments(ctx.org_id)

      assert {:goal_document_unpublished, _sentence} =
               experiment |> as_surfaces_see(ctx.org_id) |> Experiments.blocked_reason()
    end
  end

  describe "blocked/1" do
    test "lists only the running experiments that cannot convert", ctx do
      put_experiments(sticky: true)
      goal = page(ctx.actor, "Goal")

      {healthy, _c, _t} =
        ExperimentFixtures.running!(page(ctx.actor), "page", %{}, org_id: ctx.org_id)

      {broken, _c, _t} =
        ExperimentFixtures.running!(page(ctx.actor), "page", %{},
          org_id: ctx.org_id,
          goal: :content_view,
          goal_content_type: "page",
          goal_document_id: goal.id
        )

      assert Experiments.blocked(ctx.org_id) == []

      put_experiments(sticky: false)

      assert [{listed, {:sticky_off, _sentence}}] = Experiments.blocked(ctx.org_id)
      assert listed.id == broken.id
      refute listed.id == healthy.id
    end
  end
end
