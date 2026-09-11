defmodule KilnCMS.CMS.Checks.WritesRedirectTarget do
  @moduledoc """
  Matches an actor who may **write the content record a redirect targets**.

  The content editor lists the redirects standing under a record's address and
  offers a Delete on each (modelled on texttile's editor).
  Whoever may change the record's slug is the person those rows exist for, so
  they may also retire one — without being an org admin, which is what the
  `/editor/redirects` page needs. Nothing wider: the grant is decided by
  re-asking the target's own `:update` policy (`EditableContentType` for
  editors, so a type-scoped editor cannot prune a redirect at a type they may
  not author), and a redirect whose target is gone or unregistered matches
  nobody here — pruning dead rows stays an admin job.

  Only `destroy` changesets on a loaded `Redirect` row are considered; a
  create, an update or a query-shaped subject never matches.
  """
  use Ash.Policy.SimpleCheck

  require Ash.Query

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Redirect
  alias KilnCMS.CMS.Slugs

  @impl Ash.Policy.Check
  def describe(_opts), do: "an editor who may write the record this redirect targets"

  @impl Ash.Policy.SimpleCheck
  def match?(%{} = actor, %{subject: %Ash.Changeset{data: %Redirect{} = redirect}}, _opts) do
    org_id = redirect.org_id

    with ct when not is_nil(ct) <- ContentTypes.get(redirect.target_type, org_id),
         %{} = target <- load_target(ct, redirect.target_id, org_id) do
      Ash.can?({target, :update}, actor, tenant: org_id)
    else
      _ -> false
    end
  end

  def match?(_actor, _context, _opts), do: false

  # System read (`authorize?: false`, the same bypass `Redirects.resolve/3`
  # uses): the row is only looked up so its OWN policy can be asked, with the
  # actor, on the next line. Reading it as the actor would turn "may not read
  # this draft" into "may not delete its redirect", which is the same answer
  # by a longer road — and a read filter on a `:read` action could hide a
  # record the actor may perfectly well update.
  defp load_target(ct, target_id, org_id) do
    Slugs.storage_resource(ct)
    |> Ash.Query.filter(id == ^target_id)
    |> Ash.read_one!(authorize?: false, tenant: org_id)
  end
end
