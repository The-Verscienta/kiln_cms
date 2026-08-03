defmodule Kiln.Advisory.Checks.InternalLinksTest do
  @moduledoc "The broken-internal-link advisory (#474)."
  use ExUnit.Case, async: true

  alias Kiln.Advisory.Body
  alias Kiln.Advisory.Checks.InternalLinks
  alias Kiln.Advisory.Context

  defp context(paths, targets) do
    Context.new(%{}, %Body{internal_link_paths: paths}, facts: %{link_targets: targets})
  end

  test "a document with no internal links has nothing to judge" do
    assert InternalLinks.check(context([], %{})) == :n_a
  end

  test "a caller that resolved nothing gets :n_a, not a clean bill of health" do
    # The fact is absent because this caller did no lookup — reporting a pass
    # would claim an answer nobody computed. Same reason the empty map is :n_a.
    assert InternalLinks.check(context(["/a"], nil)) == :n_a
    assert InternalLinks.check(context(["/a"], %{})) == :n_a
  end

  test "every link resolving is a pass" do
    assert InternalLinks.check(context(["/a", "/b"], %{"/a" => :published, "/b" => :published})) ==
             :ok
  end

  test "a redirected link is a pass, not a finding" do
    # Delivery serves a 301 for it. Flagging a working redirect is the fastest
    # way to make an advisory panel something authors learn to ignore.
    assert InternalLinks.check(context(["/old"], %{"/old" => :redirected})) == :ok
  end

  test "a missing target is an error naming the path" do
    assert [finding] = InternalLinks.check(context(["/gone"], %{"/gone" => :missing}))
    assert finding.severity == :error
    assert finding.code == :internal_links_missing
    assert finding.args.count == 1
    assert finding.args.paths == ["/gone"]
  end

  test "an unpublished target is a warning, separately from a missing one" do
    findings =
      InternalLinks.check(
        context(["/gone", "/draft"], %{"/gone" => :missing, "/draft" => {:unpublished, :draft}})
      )

    # Two findings, not one bucket: "publish the draft" and "this link is wrong"
    # are opposite actions, and merging them sends an editor hunting for a typo
    # in a link that is perfectly correct.
    assert [missing, unpublished] = findings
    assert missing.code == :internal_links_missing
    assert missing.args.paths == ["/gone"]
    assert unpublished.code == :internal_links_unpublished
    assert unpublished.severity == :warning
    assert unpublished.args.paths == ["/draft"]
  end

  test "several broken links of one kind are one finding, listing them sorted" do
    assert [finding] =
             InternalLinks.check(context(["/z", "/a"], %{"/z" => :missing, "/a" => :missing}))

    assert finding.args.count == 2
    assert finding.args.paths == ["/a", "/z"]
  end

  test "a resolution for a path this document does not link is ignored" do
    # The fact map may hold more than one document's paths — a caller resolving
    # a batch. Reporting a neighbour's broken link on this page would be
    # baffling.
    assert InternalLinks.check(
             context(["/mine"], %{"/mine" => :published, "/someone-elses" => :missing})
           ) == :ok
  end

  test "a linked path with no resolution entry is not invented into a finding" do
    # `nil` for a path means "nobody looked", which is not evidence of breakage.
    assert InternalLinks.check(context(["/a", "/b"], %{"/a" => :published})) == :ok
  end

  test "an explicit nil facts map is the absent-fact path, not a crash" do
    # A caller writing `facts: opts[:facts]` passes nil. `Map.get(nil, ...)`
    # would BadMapError inside the check, which the registry then swallows —
    # turning a crash into a silently missing advisory.
    context = Context.new(%{}, %Body{internal_link_paths: ["/a"]}, facts: nil)
    assert InternalLinks.check(context) == :n_a
  end

  test "unknown and external resolutions are never reported" do
    # `:unknown` is the resolver saying "not my namespace". Reporting it would
    # flag `/`, `/search`, every plugin route and every deep path as broken.
    assert InternalLinks.check(
             context(["/search", "/x"], %{"/search" => :unknown, "/x" => :external})
           ) == :ok
  end

  test "the check is registered, so the editor panel actually runs it" do
    assert InternalLinks in Kiln.Advisory.Registry.checks()
  end
end
