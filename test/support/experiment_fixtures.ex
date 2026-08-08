defmodule KilnCMS.ExperimentFixtures do
  @moduledoc """
  Test scaffolding for content experiments (#499).

  Experiments are off in `config/test.exs`, matching production. A test that
  wants one turns the deployment switch on for its own duration — leaving it on
  globally would make every delivery request in the suite consult the
  running-experiment cache and would flip experimented pages to `no-store` under
  tests that assert cache headers.
  """

  alias KilnCMS.Experiments

  @doc "Turn the deployment-wide switch on for this test only."
  @spec enable!() :: :ok
  def enable! do
    original = Application.get_env(:kiln_cms, KilnCMS.Experiments, [])
    Application.put_env(:kiln_cms, KilnCMS.Experiments, Keyword.put(original, :enabled, true))

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Experiments, original)
      KilnCMS.Cache.bust_experiments(KilnCMS.Accounts.default_org_id())
    end)

    :ok
  end

  @doc """
  A running experiment on `document`, with a control and one patched variant.

  Returns `{experiment, control, variant}`.
  """
  @spec running!(struct(), String.t(), map(), keyword()) :: {struct(), struct(), struct()}
  def running!(document, content_type, patch, opts \\ []) do
    org_id = Keyword.get(opts, :org_id, document.org_id)

    experiment =
      Experiments.create_experiment!(
        Map.merge(
          %{
            name: Keyword.get(opts, :name, "exp-#{System.unique_integer([:positive])}"),
            content_type: content_type,
            document_id: document.id
          },
          goal_attrs(org_id, opts)
        ),
        authorize?: false,
        tenant: org_id
      )

    control =
      variant!(experiment, "Control", %{}, org_id,
        control: true,
        weight: Keyword.get(opts, :control_weight, 1)
      )

    treatment = variant!(experiment, "Treatment", patch, org_id, [])

    {:ok, started} =
      Experiments.start_experiment(experiment, authorize?: false, tenant: org_id)

    KilnCMS.Cache.bust_experiments(org_id)

    {started, control, treatment}
  end

  # A content-view experiment converts on a different document and has no goal
  # form; a form-submission one is the reverse. Building the wrong pair would be
  # refused by `:start`, so the fixture builds whichever the goal calls for.
  defp goal_attrs(org_id, opts) do
    case Keyword.get(opts, :goal, :form_submission) do
      :content_view ->
        %{
          goal: :content_view,
          goal_content_type: Keyword.fetch!(opts, :goal_content_type),
          goal_document_id: Keyword.fetch!(opts, :goal_document_id)
        }

      goal ->
        %{
          goal: goal,
          goal_form_id: Keyword.get_lazy(opts, :goal_form_id, fn -> goal_form!(org_id).id end)
        }
    end
  end

  @doc """
  A form for an experiment's goal.

  `:start` requires one, because a form-submission experiment with no goal form
  converts nothing and would report 0.0% forever.
  """
  @spec goal_form!(Ash.UUID.t()) :: struct()
  def goal_form!(org_id) do
    KilnCMS.CMS.create_form!(
      %{name: "Goal", slug: "goal-#{System.unique_integer([:positive])}"},
      authorize?: false,
      tenant: org_id
    )
  end

  @doc "Add a variant to an experiment."
  @spec variant!(struct(), String.t(), map(), Ash.UUID.t(), keyword()) :: struct()
  def variant!(experiment, name, patch, org_id, opts) do
    Experiments.create_variant!(
      %{
        experiment_id: experiment.id,
        name: name,
        patch: patch,
        weight: Keyword.get(opts, :weight, 1),
        control: Keyword.get(opts, :control, false)
      },
      authorize?: false,
      tenant: org_id
    )
  end

  @doc """
  A running experiment whose every request resolves to the **treatment**.

  Weights are set before `:start`, because a running experiment's variants are
  immutable — the split is the experiment, and editing it mid-flight would make
  the counts uninterpretable. A test that wants a deterministic arm therefore
  has to say so up front, exactly as an editor would.

  Returns `{experiment, control, treatment}`.
  """
  @spec pinned!(struct(), String.t(), map(), keyword()) :: {struct(), struct(), struct()}
  def pinned!(document, content_type, patch, opts \\ []) do
    running!(document, content_type, patch, Keyword.put(opts, :control_weight, 0))
  end
end
