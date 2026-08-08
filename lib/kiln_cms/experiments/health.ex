defmodule KilnCMS.Experiments.Health do
  @moduledoc """
  Whether a **running** experiment can still convert, and if not, why (#1008).

  `KilnCMS.Experiments.Validations.GoalConfigured` (#984) refuses to *start* an
  experiment whose goal can never fire. That is a point-in-time check, and every
  premise it rests on can stop holding while the experiment runs:

    * an operator turns `KILN_EXPERIMENTS_STICKY` off — which
      `docs/data-flows.md` actively invites — and every later-page goal on the
      site becomes unservable;
    * a rolling deploy leaves one node with sticky on and another with it off;
    * the goal form, the goal document, or the funnel's last step is deleted;
    * a funnel is re-ordered so it now ends on the experimented document itself.

  The delivery path already refuses to serve an arm it cannot attribute, so the
  page keeps its cache and no impressions accumulate. **Nothing said so.** The
  experiment still read `running`, and an editor watching the numbers saw one
  that simply never moved — indistinguishable from an inconclusive result.

  ## One rule, read at the moment it is asked

  Before this module the rule lived in three places — the validation, the mix
  task's `content_view_target/1`, and three moduledocs — with none of them
  authoritative at read time. `blocked_reason/1` is the one that is: it reads
  live config and the live database, so it answers for the experiment as it is
  now, not as it was when it started.

  It deliberately does **not** answer for a non-running experiment. A draft with
  no goal form yet is not broken, it is unfinished, and `:start` is where that
  is caught — reporting it here would make the honest signal one an editor
  learns to scroll past.

  ## Cost

  Up to one lookup per running experiment: the goal form, the goal document, or
  the funnel's last step. Not for the delivery path — `Delivery` answers the
  narrower "can I attribute *this request*" question from the cached running set
  and never calls this. Callers here are the mix task and the overview strip,
  both of which already accept a query, and the running set is small by
  construction (an experiment costs its page the CDN).
  """

  alias KilnCMS.Experiments
  alias KilnCMS.Experiments.Experiment
  alias KilnCMS.Experiments.Sticky

  require Logger

  @typedoc """
  Why a running experiment cannot convert. The atom is the surface-independent
  fact; the sentence spells it out for an operator reading a terminal, and a UI
  is expected to phrase its own from the atom.
  """
  @type reason :: {atom(), String.t()}

  @doc """
  `nil` if `experiment` can still convert, `{reason, sentence}` if it cannot.

  Only ever non-nil for a `:running` experiment — see the moduledoc.
  """
  @spec blocked_reason(Experiment.t()) :: reason() | nil
  def blocked_reason(%{state: :running} = experiment) do
    cond do
      not Experiments.enabled?() ->
        {:deployment_disabled,
         "experiments are switched off for this deployment, so no arm is served " <>
           "(set KILN_EXPERIMENTS_ENABLED=true)"}

      later_page_goal?(experiment) and not Sticky.enabled?() ->
        # First among the goal checks because it is the one that changes under a
        # running experiment's feet: it is a config read, not a row, so nothing
        # about the experiment itself looks different afterwards.
        {:sticky_off,
         "this goal converts on a later page, and sticky assignment is off, so " <>
           "the site cannot tell a visitor who saw the experiment from one who " <>
           "did not (set `config :kiln_cms, KilnCMS.Experiments, sticky: true`)"}

      true ->
        goal_reason(experiment)
    end
  end

  def blocked_reason(_experiment), do: nil

  @doc """
  Every running experiment for a site that cannot convert, as
  `[{experiment, reason}]`.

  Ordered as `Experiments.running/1` returns them, so two calls in a row list
  them the same way.
  """
  @spec blocked(Ash.UUID.t()) :: [{Experiment.t(), reason()}]
  def blocked(org_id) do
    org_id
    |> Experiments.running()
    |> Enum.flat_map(fn experiment ->
      case blocked_reason(experiment) do
        nil -> []
        reason -> [{experiment, reason}]
      end
    end)
  end

  defp later_page_goal?(%{goal: goal}), do: goal in [:content_view, :funnel_completion]

  defp goal_reason(%{goal: :form_submission} = experiment), do: form_submission(experiment)
  defp goal_reason(%{goal: :content_view} = experiment), do: content_view(experiment)
  defp goal_reason(%{goal: :funnel_completion} = experiment), do: funnel_completion(experiment)
  defp goal_reason(_experiment), do: nil

  defp form_submission(%{goal_form_id: nil}) do
    {:no_goal_form, "no goal form is set, and `Delivery.converts?/3` counts no form without one"}
  end

  defp form_submission(%{goal_form_id: id, org_id: org_id}) do
    case KilnCMS.CMS.get_form(id, authorize?: false, tenant: org_id) do
      {:ok, _form} -> nil
      _missing -> {:goal_form_missing, "goal form #{id} is no longer on this site"}
    end
  rescue
    error -> unreadable(:goal_form_missing, error)
  end

  defp content_view(experiment) do
    with :ok <- target_named(experiment),
         :ok <- target_elsewhere(experiment),
         :ok <- target_type_known(experiment) do
      target_exists(experiment)
    else
      {:blocked, reason} -> reason
    end
  end

  defp target_named(%{goal_content_type: type, goal_document_id: id})
       when is_binary(type) and type != "" and not is_nil(id),
       do: :ok

  defp target_named(_experiment) do
    {:blocked, {:no_target, "no goal document is set, so no view can be counted as a conversion"}}
  end

  # An experiment whose goal is its own document converts every impression on
  # the view that created it. `GoalConfigured` refuses that at `:start`; it can
  # still be reached afterwards by moving the experiment to the goal document.
  defp target_elsewhere(%{
         goal_content_type: type,
         goal_document_id: id,
         content_type: type,
         document_id: id
       }) do
    {:blocked,
     {:goal_is_self,
      "the goal document is the experimented document itself, so every " <>
        "impression would convert on the view that created it"}}
  end

  defp target_elsewhere(_experiment), do: :ok

  defp target_type_known(%{goal_content_type: type, org_id: org_id}) do
    if KilnCMS.CMS.ContentTypes.get(type, org_id) do
      :ok
    else
      {:blocked,
       {:goal_type_unknown,
        "#{inspect(type)} is not a content type on this site — a dynamic type " <>
          "may have been deleted, or it was always the URL segment rather than " <>
          "the type name"}}
    end
  end

  defp target_exists(%{goal_content_type: type, goal_document_id: id, org_id: org_id}) do
    case KilnCMS.CMS.ContentTypes.get_record(type, id, authorize?: false, tenant: org_id) do
      {:ok, _record} ->
        nil

      _missing ->
        {:goal_document_missing, "goal document #{type} #{id} is no longer on this site"}
    end
  rescue
    error -> unreadable(:goal_document_missing, error)
  end

  # The funnel goal is one level of indirection out (#1010): the target is the
  # funnel's LAST STEP, so editing the funnel edits the goal — which is the
  # feature, and also the way a healthy experiment becomes an unservable one
  # without anybody touching the experiment.
  defp funnel_completion(%{goal_funnel_id: nil}) do
    {:no_goal_funnel, "no funnel is set, so nothing can complete this experiment"}
  end

  # Through the same per-site cache `Delivery.goal_document?/3` resolves the goal
  # from, deliberately: this reports what delivery will *actually* do on the next
  # request. Reading the funnel fresh here would let the report say "healthy"
  # while delivery still converts on the previous last step.
  defp funnel_completion(experiment) do
    case Experiments.funnel_target(experiment) do
      nil ->
        {:funnel_target_missing,
         "funnel #{experiment.goal_funnel_id} is gone from this site or has no " <>
           "steps, so nothing can complete this experiment"}

      {type, id} ->
        funnel_target_usable(experiment, type, id)
    end
  end

  defp funnel_target_usable(
         %{content_type: type, document_id: id} = experiment,
         type,
         id
       ) do
    {:funnel_ends_here,
     "funnel #{experiment.goal_funnel_id} now ends on the experimented document " <>
       "itself, so every impression would convert on the view that created it"}
  end

  defp funnel_target_usable(experiment, type, id) do
    # `FunnelStep` is FK-less by design, so a step can outlive the document it
    # names — fine for a report that shows zero traffic, fatal for a goal.
    case KilnCMS.CMS.ContentTypes.get_record(type, id,
           authorize?: false,
           tenant: experiment.org_id
         ) do
      {:ok, _record} ->
        nil

      _missing ->
        {:funnel_target_missing,
         "funnel #{experiment.goal_funnel_id} ends on #{type} #{id}, which is no " <>
           "longer a document on this site"}
    end
  rescue
    error -> unreadable(:funnel_target_missing, error)
  end

  # A lookup that raises is reported as blocked, not as healthy. "The goal is
  # gone" and "the goal could not be read" are the same thing to an editor
  # waiting on numbers, and the alternative — swallowing it — is the silence
  # this module exists to end.
  defp unreadable(reason, error) do
    Logger.warning("Experiments.Health could not resolve a goal: #{Exception.message(error)}")
    {reason, "the goal could not be resolved: #{Exception.message(error)}"}
  end
end
