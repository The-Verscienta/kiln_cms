defmodule KilnCMS.Experiments.Validations.GoalConfigured do
  @moduledoc """
  Refuses to start an experiment whose goal can never fire (#984).

  This is one check because it is one failure: an experiment that starts, splits
  traffic, costs its page the shared cache, accumulates impressions on every arm
  and then reports 0.0% forever. Nothing about that looks broken from the
  outside — the numbers are simply wrong — so it has to be refused at the only
  moment there is still someone to tell.

  What "can never fire" means depends on the goal:

    * `:form_submission` — `Delivery.converts?/3` requires the submitted form to
      **be** the goal form, and treats a `nil` goal form as "no form converts
      this experiment". So a missing `goal_form_id` is exactly the dead case.

    * `:content_view` — the conversion happens on a **later page** than the
      assignment, so three things must hold: a target to convert on, a target
      that is not the experimented document itself (which would convert every
      impression at the moment it was recorded), and sticky assignment switched
      on — because without a bucket cookie the built-in site has no way to know
      the visitor was ever exposed. See `KilnCMS.Experiments.Sticky`.

  A `:content_view` experiment also takes the **goal** page out of the shared
  cache for its duration (the conversion is counted at the origin), so it costs
  two pages their CDN rather than one. That is a real cost but not a reason to
  refuse — it is the operator's to weigh, and it is written down in
  `docs/content-experiments-plan.md`.

  The sticky check reads runtime config from a validation, which is unusual and
  deliberate: `sticky` is the difference between this goal working and silently
  not working, and finding that out from a flat results table weeks later is the
  outcome the whole module exists to prevent.
  """
  use Ash.Resource.Validation

  alias KilnCMS.Experiments.Sticky

  @impl true
  def validate(changeset, _opts, context) do
    case Ash.Changeset.get_attribute(changeset, :goal) do
      :content_view -> content_view(changeset, context)
      _form_submission -> form_submission(changeset)
    end
  end

  defp form_submission(changeset) do
    if Ash.Changeset.get_attribute(changeset, :goal_form_id) do
      :ok
    else
      {:error,
       field: :goal_form_id,
       message: "a form-submission experiment needs a goal form before it can start"}
    end
  end

  defp content_view(changeset, context) do
    with :ok <- target_present(changeset),
         :ok <- target_type_exists(changeset, context),
         :ok <- target_is_elsewhere(changeset) do
      sticky_on()
    end
  end

  defp target_present(changeset) do
    type = Ash.Changeset.get_attribute(changeset, :goal_content_type)
    id = Ash.Changeset.get_attribute(changeset, :goal_document_id)

    if is_binary(type) and type != "" and not is_nil(id) do
      :ok
    else
      {:error,
       field: :goal_document_id,
       message:
         "a content-view experiment needs a target document " <>
           "(goal_content_type and goal_document_id) before it can start"}
    end
  end

  # `Delivery.goal_document?/3` matches `goal_content_type` against `ct.type` by
  # exact string equality, so `"pages"` (the URL segment) or `"Post"` never
  # matches anything. Nothing about the resulting experiment looks wrong — it
  # serves, it splits, it books impressions — it just converts nothing, forever.
  # A typo that costs a fortnight of traffic is worth one lookup here.
  defp target_type_exists(changeset, context) do
    type = Ash.Changeset.get_attribute(changeset, :goal_content_type)

    # With the tenant, so a dynamic content type (D17) — which exists only for
    # one site — resolves as readily as a compiled one.
    if KilnCMS.CMS.ContentTypes.get(type, context.tenant) do
      :ok
    else
      {:error,
       field: :goal_content_type,
       message:
         "#{inspect(type)} is not a content type on this site — " <>
           "it is the type NAME (\"post\", \"page\"), not the URL segment"}
    end
  end

  defp target_is_elsewhere(changeset) do
    same_type? =
      Ash.Changeset.get_attribute(changeset, :goal_content_type) ==
        Ash.Changeset.get_attribute(changeset, :content_type)

    same_doc? =
      Ash.Changeset.get_attribute(changeset, :goal_document_id) ==
        Ash.Changeset.get_attribute(changeset, :document_id)

    if same_type? and same_doc? do
      {:error,
       field: :goal_document_id,
       message:
         "the goal document cannot be the experimented document itself — " <>
           "every impression would convert on the view that created it"}
    else
      :ok
    end
  end

  defp sticky_on do
    if Sticky.enabled?() do
      :ok
    else
      {:error,
       field: :goal,
       message:
         "a content-view goal needs sticky assignment, which is off: " <>
           "set `config :kiln_cms, KilnCMS.Experiments, sticky: true`. " <>
           "Without it the site cannot tell a visitor who saw the experiment " <>
           "from one who did not, and nothing would ever convert"}
    end
  end
end
