defmodule KilnCMS.CMS.Validations.AvailableTypeName do
  @moduledoc """
  Guards a `TypeDefinition` from colliding with anything that already owns its
  `name` or `path_segment`:

    * a **compiled** content type's type name, plural, or public path segment
      (compiled always wins — a dynamic type can never shadow `Page`/`Post`);
    * a **reserved router segment** (`/editor`, `/api`, `/search`, …), since
      dynamic types are delivered at `/<path_segment>/<slug>`. Only when the
      segment is being written, so a type whose segment was reserved later
      can still be edited (#2898);
    * a configured **locale prefix** (`/fr/...` routes);
    * a **built-in webhook event namespace** for the `name`
      (`KilnCMS.CMS.WebhookEndpoint.reserved_namespaces/0`: `release`, `task`,
      `form`, `tag`, …; #1965, #1994): a content type's events are
      `<name>.<verb>`, so a type named `release` would send
      `release.published`, the name content releases send. Only when the name
      is being written, so a type created before this rule can still be
      edited.

  Dynamic-vs-dynamic uniqueness is enforced by the resource's identities, not
  here.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.ContentTypes

  @impl true
  def validate(changeset, _opts, _context) do
    with :ok <- check(changeset, :name, taken_names()),
         :ok <- check_event_namespace(changeset) do
      check_path_segment(changeset)
    end
  end

  # Only when the segment is being written (#2898): a segment reserved after a
  # type took it must not block every later edit of that type.
  defp check_path_segment(changeset) do
    if Ash.Changeset.changing_attribute?(changeset, :path_segment),
      do: check(changeset, :path_segment, taken_segments()),
      else: :ok
  end

  defp check_event_namespace(changeset) do
    name = Ash.Changeset.get_attribute(changeset, :name)
    namespaces = KilnCMS.CMS.WebhookEndpoint.reserved_namespaces()

    if Ash.Changeset.changing_attribute?(changeset, :name) and name in namespaces do
      {:error,
       InvalidAttribute.exception(
         field: :name,
         message: "is a built-in webhook event namespace (#{Enum.join(namespaces, ", ")})",
         value: name
       )}
    else
      :ok
    end
  end

  defp check(changeset, field, taken) do
    case Ash.Changeset.get_attribute(changeset, field) do
      nil ->
        :ok

      value ->
        if value in taken do
          {:error,
           InvalidAttribute.exception(
             field: field,
             message: "is already used by a built-in content type or a reserved path",
             value: value
           )}
        else
          :ok
        end
    end
  end

  # A dynamic type may not take a compiled type's name or plural (either would
  # make the merged registry ambiguous).
  defp taken_names do
    Enum.flat_map(ContentTypes.all(), &[Atom.to_string(&1.type), &1.plural])
  end

  # ...nor serve at a URL segment the router or a compiled type already owns.
  defp taken_segments do
    compiled = ContentTypes.all() |> Enum.map(& &1.path_segment) |> Enum.reject(&is_nil/1)
    compiled ++ ContentTypes.reserved_path_segments()
  end
end
