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

    * `:funnel_completion` — the same, one level of indirection out (#1010). The
      target is not named directly but derived: it is the funnel's **final
      step**. So the funnel has to exist on this site, have at least one step,
      and not end on the experimented document.

  Either later-page goal also takes the **goal** page out of the shared cache for
  its duration (the conversion is counted at the origin), so it costs two pages
  their CDN rather than one. That is a real cost but not a reason to
  refuse — it is the operator's to weigh, and it is written down in
  `docs/content-experiments-plan.md`.

  The sticky check reads runtime config from a validation, which is unusual and
  deliberate: `sticky` is the difference between this goal working and silently
  not working, and finding that out from a flat results table weeks later is the
  outcome the whole module exists to prevent.

  ## This check cannot hold on its own

  It runs once, on the changeset that starts the experiment. Every premise it
  rests on is revocable afterwards — the flag, the form, the document, the
  funnel's ordering — so `KilnCMS.Experiments.Health` asks the same question of
  a **running** experiment, live, and the surfaces report what it answers
  (#1008). Adding a case here means adding one there.

  The two are **not** identical, and the differences are deliberate:

    * `Health` additionally requires each document to be **published**, and the
      goal form to be **active**. This gate does not, because a publish is a
      normal next step — refusing to start an experiment on a document you are
      about to publish would be an obstacle, not a guard;
    * `Health` additionally checks the **experimented** document, which cannot
      have gone anywhere between `create` and `start`;
    * this gate reports through `field:` so the error lands on the form field;
      `Health` reports an atom a UI phrases itself.

  Anything else — a missing form, a missing goal document, an unknown type, a
  self-goal, a stepless funnel — must be caught by **both**, or `:start` accepts
  what the first `show` condemns.
  """
  use Ash.Resource.Validation

  alias KilnCMS.Experiments.Sticky

  @impl true
  def validate(changeset, _opts, context) do
    case Ash.Changeset.get_attribute(changeset, :goal) do
      :content_view -> content_view(changeset, context)
      :funnel_completion -> funnel_completion(changeset, context)
      _form_submission -> form_submission(changeset, context)
    end
  end

  # A funnel goal converts on the funnel's FINAL step, so every way the funnel
  # can fail to name one is a way the experiment reports 0.0% forever: no
  # funnel, a funnel on another site, one with no steps, or one whose last step
  # is the experimented document itself.
  #
  # Not checked: that the funnel is `active`. That flag governs whether the
  # funnel *report* is shown, and an operator hiding a report should not
  # silently stop an experiment mid-flight — `Delivery` resolves the steps
  # regardless.
  defp funnel_completion(changeset, context) do
    with {:ok, funnel} <- funnel(changeset, context),
         :ok <- funnel_has_steps(funnel),
         :ok <- funnel_ends_elsewhere(changeset, funnel),
         :ok <- funnel_target_exists(funnel, context) do
      sticky_on()
    end
  end

  defp funnel(changeset, context) do
    case Ash.Changeset.get_attribute(changeset, :goal_funnel_id) do
      nil ->
        {:error,
         field: :goal_funnel_id,
         message: "a funnel-completion experiment needs a funnel before it can start"}

      id ->
        case KilnCMS.Analytics.get_funnel(id,
               authorize?: false,
               tenant: context.tenant,
               load: [:steps]
             ) do
          {:ok, funnel} ->
            {:ok, funnel}

          _missing ->
            {:error, field: :goal_funnel_id, message: "no funnel #{inspect(id)} on this site"}
        end
    end
  end

  defp funnel_has_steps(%{steps: [_ | _]}), do: :ok

  defp funnel_has_steps(_funnel) do
    {:error,
     field: :goal_funnel_id, message: "that funnel has no steps, so nothing can complete it"}
  end

  # `FunnelStep` is FK-less by design — "a step whose content has since been
  # deleted resolves to zero traffic" — which is fine for a report and fatal for
  # a goal. A funnel ending on a deleted or never-published document starts
  # cleanly and converts nothing, which is the failure this module exists to
  # refuse, so the last step is resolved the same way `content_view`'s target is.
  defp funnel_target_exists(funnel, context) do
    last = List.last(funnel.steps)

    case KilnCMS.CMS.ContentTypes.get_record(last.content_type, last.content_id,
           authorize?: false,
           tenant: context.tenant
         ) do
      {:ok, _record} ->
        :ok

      _missing ->
        {:error,
         field: :goal_funnel_id,
         message:
           "that funnel's last step (#{last.content_type} #{last.content_id}) " <>
             "is not a document on this site, so nothing can complete it"}
    end
  rescue
    _error ->
      {:error,
       field: :goal_funnel_id,
       message: "that funnel's last step could not be resolved to a document"}
  end

  defp funnel_ends_elsewhere(changeset, funnel) do
    last = List.last(funnel.steps)

    same? =
      last.content_type == Ash.Changeset.get_attribute(changeset, :content_type) and
        last.content_id == Ash.Changeset.get_attribute(changeset, :document_id)

    if same? do
      {:error,
       field: :goal_funnel_id,
       message:
         "that funnel's last step is the experimented document itself — " <>
           "every impression would convert on the view that created it"}
    else
      :ok
    end
  end

  defp form_submission(changeset, context) do
    case Ash.Changeset.get_attribute(changeset, :goal_form_id) do
      nil ->
        {:error,
         field: :goal_form_id,
         message: "a form-submission experiment needs a goal form before it can start"}

      id ->
        goal_form_usable(id, context)
    end
  end

  # Present is not enough: a mistyped or another site's uuid starts cleanly and
  # converts nothing, and an inactive form refuses every submission before it
  # can be counted. This is the same pair `Health.blocked_reason/1` checks at
  # read time, done here so `:start` cannot accept what `show` immediately
  # condemns (#1008 review) — and it is what `funnel_target_exists/2` below has
  # always done for the sibling goal.
  defp goal_form_usable(id, context) do
    case KilnCMS.CMS.get_form(id, authorize?: false, tenant: context.tenant) do
      {:ok, %{active: true}} ->
        :ok

      {:ok, _inactive} ->
        {:error,
         field: :goal_form_id,
         message: "that form is not accepting submissions, so nothing could convert"}

      _missing ->
        {:error, field: :goal_form_id, message: "no form #{inspect(id)} on this site"}
    end
  rescue
    _error ->
      {:error, field: :goal_form_id, message: "that goal form could not be resolved"}
  end

  defp content_view(changeset, context) do
    with :ok <- target_present(changeset),
         :ok <- target_type_exists(changeset, context),
         :ok <- target_is_elsewhere(changeset),
         :ok <- target_document_exists(changeset, context) do
      sticky_on()
    end
  end

  # The type existing does not mean the DOCUMENT does. `funnel_target_exists/2`
  # already resolves the funnel's last step this way, under a comment claiming
  # it is done "the same way `content_view`'s target is" — which was not true
  # until now: a transposed uuid of a valid type passed every gate here and was
  # then reported blocked by `Health` on the first `show` (#1008 review).
  defp target_document_exists(changeset, context) do
    type = Ash.Changeset.get_attribute(changeset, :goal_content_type)
    id = Ash.Changeset.get_attribute(changeset, :goal_document_id)

    case KilnCMS.CMS.ContentTypes.get_record(type, id,
           authorize?: false,
           tenant: context.tenant
         ) do
      {:ok, _record} ->
        :ok

      _missing ->
        {:error,
         field: :goal_document_id,
         message: "#{type} #{id} is not a document on this site, so nothing could convert"}
    end
  rescue
    _error ->
      {:error, field: :goal_document_id, message: "that goal document could not be resolved"}
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
         "a later-page goal needs sticky assignment, which is off: " <>
           "set `config :kiln_cms, KilnCMS.Experiments, sticky: true`. " <>
           "Without it the site cannot tell a visitor who saw the experiment " <>
           "from one who did not, and nothing would ever convert"}
    end
  end
end
