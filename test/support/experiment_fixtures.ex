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
        %{
          name: Keyword.get(opts, :name, "exp-#{System.unique_integer([:positive])}"),
          content_type: content_type,
          document_id: document.id,
          goal: Keyword.get(opts, :goal, :form_submission)
        },
        authorize?: false,
        tenant: org_id
      )

    control = variant!(experiment, "Control", %{}, org_id, control: true)
    treatment = variant!(experiment, "Treatment", patch, org_id, [])

    {:ok, started} =
      Experiments.start_experiment(experiment, authorize?: false, tenant: org_id)

    KilnCMS.Cache.bust_experiments(org_id)

    {started, control, treatment}
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

  @doc "Force every request to resolve to one variant, by zeroing the others."
  @spec pin!(struct(), [struct()], Ash.UUID.t()) :: :ok
  def pin!(winner, others, org_id) do
    Enum.each(others, fn variant ->
      if variant.id != winner.id do
        Experiments.update_variant!(variant, %{weight: 0}, authorize?: false, tenant: org_id)
      end
    end)

    KilnCMS.Cache.bust_experiments(org_id)
    :ok
  end
end
