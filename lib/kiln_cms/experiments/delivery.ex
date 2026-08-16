defmodule KilnCMS.Experiments.Delivery do
  @moduledoc """
  The delivery-path entry point for experiments (#499).

  One function per surface, each returning the chosen variant or `nil`. `nil` is
  the overwhelmingly common answer — most pages are not experimented and most
  deployments have the feature off entirely — so both paths are a cached lookup
  and nothing else before they can say so.

  Impressions are recorded through the same async `Task.Supervisor` the view
  counters use: a delivery response must never wait on a counter, and a counter
  that fails must never fail a page.
  """

  alias KilnCMS.Experiments
  alias KilnCMS.Experiments.Assignment
  alias KilnCMS.Experiments.Sticky

  require Logger

  @doc """
  The variant to serve for a record on the built-in site, or `nil`.

  Stateless: drawn per request, nothing stored. Safe to draw randomly here only
  because `KilnCMSWeb.ContentController` flips an experimented page to
  `private, no-store` — see `KilnCMS.Experiments`.
  """
  @spec assign(String.t(), struct()) :: struct() | nil
  def assign(content_type, record), do: do_assign(content_type, record, nil)

  @doc """
  The variant to serve on the built-in site, sticky per visitor when the
  operator opted in (#984).

  Returns `{variant_or_nil, conn}` — the conn because minting a bucket sets a
  cookie on it.

  With `sticky: false` (the default) this is exactly `assign/2` and the conn
  comes back untouched: no cookie is read, none is written, and
  `docs/data-flows.md`'s "no cookie is recorded for visitors" stays literally
  true. With it on, the visitor keeps their arm across reloads instead of
  re-drawing every request.

  The page stays `private, no-store` either way. Stickiness changes *which* arm
  a given visitor sees, not the fact that the body differs between visitors —
  so a shared cache would still be serving one visitor's arm to another.
  """
  @spec assign_sticky(String.t(), struct(), Plug.Conn.t()) :: {struct() | nil, Plug.Conn.t()}
  def assign_sticky(content_type, record, conn) do
    if Sticky.enabled?() do
      sticky_assign(content_type, record, conn)
    else
      {assign(content_type, record), conn}
    end
  end

  # The experiment is looked up BEFORE the bucket, and that order is the
  # privacy design rather than an optimisation: a visitor who never lands on an
  # experimented page never gets a cookie. Minting first would put one on every
  # page view of the whole site the moment the switch went on — a standing
  # marker, which is precisely what a bucket-not-an-id is meant not to be.
  defp sticky_assign(content_type, %{id: id, org_id: org_id}, conn) do
    case Experiments.for_document(org_id, content_type, id) do
      nil -> {nil, conn}
      experiment -> serve_sticky(experiment, org_id, conn)
    end
  rescue
    # A page must render even if the experiment layer is broken.
    error ->
      Logger.warning("Experiments.Delivery.assign_sticky failed: #{Exception.message(error)}")
      {nil, conn}
  end

  defp sticky_assign(content_type, record, conn), do: {assign(content_type, record), conn}

  defp serve_sticky(experiment, org_id, conn) do
    {bucket, minted} = Sticky.bucket(conn)

    case Assignment.choose_bucket(experiment.variants, bucket, Sticky.buckets()) do
      # No arm to serve, so hand back the ORIGINAL conn and drop the mint. The
      # response is about to take the PUBLIC cache headers — `variant == nil`
      # means `render_content` sees nothing personal — and a `Set-Cookie` on a
      # `public, max-age=60` response is one a CDN stores and replays, pinning
      # every visitor of that page to one bucket.
      nil -> {nil, conn}
      variant -> {variant, count_exposure(experiment, variant, org_id, minted)}
    end
  end

  # Only a later-page goal needs to know the visitor was here — `:form_submission`
  # converts on the page that carried the variant, so exposure travels with the
  # request and nothing has to be written down.
  #
  # And that goal's impressions are counted **per exposed visitor**, not per page
  # view, because its conversions are: an exposure is spent once. Counting a
  # visitor's tenth reload of the landing page in the denominator would make the
  # arm that brings people back look worse for bringing them back.
  defp count_exposure(experiment, variant, org_id, conn) do
    # A body check rather than a guard, so the list itself lives in one place
    # (#1115) — `Experiments.later_page_goal?/1`.
    if Experiments.later_page_goal?(experiment) do
      case Sticky.remember_exposure(conn, variant.id) do
        {:new, conn} ->
          record_impression(variant, org_id)
          conn

        {:repeat, conn} ->
          conn
      end
    else
      record_impression(variant, org_id)
      conn
    end
  end

  @doc """
  Count a conversion for a later-page goal — `:content_view`, or
  `:funnel_completion` on its funnel's final step (#1010) — if this page is some
  running experiment's goal document and the visitor was exposed to it (#984).

  Returns the conn, because a counted exposure is **removed** from the visitor's
  cookie: one exposure converts once. Without that a reload of the target page
  would convert again and again, and an arm could report more conversions than
  it ever had impressions.

  Both switches have to be on. Sticky assignment is what makes exposure
  knowable at all here — `Validations.GoalConfigured` refuses to start such an
  experiment while it is off, but an operator can turn it off afterwards, and
  the honest behaviour then is to stop counting rather than to count everyone.

  Built-in site only. A headless caller's `variant_key` says which arm they
  would be in, not that they ever fetched the experimented document, so
  attributing a later fetch to it would count callers who never saw the test.

  A goal document is also flagged `goal_page?/1`, so the controller can drop it
  out of the shared cache — see there for why that is not optional.

  The cookie is attacker-controlled. The **containment** is the same as on the
  form path — the variant must belong to a *running* experiment on **this** site
  whose goal document is **this** page, so a stray uuid mints no `VariantDay`
  row and another site's results cannot be written into. The **bound** is
  narrower: this is a GET under the `:delivery` rate limit rather than a POST
  under the much tighter `:form` one, and there is no honeypot or spam scoring
  in front of it. So a scripted client can inflate an arm it could legitimately
  have been served, considerably faster than it could through a form.

  That per-request multiplier is what #1007 closes: whatever the cookie names —
  up to `Sticky.max_exposures/0` arms, potentially spanning several running
  experiments whose goal document is this same page — at most **one**
  conversion is counted per request. See `convert/3` for the tie-break.

  What remains open, and is inherent to any client-reported conversion on a
  cacheable GET, is a visitor (or script) replaying the single arm it was
  legitimately served, across many requests. That is worth knowing before
  reading a `content_view` result as evidence.
  """
  @spec record_content_view(String.t(), struct(), Plug.Conn.t()) :: Plug.Conn.t()
  def record_content_view(content_type, %{id: id, org_id: org_id}, conn) do
    if Experiments.enabled?() and Sticky.enabled?() do
      convert_exposed(content_type, id, org_id, conn)
    else
      conn
    end
  rescue
    error ->
      Logger.warning(
        "Experiments.Delivery.record_content_view failed: " <> Exception.message(error)
      )

      conn
  end

  def record_content_view(_content_type, _record, conn), do: conn

  @doc """
  Whether this response is the goal document of a running later-page experiment
  (`:content_view`, or `:funnel_completion` on its funnel's final step), and so
  must not be shared-cached (#984, #1010).

  Set by `record_content_view/3`. Two independent reasons, and either alone
  would be enough:

    * a conversion is counted **at the origin**, so a CDN holding this page for
      `max-age=60` swallows every conversion after the first — the experiment
      would report a fraction of the truth and read as "the treatment did
      nothing";
    * the response carries a `Set-Cookie` that deletes the visitor's spent
      exposure, and a shared cache storing that would hand one visitor's
      cookie instructions to everyone else.

  Flagged for **every** visitor of a goal page, not only for those carrying an
  exposure: a cache header that differed by cookie would itself announce which
  visitors are in an experiment, and would be wrong for the next request anyway.
  """
  @spec goal_page?(Plug.Conn.t()) :: boolean()
  def goal_page?(conn), do: conn.private[:kiln_experiment_goal_page] == true

  defp convert_exposed(content_type, id, org_id, conn) do
    case targeting(org_id, content_type, id) do
      [] ->
        conn

      experiments ->
        conn
        |> Plug.Conn.put_private(:kiln_experiment_goal_page, true)
        |> convert(experiments, org_id)
    end
  end

  # At most ONE conversion per request, whatever the exposure cookie names
  # (#1007) — without this, a cookie carrying up to `Sticky.max_exposures/0`
  # arms across that many running experiments whose goal document is this same
  # page would convert every one of them in a single GET, which is exactly the
  # multiplier a scripted client wants: several conversions bought for the
  # price of one request, on a rate limit that was sized for a page view rather
  # than a write.
  #
  # The tie-break is deterministic rather than "whichever the cookie lists
  # first": `experiments` is sorted by id here, same as the variant sort below,
  # for the same reason — the cookie is attacker-controlled and its ordering is
  # not something this code should let pick the winner. `targeting/3` already
  # walked `Experiments.running/1` in `inserted_at` order, so re-sorting by id
  # trades "oldest experiment wins" for "lowest id wins"; both are arbitrary
  # from a visitor's point of view, and id is the stable one two nodes agree on
  # without a query.
  defp convert(conn, experiments, org_id) do
    {exposed, conn} = Sticky.exposures(conn)

    case first_converted_variant(experiments, exposed) do
      nil ->
        conn

      variant_id ->
        count_conversion(variant_id, org_id)
        Sticky.put_exposures(conn, exposed -- [variant_id])
    end
  end

  defp count_conversion(variant_id, org_id) do
    async(fn ->
      Experiments.record_conversion(variant_id, authorize?: false, tenant: org_id)
    end)
  end

  # A cached read, and the only work an ordinary page pays for this feature.
  defp targeting(org_id, content_type, id) do
    org_id
    |> Experiments.running()
    |> Enum.filter(&goal_document?(&1, content_type, id))
  end

  # The first (by the tie-break above) experiment with a matching exposed
  # variant, and within it the first (by id) matching variant — a visitor
  # carries at most one arm of any given experiment, so trusting a hand-edited
  # cookie that lists two would be trusting the attacker to pick.
  defp first_converted_variant(experiments, exposed) do
    experiments
    |> Assignment.sort_by_id()
    |> Enum.find_value(fn experiment ->
      variant = experiment.variants |> Assignment.sort_by_id() |> Enum.find(&(&1.id in exposed))
      variant && variant.id
    end)
  end

  # Two goals convert on a later page, and they name that page differently.
  # `:content_view` states it outright; `:funnel_completion` names a funnel and
  # means its FINAL step (#1010), so if an editor reorders the funnel the goal
  # follows without anyone editing the experiment.
  #
  # BOTH carry the self-conversion guard below, for the reason spelled out over
  # the funnel clause. The two differ only in how reachable the state is today —
  # not in what happens if it is reached — so they are guarded the same way.
  defp goal_document?(%{goal: :content_view} = experiment, content_type, id) do
    type = to_string(content_type)

    experiment.goal_content_type == type and experiment.goal_document_id == id and
      not experimented_document?(experiment, type, id)
  end

  # The self-conversion guard has to be HERE as well as in
  # `Validations.GoalConfigured`, and that is a consequence of the feature
  # rather than belt-and-braces: `:start` refuses a funnel whose last step is
  # the experimented document, but the whole point of naming a funnel is that
  # editing it moves the goal — so an editor can drag that document to the end
  # afterwards, and nothing about a funnel write knows an experiment exists.
  #
  # Left unguarded it is not a small error. `assign_sticky` writes the exposure
  # and `record_content_view/3` reads it back off the same conn a few lines
  # later, so the impression would convert itself within one request, the
  # exposure would be spent, and the next request would mint and convert another
  # — every arm reporting 100% forever.
  #
  # The `:content_view` clause above is the same failure with a narrower way in.
  # `:start` refuses a self-goal and a running experiment cannot be edited, so
  # today it takes a seed or a direct write — but "unreachable" is a property of
  # the *write* layer, and this is the *delivery* layer. `/editor/experiments`
  # (#982) adds an editing surface, and `Health.blocked_reason/1` (#1008) reports
  # `:goal_is_self` as "no usable result", which is the opposite of what an
  # unguarded delivery would do. Guarding here is what makes that report true.
  defp goal_document?(%{goal: :funnel_completion} = experiment, content_type, id) do
    case Experiments.funnel_target(experiment) do
      {type, document_id} ->
        type == to_string(content_type) and document_id == id and
          not experimented_document?(experiment, type, document_id)

      nil ->
        false
    end
  end

  defp goal_document?(_experiment, _content_type, _id), do: false

  defp experimented_document?(experiment, type, document_id) do
    experiment.content_type == type and experiment.document_id == document_id
  end

  @doc """
  The variant to serve a headless caller, bucketed by their `variant_key`.

  **No key means no variant.** Drawing one at random would be the mistake the
  built-in site avoids by going `private, no-store`: a keyless headless request
  is one URL for every caller under `public, max-age=300`, so a CDN would cache
  whichever arm the first caller drew and serve it to everyone for five minutes
  — a 100/0 split reported as a fair one. A caller who has not opted in with a
  key gets the canonical document, which is also the honest default.

  With a key the choice is deterministic, so the caller owns stickiness and an
  edge cache can hold one entry per arm.
  """
  @spec assign_keyed(String.t(), struct(), String.t() | nil) :: struct() | nil
  def assign_keyed(content_type, record, key) when is_binary(key) and key != "",
    do: do_assign(content_type, record, key)

  def assign_keyed(_content_type, _record, _key), do: nil

  defp do_assign(content_type, %{id: id, org_id: org_id}, key) do
    with experiment when not is_nil(experiment) <-
           Experiments.for_document(org_id, content_type, id),
         true <- attributable?(experiment),
         variant when not is_nil(variant) <- Assignment.choose(experiment.variants, key) do
      record_impression(variant, org_id)
      variant
    else
      _none -> nil
    end
  rescue
    # A page must render even if the experiment layer is broken. The canonical
    # document is always the safe answer.
    error ->
      Logger.warning("Experiments.Delivery.assign failed: #{Exception.message(error)}")
      nil
  end

  defp do_assign(_content_type, _record, _key), do: nil

  # A `:content_view` experiment serves NOTHING on a surface that cannot count
  # its conversions — the stateless site with `sticky` off, and every headless
  # caller. `:start` refuses to launch one while sticky is off, but an operator
  # can turn it off afterwards, and a headless deployment was never gated at all.
  #
  # Serving it anyway is the worse half of the failure this goal was built to
  # avoid: the arm splits traffic and books impressions on a denominator the
  # numerator can never reach, so the results are not merely absent but wrong —
  # a real effect on the built-in site is diluted by headless traffic nobody can
  # see. A headless caller's `variant_key` says which arm they *would* be in,
  # never that they fetched the experimented document.
  #
  # Not `Health.blocked_reason/1`: this is the narrower question of whether
  # *this request's surface* can be attributed, answered on the hot path with no
  # query. `Health` answers whether the experiment can convert on any surface,
  # for the operator, and is deliberately allowed a lookup (#1008).
  defp attributable?(experiment), do: not Experiments.later_page_goal?(experiment)

  @doc """
  Count one conversion against `variant_id`.

  Called from the form-submission path, where the id arrived as a **hidden field
  on a public, CSRF-free POST** — so it is attacker-controlled and is checked
  before anything is written.

  The id must name a variant of a currently-**running** experiment on *this*
  site. Without that check the endpoint would accept any string: a random uuid
  would mint a `VariantDay` row (there is no foreign key on `variant_id`, so the
  table would grow without bound), and another org's variant id would write a
  conversion into their results.

  The check costs nothing — the running set is already cached for delivery, and
  it is the same lookup that decided to serve a variant in the first place.

  What this does **not** prevent is a visitor replaying the arm they were
  legitimately served. That is inherent to any client-reported conversion and
  is bounded by the form endpoint's own rate limit; the point here is that the
  blast radius stops at "an arm someone could see", not "any row in the table".
  """
  @spec record_conversion(String.t() | nil, Ash.UUID.t(), keyword()) :: :ok
  def record_conversion(variant_id, org_id, opts \\ [])

  def record_conversion(variant_id, org_id, opts) when is_binary(variant_id) do
    if converts?(variant_id, org_id, Keyword.get(opts, :form_id)) do
      count_conversion(variant_id, org_id)
    end

    :ok
  end

  def record_conversion(_variant_id, _org_id, _opts), do: :ok

  # Two checks, and the second is the one that keeps a result meaningful.
  #
  # The variant must belong to a running experiment on this site — otherwise a
  # random uuid mints a `VariantDay` row (there is no foreign key) and another
  # org's id writes into their results.
  #
  # And the submitted form must be **that experiment's goal form**. Without it
  # every form on the site converts every arm: an attacker reads a treatment's
  # id off any page's hidden field, posts an unrelated newsletter form with it,
  # and picks the winner. A `nil` goal form is treated as "no form converts this
  # experiment" rather than "any form does" — an experiment whose goal was never
  # configured has not been told what success looks like.
  defp converts?(variant_id, org_id, form_id) do
    # `enabled?()` here as well as in `for_document/3`: the switch is documented
    # as "whether this deployment serves experiments at all", and a public form
    # POST carrying a stale `_kiln_variant` is the other way in.
    if Experiments.enabled?(), do: matching_experiment?(variant_id, org_id, form_id), else: false
  end

  defp matching_experiment?(variant_id, org_id, form_id) do
    org_id
    |> Experiments.running()
    |> Enum.any?(fn experiment ->
      experiment.goal == :form_submission and
        not is_nil(experiment.goal_form_id) and
        experiment.goal_form_id == form_id and
        Enum.any?(experiment.variants, &(&1.id == variant_id))
    end)
  rescue
    _error -> false
  end

  defp record_impression(variant, org_id) do
    async(fn ->
      Experiments.record_impression(variant.id, authorize?: false, tenant: org_id)
    end)
  end

  # Same posture as `KilnCMSWeb.ViewTracking`: off the request path, and a
  # failure is swallowed rather than surfaced to a visitor.
  defp async(fun) do
    if Application.get_env(:kiln_cms, :async_analytics, true) do
      Task.Supervisor.start_child(KilnCMS.TaskSupervisor, fn -> safely(fun) end)
    else
      safely(fun)
    end

    :ok
  end

  defp safely(fun) do
    fun.()
  rescue
    _error -> :ok
  end
end
