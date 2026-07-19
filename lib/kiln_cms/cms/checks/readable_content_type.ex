defmodule KilnCMS.CMS.Checks.ReadableContentType do
  @moduledoc """
  Matches an editor whose *editorial* visibility covers this content type
  (granular RBAC #332, read axis).

  The editor's effective `readable_types` scope (membership-then-user, like
  `EditableContentType` — see `KilnCMS.Accounts.Scoping`) names the content
  types where they see **everything** (drafts, in-review, archived). An empty
  scope means unrestricted — the phase-1 behavior, every editor sees all
  content.

  This check gates only the editors-see-everything grant in the content read
  policy. When it does NOT match (a restricted editor, out-of-scope type), the
  policy falls through to the published/audience filters — so the editor still
  reads that type like any signed-in consumer: **published** content, gated by
  audience. Published visibility is never narrowed by this axis; it scopes
  editorial (non-published) visibility only. Admins bypass; viewers and
  anonymous actors never match (they were never in the editors grant).
  """
  use Ash.Policy.SimpleCheck

  alias KilnCMS.Accounts.Scoping

  @impl Ash.Policy.Check
  def describe(_opts), do: "an editor whose editorial read scope covers this content type"

  @impl Ash.Policy.SimpleCheck
  def match?(%{role: :editor} = actor, %{resource: resource, subject: subject}, _opts) do
    Scoping.permitted?(actor, subject, :readable_types, content_type(resource))
  end

  def match?(_actor, _context, _opts), do: false

  defp content_type(resource) do
    if function_exported?(resource, :__kiln_content_type__, 0) do
      to_string(resource.__kiln_content_type__())
    end
  end
end
