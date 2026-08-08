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
      async(fn ->
        Experiments.record_conversion(variant_id, authorize?: false, tenant: org_id)
      end)
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
