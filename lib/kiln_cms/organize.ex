defmodule KilnCMS.Organize do
  @moduledoc """
  Derived organization (#1596, `docs/content-organization-plan.md` §6): the
  library-level layer over `KilnCMS.Search.Related`'s embeddings — semantic
  clusters as a browse axis, a bulk tag-review surface, an under-organized
  queue, a taxonomy-health report and content gaps read as organization
  signals. The console surface is `KilnCMSWeb.OrganizeLive`.

  ## Two contracts every function here keeps

  **Semantic search off ⇒ empty, quietly.** `KilnCMS.Search.semantic?/0`
  defaults to false and the ML stack is opt-in (`KILN_ML=1`), so on a default
  install this whole workstream is invisible: each public function answers its
  empty shape before it touches the database, `KilnCMS.LLM.Budget` or the
  embedder. That includes the parts that need no vectors (single-use terms,
  content nothing links to) — the maintainer's call on #1596, recorded there.

  **Every bulk path is bounded, and the bound is stated.** See `bounds/0` for
  the numbers and `KilnCMS.Organize.Tagging` for the one path that can reach
  model inference. The browse surfaces (clusters, queue, health) read stored
  vectors only and never infer.

  ## Terms go through one seam

  Every read or write of `Tag`/`Category` in this layer goes through
  `KilnCMS.Organize.Terms`, so the 2.0 vocabulary migration (#1595) has one
  module to change rather than five.
  """

  @defaults [
    # Published documents clustered per page load (clusters read one
    # SQL-averaged centroid per document — `KilnCMS.Search.DocumentCentroids`).
    cluster_limit: 300,
    # Published documents scored against the tag vocabulary by the queue's
    # "far from every tag" leg.
    far_limit: 100,
    # Rows the queue's "no tags or category" leg lists.
    untermed_limit: 50,
    # Documents one bulk tag-review run may hold.
    bulk_limit: 20,
    # Tags the health report and the in-memory distance passes consider.
    term_limit: 500,
    # Documents the "nothing links here" check considers.
    inbound_limit: 300,
    # Zero-result queries read for the gap signal.
    gap_limit: 20
  ]

  @doc """
  The size bounds every surface here runs under, overridable per deployment
  under `config :kiln_cms, KilnCMS.Organize`. Defaults:

  #{Enum.map_join(@defaults, "\n", fn {k, v} -> "  * `#{k}`: #{v}" end)}
  """
  @spec bounds() :: keyword()
  def bounds, do: Keyword.merge(@defaults, Application.get_env(:kiln_cms, __MODULE__, []))

  @doc "One bound from `bounds/0`."
  @spec bound(atom()) :: pos_integer()
  def bound(key), do: Keyword.fetch!(bounds(), key)

  @doc "Whether any of this layer answers anything — `KilnCMS.Search.semantic?/0`."
  @spec enabled?() :: boolean()
  def enabled?, do: KilnCMS.Search.semantic?()
end
