defmodule Mix.Tasks.Kiln.Experiment do
  @shortdoc "Create, start, inspect and conclude content experiments"
  @moduledoc """
  Operate A/B experiments from the command line (#499, phase 1).

      mix kiln.experiment list                          [--org-id UUID]
      mix kiln.experiment show    NAME                  [--org-id UUID]
      mix kiln.experiment create  NAME --type post --document UUID --form FORM_UUID
      mix kiln.experiment create  NAME --type post --document UUID \\
            --goal content_view --goal-type page --goal-document UUID
      mix kiln.experiment variant NAME --variant "Control" --control
      mix kiln.experiment variant NAME --variant "Punchier" --patch '{"fields":{"title":"..."}}'
      mix kiln.experiment start   NAME
      mix kiln.experiment conclude NAME [--winner VARIANT_NAME]

  Phase 1 ships the engine, not the editor — `/editor/experiments` is phase 2.
  This exists so the engine is operable in the meantime, rather than shipping
  something that works but that nobody can turn on.

  `start` refuses an experiment that cannot produce a result: fewer than two
  variants, no control, or another experiment already running on the same
  document. Those are not recoverable once visitors are in the experiment, so
  they are checked before rather than reported after.

  Nothing serves until `KILN_EXPERIMENTS_ENABLED=true` — a running experiment
  costs its page the shared cache, so the deployment gets a say.
  """
  use Mix.Task

  alias KilnCMS.Experiments
  alias KilnCMS.Experiments.Variant

  @requirements ["app.start"]

  @switches [
    org_id: :string,
    type: :string,
    document: :string,
    goal: :string,
    form: :string,
    goal_type: :string,
    goal_document: :string,
    variant: :string,
    patch: :string,
    weight: :integer,
    control: :boolean,
    winner: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, positional} = OptionParser.parse!(args, strict: @switches)
    org_id = opts[:org_id] || KilnCMS.Accounts.default_org_id()

    case positional do
      ["list"] -> list(org_id)
      ["show", name] -> show(org_id, name)
      ["create", name] -> create(org_id, name, opts)
      ["variant", name] -> variant(org_id, name, opts)
      ["start", name] -> start(org_id, name)
      ["conclude", name] -> conclude(org_id, name, opts)
      _other -> Mix.raise("Usage: mix kiln.experiment list|show|create|variant|start|conclude")
    end
  end

  defp list(org_id) do
    Mix.shell().info(deployment_line())

    case experiments(org_id) do
      [] ->
        Mix.shell().info("No experiments on this site.")

      experiments ->
        Enum.each(experiments, fn experiment ->
          Mix.shell().info(
            "#{experiment.state |> to_string() |> String.pad_trailing(10)} " <>
              "#{experiment.name}  (#{experiment.content_type} #{experiment.document_id})"
          )
        end)
    end
  end

  defp show(org_id, name) do
    case find(org_id, name) do
      nil ->
        Mix.raise("No experiment named #{inspect(name)} on this site.")

      experiment ->
        Mix.shell().info(deployment_line())
        Mix.shell().info("Name:     #{experiment.name}")
        Mix.shell().info("State:    #{experiment.state}")
        Mix.shell().info("Target:   #{experiment.content_type} #{experiment.document_id}")
        Mix.shell().info("Goal:     #{goal_line(experiment)}")
        Mix.shell().info("")

        Enum.each(experiment.variants, &Mix.shell().info(variant_line(&1, org_id)))
    end
  end

  defp variant_line(variant, org_id) do
    {impressions, conversions} = totals(org_id, variant.id)

    "  #{if variant.control, do: "*", else: " "} " <>
      "#{String.pad_trailing(variant.name, 20)} " <>
      "weight=#{variant.weight}  #{impressions} served  #{conversions} converted" <>
      rate(impressions, conversions)
  end

  defp create(org_id, name, opts) do
    type = opts[:type] || Mix.raise("--type is required (a content type name, e.g. post)")
    document = opts[:document] || Mix.raise("--document UUID is required")

    experiment =
      Experiments.create_experiment!(
        Map.merge(
          %{name: name, content_type: type, document_id: document},
          goal_attrs(opts)
        ),
        authorize?: false,
        tenant: org_id
      )

    Mix.shell().info("Created experiment #{experiment.name} (#{experiment.state}).")
    Mix.shell().info("Add at least two variants, one of them --control, then `start`.")
  end

  defp variant(org_id, name, opts) do
    experiment = find(org_id, name) || Mix.raise("No experiment named #{inspect(name)}.")
    variant_name = opts[:variant] || Mix.raise("--variant NAME is required")

    created =
      Experiments.create_variant!(
        %{
          experiment_id: experiment.id,
          name: variant_name,
          weight: opts[:weight] || 1,
          control: opts[:control] || false,
          patch: parse_patch(opts[:patch])
        },
        authorize?: false,
        tenant: org_id
      )

    Mix.shell().info("Added variant #{created.name} (weight #{created.weight}).")
  end

  defp start(org_id, name) do
    experiment = find(org_id, name) || Mix.raise("No experiment named #{inspect(name)}.")

    case Experiments.start_experiment(experiment, authorize?: false, tenant: org_id) do
      {:ok, started} ->
        Mix.shell().info("#{started.name} is running.")

        unless Experiments.enabled?() do
          Mix.shell().error(
            "KILN_EXPERIMENTS_ENABLED is not set, so nothing is served yet. " <>
              "Set it and restart."
          )
        end

      {:error, error} ->
        Mix.raise("Could not start: #{describe(error)}")
    end
  end

  defp conclude(org_id, name, opts) do
    experiment = find(org_id, name) || Mix.raise("No experiment named #{inspect(name)}.")
    winner = winner_id(experiment, opts[:winner])

    {:ok, concluded} =
      Experiments.conclude_experiment(experiment, winner, authorize?: false, tenant: org_id)

    Mix.shell().info("#{concluded.name} concluded.")

    # Concluding records a result; it does not edit the document. Promoting the
    # winner is a separate, deliberate act — see the resource's moduledoc.
    if winner do
      Mix.shell().info(
        "Winner recorded. The document is unchanged — promote the winning patch " <>
          "through the editor when you are ready."
      )
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp experiments(org_id) do
    Experiments.list_experiments!(query: [load: :variants], authorize?: false, tenant: org_id)
  end

  defp find(org_id, name), do: Enum.find(experiments(org_id), &(&1.name == name))

  defp totals(org_id, variant_id) do
    Experiments.list_variant_days!(
      query: [filter: [variant_id: variant_id]],
      authorize?: false,
      tenant: org_id
    )
    |> Enum.reduce({0, 0}, fn day, {i, c} -> {i + day.impressions, c + day.conversions} end)
  end

  # Deliberately just the ratio, with no confidence claim. A significance number
  # on a handful of impressions is worse than none — it invites a decision the
  # data cannot support.
  defp rate(0, _conversions), do: ""

  defp rate(impressions, conversions),
    do: "  (#{Float.round(conversions / impressions * 100, 1)}%)"

  defp goal_line(%{goal: :content_view} = experiment) do
    "content_view → #{experiment.goal_content_type} #{experiment.goal_document_id}"
  end

  defp goal_line(experiment), do: "#{experiment.goal} (form #{experiment.goal_form_id})"

  defp goal(nil), do: :form_submission
  defp goal("form_submission"), do: :form_submission
  defp goal("content_view"), do: :content_view

  defp goal(other),
    do: Mix.raise("Unknown goal #{inspect(other)} (form_submission, content_view)")

  # An experiment whose goal cannot fire counts nothing, so each goal's
  # requirement is refused here rather than left to be discovered from an empty
  # results column weeks later. `:start` checks the same things again — this is
  # the readable error, that is the real gate.
  defp goal_attrs(opts) do
    case goal(opts[:goal]) do
      :content_view -> %{goal: :content_view} |> Map.merge(content_view_target(opts))
      :form_submission -> %{goal: :form_submission, goal_form_id: goal_form_id(opts)}
    end
  end

  defp goal_form_id(opts) do
    opts[:form] ||
      Mix.raise("--form FORM_UUID is required: it is the form whose submission counts")
  end

  defp content_view_target(opts) do
    # Refused rather than dropped: an operator adapting an existing command line
    # keeps `--form` and adds `--goal content_view`, and would otherwise be told
    # nothing while the flag went on the floor — leaving them believing form
    # submissions also count for an experiment that has no goal form.
    if opts[:form] do
      Mix.raise(
        "--form does not apply to a content_view goal: a content-view " <>
          "experiment converts on a VIEW of --goal-document, not on a form."
      )
    end

    unless KilnCMS.Experiments.Sticky.enabled?() do
      Mix.raise(
        "The content_view goal needs sticky assignment, which is off. " <>
          "Set `config :kiln_cms, KilnCMS.Experiments, sticky: true` — without it " <>
          "the site cannot tell a visitor who saw the experiment from one who did " <>
          "not, so nothing would ever convert. See docs/data-flows.md."
      )
    end

    %{
      goal_content_type:
        opts[:goal_type] ||
          Mix.raise("--goal-type is required: the content type of the document a view converts"),
      goal_document_id:
        opts[:goal_document] ||
          Mix.raise("--goal-document UUID is required: the document whose view converts")
    }
  end

  defp parse_patch(nil), do: %{}

  defp parse_patch(json) do
    case Jason.decode(json) do
      {:ok, patch} when is_map(patch) -> patch
      _other -> Mix.raise("--patch must be a JSON object")
    end
  end

  defp winner_id(_experiment, nil), do: nil

  defp winner_id(experiment, name) do
    case Enum.find(experiment.variants, &(&1.name == name)) do
      nil -> Mix.raise("No variant named #{inspect(name)} on this experiment.")
      %Variant{id: id} -> id
    end
  end

  defp deployment_line do
    if Experiments.enabled?(),
      do: "Deployment: enabled (KILN_EXPERIMENTS_ENABLED)",
      else: "Deployment: DISABLED — no experiment is served"
  end

  defp describe(%{errors: errors}), do: Enum.map_join(errors, "; ", &describe/1)
  defp describe(%{message: message}), do: message
  defp describe(other), do: inspect(other)
end
