defmodule Kiln.Advisory.Checks.InternalLinks do
  @moduledoc """
  Internal links whose target no longer resolves (#474).

  An author links `/blog/the-thing`. Later it is renamed, unpublished or
  deleted, and nothing says so — the link keeps rendering and quietly 404s for
  every reader. This is the deterministic half of the broken-link checker: no
  network, no scheduling, no per-org opt-in, just "does this path resolve on
  this site right now".

  ## Two findings, because they are two different jobs

    * `:internal_links_missing` (`:error`) — nothing resolves the path in any
      state. The link is wrong, or the target was deleted.
    * `:internal_links_unpublished` (`:warning`) — a real document, not
      currently served. Nothing is *broken*; someone needs to publish it, or the
      author linked a draft too early.

  Delivery cannot tell those apart — both are a 404 to a visitor — but they need
  opposite actions, and collapsing them would send an editor hunting for a typo
  in a link that is perfectly correct.

  A path covered by a redirect is **not** reported. A published rename leaves a
  `KilnCMS.CMS.Redirect` behind and delivery serves a 301; flagging that reports
  a working feature as a fault, which is the fastest way to make an advisory
  panel something authors learn to ignore.

  ## `:n_a` when nobody resolved anything

  Resolution is a query per path, so it happens in the caller
  (`KilnCMS.Links.Internal.resolve_all/3`) and arrives as a context fact. A
  caller that did not do that work gets `:n_a` rather than a clean bill of
  health — see `Kiln.Advisory.Context` on why a check must not invent an answer
  from a missing fact. A document with no internal links is also `:n_a`: there
  is nothing to judge, and reporting a pass would flatter it.
  """
  use Kiln.Advisory

  alias Kiln.Advisory.Context

  @impl Kiln.Advisory
  def check(%Context{body: %{internal_link_paths: []}}), do: :n_a

  def check(%Context{} = context) do
    case Context.fact(context, :link_targets) do
      nil -> :n_a
      targets when map_size(targets) == 0 -> :n_a
      targets -> findings(context, targets)
    end
  end

  defp findings(context, targets) do
    # Only the paths this document actually links. The fact map may legitimately
    # hold more (a caller resolving several documents at once), and reporting a
    # neighbour's broken link on this page would be baffling.
    grouped =
      context.body.internal_link_paths
      |> Enum.map(&{&1, Map.get(targets, &1)})
      |> Enum.group_by(fn {_path, resolution} -> bucket(resolution) end, &elem(&1, 0))

    case Enum.flat_map([:missing, :unpublished], &finding_for(&1, grouped)) do
      [] -> :ok
      findings -> findings
    end
  end

  # `Internal.problem?/1` decides what counts, so this module and the resolver
  # cannot drift on whether a redirect is a fault. Everything not a problem —
  # published, redirected, unknown, external, or a path nobody resolved — is one
  # bucket the checker never reports.
  defp bucket({:unpublished, _state}), do: :unpublished

  defp bucket(resolution) do
    if KilnCMS.Links.Internal.problem?(resolution), do: :missing, else: :fine
  end

  defp finding_for(kind, grouped) do
    case Map.get(grouped, kind, []) do
      [] ->
        []

      paths ->
        # The paths ride along so the panel can name them — an advisory that says
        # "3 broken links" without saying which is a search task, not advice.
        [
          finding(severity(kind), code(kind), :body, %{
            count: length(paths),
            paths: Enum.sort(paths)
          })
        ]
    end
  end

  defp severity(:missing), do: :error
  defp severity(:unpublished), do: :warning

  defp code(:missing), do: :internal_links_missing
  defp code(:unpublished), do: :internal_links_unpublished
end
