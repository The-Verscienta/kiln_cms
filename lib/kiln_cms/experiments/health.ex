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
    * the goal form is deactivated, or the goal document, the experimented
      document, or the funnel's last step is unpublished or deleted;
    * a funnel is re-ordered so it now ends on the experimented document itself.

  Nothing said so. The experiment still read `running`, and an editor watching
  the numbers saw one that simply never moved — indistinguishable from an
  inconclusive result.

  ## A blocked experiment is not a free one

  Only `:sticky_off` is refused by delivery: `attributable?/1` gates `do_assign/3`
  and nothing else. For every *other* reason here the arm is served normally —
  `assign_sticky/3` never consults `attributable?/1`, `count_exposure/4` books an
  impression, and `ContentController` still drops the page to `private, no-store`.
  So a blocked experiment goes on splitting traffic, accumulating impressions on
  a denominator the numerator can never reach, and costing both its pages the CDN.

  That is why this is worth surfacing rather than leaving to whoever eventually
  reads a flat table, and why clearing the block does **not** make the numbers
  gathered meanwhile usable.

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

  ## What is NOT reported here

  The deployment switch. `KILN_EXPERIMENTS_ENABLED` being off is a **site-wide**
  fact, and folding it into a per-experiment verdict did two harmful things
  (#1008 review): it made the answer identical for every row on a deployment
  whose default is off, and — because it short-circuited — it *hid* every real
  reason until the flag was flipped, so fixing the flag revealed a second round
  of problems that had been concealed the whole time. Each surface reports the
  switch once, on its own: `mix kiln.experiment` in `deployment_line/0`, the
  overview in its own line above the list.

  ## Cost

  Up to one lookup per running experiment: the goal form, the goal document, or
  the funnel's last step — plus one for the experimented document. Not for the
  delivery path — `Delivery` answers the narrower "can I attribute *this
  request*" question from the cached running set and never calls this. Callers
  here are the mix task and the overview strip, both of which already accept a
  query, and the running set is small by construction.
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

  # `:live` is the only healthy answer. Everything else is a distinct reason an
  # operator can act on, and keeping them apart here is what stops a failed read
  # being reported as a deletion.
  @typep resolution ::
           :live
           | :missing
           | {:not_published, atom()}
           | {:unknown_type, String.t()}
           | {:unreadable, String.t()}

  @doc """
  `nil` if `experiment` can still convert, `{reason, sentence}` if it cannot.

  Only ever non-nil for a `:running` experiment — see the moduledoc. Does not
  consider the deployment switch; that is a site-wide fact each surface reports
  once.
  """
  @spec blocked_reason(Experiment.t()) :: reason() | nil
  def blocked_reason(%{state: :running} = experiment) do
    # Sticky first because it is the one that changes under a running
    # experiment's feet: it is a config read, not a row, so nothing about the
    # experiment itself looks different afterwards.
    if Experiments.later_page_goal?(experiment) and not Sticky.enabled?() do
      {:sticky_off,
       "this goal converts on a later page, and sticky assignment is off, so " <>
         "the site cannot tell a visitor who saw the experiment from one who " <>
         "did not (set `config :kiln_cms, KilnCMS.Experiments, sticky: true`)"}
    else
      subject_reason(experiment) || goal_reason(experiment)
    end
  end

  def blocked_reason(_experiment), do: nil

  @doc """
  `nil` if a variant's own totals are plausible, `{reason, sentence}` if they
  are not (#1007 — a results-panel sanity check, not a prevention).

  The opposite question from `blocked_reason/1`. That one says an experiment
  cannot produce a result at all; this says a variant IS producing one, in
  numbers that are worth a second look before being read as a rate.

  Only the one unambiguous case: more conversions than impressions for the
  same variant. In the ordinary run of the site this does not happen — an
  impression is booked before a conversion can follow it, whether that is one
  exposure converting once (`Delivery.count_exposure/4`, `:content_view` and
  `:funnel_completion`) or an arm being served before its form can be posted
  (`:form_submission`) — so it is a strong signal rather than routine noise.
  It is not a *proof* of abuse: a double form submission (back-button resubmit,
  a double-bound submit handler) books a second conversion off the same page
  view, and would trip this too. Either cause is worth a look, which is why
  this stays a flag rather than a rule that discards a row.

  It is also the multiplier `Delivery.record_content_view/3` cannot fully
  close (#1007): that function bounds a single request to at most one
  conversion, and `Delivery.record_conversion/3`'s form path is bounded by the
  `:form` rate limit, honeypot and spam checks, but neither stops a client
  from replaying, across many separate requests, an id it read off the page
  without the impressions to match — this is the check that catches the
  result rather than the request.

  Deliberately not a rate ceiling instead: a rate has no value that is
  implausible on its own — 100% of one impression is a legitimate, if
  unreadable, result — while the count inequality needs no sample size to be
  worth flagging.
  """
  @spec anomaly_reason(non_neg_integer(), non_neg_integer()) :: reason() | nil
  def anomaly_reason(impressions, conversions) when conversions > impressions do
    {:conversions_exceed_impressions,
     "#{conversions} conversions were recorded against only #{impressions} impressions — " <>
       "a variant does not usually convert more than it was shown, so this total is worth " <>
       "checking before it is read as a rate (see KilnCMS.Experiments.Delivery, #1007)"}
  end

  def anomaly_reason(_impressions, _conversions), do: nil

  @doc """
  Every running experiment for a site that cannot convert, as
  `[{experiment, reason}]`.

  Ordered as `Experiments.running/1` returns them (`inserted_at` ascending),
  so two calls in a row list them the same way.
  """
  # DO NOT short-circuit this on `Experiments.enabled?()`. It looks like free
  # efficiency — no arm is served, so why compute a goal reason — and #1114
  # proposed exactly that. It reintroduces the masking #1008's review removed:
  # the operator sees only "experiments are switched off", flips the flag, and
  # *then* discovers the goal form was deleted three weeks ago. Surfacing both
  # at once is the whole point, and `OverviewExperimentWarningTest` pins it.
  #
  # The cost this was meant to save is also smaller than it looks: `running/1`
  # caches `[]` like any other value, so a site with no experiments pays one
  # load per TTL, not one per mount.
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

  @doc """
  Whether this site has running experiments that the deployment switch is
  stopping from being served.

  The site-wide half of what the surfaces report, kept apart from `blocked/1`
  for the reason in the moduledoc: it is one fact about the deployment, not a
  verdict on each experiment.
  """
  @spec switched_off?(Ash.UUID.t()) :: boolean()
  def switched_off?(org_id) do
    not Experiments.enabled?() and Experiments.running(org_id) != []
  end

  # The EXPERIMENTED document, checked before any goal. `Delivery` only ever
  # reaches `Experiments.for_document/3` from a published-content render, so a
  # document that is unpublished, archived or trashed serves no arm at all —
  # zero impressions, zero conversions, and every goal check below it healthy.
  # Unpublishing the page under test is the most ordinary thing an editor does
  # to it, and before this it was the one input nothing here looked at.
  defp subject_reason(%{content_type: type, document_id: id, org_id: org_id}) do
    case published_document(type, id, org_id) do
      :live ->
        nil

      :missing ->
        {:document_missing,
         "the experimented document #{type} #{id} is no longer on this site, so " <>
           "no arm is ever served"}

      {:not_published, state} ->
        {:document_unpublished,
         "the experimented document #{type} #{id} is #{state}, not published, so " <>
           "it is not served and no arm can be shown"}

      {:unknown_type, _type} ->
        {:document_missing,
         "#{inspect(type)} is not a content type on this site, so the " <>
           "experimented document cannot be resolved"}

      {:unreadable, message} ->
        unreadable_reason(message)
    end
  end

  defp goal_reason(%{goal: :form_submission} = experiment), do: form_submission(experiment)
  defp goal_reason(%{goal: :content_view} = experiment), do: content_view(experiment)
  defp goal_reason(%{goal: :funnel_completion} = experiment), do: funnel_completion(experiment)

  # Fails CLOSED, like every other fallback here. A goal added to the resource
  # without a clause in this module must not read as healthy forever — silence
  # is the failure this module exists to end, and an unrecognised goal is
  # exactly the case nothing else would catch.
  defp goal_reason(%{goal: goal}) do
    {:unknown_goal,
     "#{inspect(goal)} is a goal this version does not know how to check, so " <>
       "whether it can convert is unknown"}
  end

  defp form_submission(%{goal_form_id: nil}) do
    {:no_goal_form, "no goal form is set, and `Delivery.converts?/3` counts no form without one"}
  end

  defp form_submission(%{goal_form_id: id, org_id: org_id}) do
    case KilnCMS.CMS.get_form(id, authorize?: false, tenant: org_id) do
      # `active` is the gate the visitor actually meets: `read :active_by_slug`
      # filters on it and `Forms.submit/3` refuses before `record/4`, the only
      # caller that counts a conversion. Deactivating a form is the reversible,
      # common action; deleting it is the rare one.
      {:ok, %{active: true}} ->
        nil

      {:ok, _inactive} ->
        {:goal_form_inactive,
         "goal form #{id} is not accepting submissions, so no submission can " <>
           "convert this experiment"}

      {:error, error} ->
        if not_found?(error) do
          {:goal_form_missing, "goal form #{id} is no longer on this site"}
        else
          unreadable_reason(log_unreadable(error))
        end
    end
  rescue
    error -> unreadable_reason(log_unreadable(error))
  end

  # One convention throughout this module: a check returns `nil` when it passes
  # and a `reason` when it does not, so they chain with `||` (#1117). The `with`
  # this replaced mixed `:ok`/`{:blocked, r}` against `nil`/`r`, which meant a
  # fifth check written in the majority style raised `WithClauseError` — fatal
  # to `mix kiln.experiment list`, and silently empty on the overview.
  defp content_view(experiment) do
    target_named(experiment) || target_elsewhere(experiment) || goal_document(experiment)
  end

  defp target_named(%{goal_content_type: type, goal_document_id: id})
       when is_binary(type) and type != "" and not is_nil(id),
       do: nil

  defp target_named(_experiment) do
    {:no_target, "no goal document is set, so no view can be counted as a conversion"}
  end

  # Defensive, not reachable by any supported write: `GoalConfigured` refuses
  # this at `:start`, and a running experiment cannot be edited afterwards —
  # `update :update` carries `validate attribute_equals(:state, :draft)` and
  # `:start`/`:conclude`/`:archive` all `accept []`. It is kept because the cost
  # is one comparison and the alternative is trusting that no legacy row, seed
  # or direct-SQL write ever produced one.
  #
  # `Delivery.goal_document?/3` guards this case on both goal branches, so what
  # this reports and what delivery does now agree: nothing converts. Before that
  # guard the `:content_view` branch would have converted EVERY impression —
  # the opposite of what this says — which is why the two were fixed together.
  defp target_elsewhere(%{
         goal_content_type: type,
         goal_document_id: id,
         content_type: type,
         document_id: id
       }) do
    {:goal_is_self,
     "the goal document is the experimented document itself, so nothing " <>
       "converts — a view cannot be a conversion of the impression that same " <>
       "view created, and delivery refuses to count it"}
  end

  defp target_elsewhere(_experiment), do: nil

  defp goal_document(%{goal_content_type: type, goal_document_id: id, org_id: org_id}) do
    case published_document(type, id, org_id) do
      :live ->
        nil

      :missing ->
        {:goal_document_missing, "goal document #{type} #{id} is no longer on this site"}

      {:not_published, state} ->
        {:goal_document_unpublished,
         "goal document #{type} #{id} is #{state}, not published, so a visitor " <>
           "never reaches the page whose view would convert"}

      {:unknown_type, _type} ->
        {:goal_type_unknown,
         "#{inspect(type)} is not a content type on this site — a dynamic type " <>
           "may have been deleted, or it was always the URL segment rather than " <>
           "the type name"}

      {:unreadable, message} ->
        unreadable_reason(message)
    end
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
        # Three causes share this answer, and the sentence has to admit all
        # three: the loader rescues a failed read to an empty map, so "could not
        # be read" is not distinguishable from "gone" at this call.
        {:funnel_target_missing,
         "funnel #{experiment.goal_funnel_id} is gone from this site, has no " <>
           "steps, or could not be read, so nothing can complete this experiment"}

      {type, id} ->
        funnel_target_usable(experiment, type, id)
    end
  end

  defp funnel_target_usable(%{content_type: type, document_id: id} = experiment, type, id) do
    {:funnel_ends_here,
     "funnel #{experiment.goal_funnel_id} now ends on the experimented document " <>
       "itself, so nothing converts — a view cannot be a conversion of the " <>
       "impression that same view created, and delivery refuses to count it"}
  end

  defp funnel_target_usable(experiment, type, id) do
    # `FunnelStep` is FK-less by design AND its `content_type` is an unvalidated
    # string, so the step can outlive both the document it names and the type —
    # fine for a report that shows zero traffic, fatal for a goal.
    case published_document(type, id, experiment.org_id) do
      :live ->
        nil

      :missing ->
        {:funnel_target_missing,
         "funnel #{experiment.goal_funnel_id} ends on #{type} #{id}, which is no " <>
           "longer a document on this site"}

      {:not_published, state} ->
        {:goal_document_unpublished,
         "funnel #{experiment.goal_funnel_id} ends on #{type} #{id}, which is " <>
           "#{state}, not published, so nothing can complete it"}

      {:unknown_type, _type} ->
        {:goal_type_unknown,
         "funnel #{experiment.goal_funnel_id} ends on #{inspect(type)}, which is " <>
           "not a content type on this site — a dynamic type may have been deleted"}

      {:unreadable, message} ->
        unreadable_reason(message)
    end
  end

  # THE document resolver for this module: "is there a live, PUBLISHED record
  # here". `get_record/3` runs the primary read, which returns drafts and
  # archived rows, while every conversion path resolves through a published-only
  # read — so "does the row exist" was never the question worth asking.
  #
  # The type is resolved first because `get_record/3` raises `ArgumentError` on
  # an unknown one, and "a dynamic type was deleted" deserves its own answer
  # rather than arriving as an exception message.
  @spec published_document(String.t(), Ash.UUID.t(), Ash.UUID.t()) :: resolution()
  defp published_document(type, id, org_id) do
    if is_nil(KilnCMS.CMS.ContentTypes.get(type, org_id)) do
      {:unknown_type, type}
    else
      type
      |> KilnCMS.CMS.ContentTypes.get_record(id, authorize?: false, tenant: org_id)
      |> classify()
    end
  rescue
    # Covers the whole body, including `ContentTypes.get/2` — which reaches the
    # database for a dynamic type through a bang read. Without this a registry
    # that cannot be read aborts `mix kiln.experiment list` mid-listing, and
    # makes the overview's outer rescue answer "every experiment is healthy".
    error -> log_unreadable(error)
  end

  defp classify({:ok, %{state: :published}}), do: :live
  defp classify({:ok, %{state: state}}), do: {:not_published, state}

  defp classify({:error, error}),
    do: if(not_found?(error), do: :missing, else: log_unreadable(error))

  defp classify(_other), do: :missing

  # Ash wraps the not-found in an `Invalid`/`Query` envelope whose `errors` list
  # carries the real class, so the check has to recurse rather than match the
  # top-level struct. Same shape as `KilnCMS.Firing.References.not_found?/1`.
  defp not_found?(%Ash.Error.Query.NotFound{}), do: true
  defp not_found?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &not_found?/1)
  defp not_found?(_other), do: false

  # A read that FAILED is not a row that is GONE. AshPostgres returns rather
  # than raises for most database errors, so the tuple path is the likely one
  # and was previously silent — reporting a pool timeout as a deleted goal and
  # sending an operator to restore something nobody removed.
  defp log_unreadable(error) do
    message = Exception.message(error)
    Logger.warning("Experiments.Health could not resolve a document: #{message}")
    {:unreadable, message}
  end

  defp unreadable_reason({:unreadable, message}), do: unreadable_reason(message)

  defp unreadable_reason(message) when is_binary(message) do
    {:goal_unreadable, "the goal could not be read: #{message}"}
  end
end
