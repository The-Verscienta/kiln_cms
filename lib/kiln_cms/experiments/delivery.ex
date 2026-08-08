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

  Stateless: drawn per request, nothing stored. See `KilnCMS.Experiments` on why
  this surface has no visitor key.
  """
  @spec assign(String.t(), struct()) :: struct() | nil
  def assign(content_type, record) do
    assign(content_type, record, nil)
  end

  @doc """
  The variant to serve, bucketed by a caller-supplied `key`.

  A binary `key` makes the choice deterministic — the same key always resolves
  to the same variant — which is what lets a headless caller own stickiness and
  an edge cache vary on the result.
  """
  @spec assign(String.t(), struct(), String.t() | nil) :: struct() | nil
  def assign(content_type, %{id: id, org_id: org_id}, key) do
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

  def assign(_content_type, _record, _key), do: nil

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
  @spec record_conversion(String.t() | nil, Ash.UUID.t()) :: :ok
  def record_conversion(variant_id, org_id) when is_binary(variant_id) do
    if running_variant?(variant_id, org_id) do
      async(fn ->
        Experiments.record_conversion(variant_id, authorize?: false, tenant: org_id)
      end)
    end

    :ok
  end

  def record_conversion(_variant_id, _org_id), do: :ok

  defp running_variant?(variant_id, org_id) do
    org_id
    |> Experiments.running()
    |> Enum.any?(fn experiment ->
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
