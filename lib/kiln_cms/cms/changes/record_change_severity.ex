defmodule KilnCMS.CMS.Changes.RecordChangeSeverity do
  @moduledoc """
  Stores *how much a published edit matters* on the edit's own version row
  (`KilnCMS.CMS.Severity` has the rule and the vocabulary).

  Applied once, in the shared Content macro's `changes` block, on every update
  action. It does nothing unless the site lists a safety field for the
  record's type (`KilnCMS.CMS.SiteSafetyFields`) and the write is a published
  edit: the document is live, or the action makes it live.

  ## Detection

  In a `before_action` hook registered last, so every change has landed and the
  comparison is of what is about to be written against the row:

    * **A live document** (`data.state == :published`): a listed field differs
      from the row's value. This is how `:publish_changes` is seen — it accepts
      nothing, and `PromoteWorkingCopy` moves the held values into the live
      attributes — and how a `:restore_version` is seen, whose fold is written
      in a hook of its own. Input is not consulted, so a form that posts every
      field unchanged is not an edit of any of them.
    * **A first publish** (the action leaves the state `:published` on a record
      that was not): there is no live value to differ from, so a listed field
      counts when it is non-empty.

  Saving a working copy and autosave are not published edits (the live columns
  do not move) and are not looked at.

  ## Outcome

  `nil` when no listed field is touched — nothing is written, whatever
  `change_severity` the caller sent. Otherwise the `change_severity` argument,
  else an error on `:change_severity` if the changeset carries the
  `require_change_severity` context marker (the admin editor sets it, because it
  shows the selector), else `:notable`. The result goes to
  `changeset.context[:paper_trail_metadata][:change_severity]`, which AshPaperTrail
  copies into the version it writes in the same transaction.

  The settings are read when the changeset is built — outside the action's
  transaction when there is none around it, so they can be cached.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Severity
  alias KilnCMS.CMS.VersionFields
  alias KilnCMS.CMS.WorkingCopy

  # Actions that can leave a record published without it having been.
  @publishing [:publish, :publish_scheduled]

  @impl true
  def change(changeset, _opts, _context) do
    if candidate?(changeset) do
      names =
        Severity.safety_fields_for(changeset.data.org_id, ContentTypes.type_name_for(changeset))

      if names == [],
        do: changeset,
        else: Ash.Changeset.before_action(changeset, &decide(&1, names))
    else
      changeset
    end
  end

  # Cheap gate ahead of the settings read: a draft edit is never a published
  # edit, and an action PaperTrail does not version cannot carry a severity.
  defp candidate?(%{data: %{state: state}, action: %{name: name}, resource: resource}) do
    (state == :published or name in @publishing) and
      name not in AshPaperTrail.Resource.Info.ignore_actions(resource)
  end

  defp candidate?(_changeset), do: false

  defp decide(changeset, names) do
    if touches?(changeset, fields(changeset.resource, names)) do
      severity = Ash.Changeset.get_argument(changeset, :change_severity)

      cond do
        severity != nil -> record(changeset, severity)
        changeset.context[:require_change_severity] == true -> missing(changeset)
        true -> record(changeset, Severity.default())
      end
    else
      changeset
    end
  end

  defp record(changeset, severity) do
    metadata =
      Map.put(changeset.context[:paper_trail_metadata] || %{}, :change_severity, severity)

    Ash.Changeset.set_context(changeset, %{paper_trail_metadata: metadata})
  end

  defp missing(changeset) do
    Ash.Changeset.add_error(changeset,
      field: :change_severity,
      message: "choose a severity for this change"
    )
  end

  # ── Which fields ──────────────────────────────────────────────────────────

  # `{:attribute, atom}` for an editorial column, `{:custom, "name"}` for a
  # custom field. Names are matched against the resource's own list rather than
  # converted to atoms, and a bookkeeping column (`lock_version`, `org_id`, the
  # working copy) is never a safety field: it is a custom field name or nothing.
  defp fields(resource, names) do
    editorial =
      resource
      |> VersionFields.content_fields()
      |> Enum.reject(&working_copy?/1)

    if "*" in names do
      Enum.map(editorial, &{:attribute, &1})
    else
      by_name = Map.new(editorial, &{to_string(&1), &1})
      names |> Enum.uniq() |> Enum.map(&field_ref(Map.fetch(by_name, &1), &1))
    end
  end

  defp field_ref({:ok, :custom_fields}, name), do: {:custom, name}
  defp field_ref({:ok, attribute}, _name), do: {:attribute, attribute}
  defp field_ref(:error, name), do: {:custom, name}

  defp working_copy?(name), do: name |> to_string() |> String.starts_with?("working_")

  # ── Touched? ──────────────────────────────────────────────────────────────

  defp touches?(%{data: %{state: :published}} = changeset, fields),
    do: Enum.any?(fields, &differs?(changeset, &1))

  defp touches?(changeset, fields) do
    if Ash.Changeset.get_attribute(changeset, :state) == :published,
      do: Enum.any?(fields, &present?(changeset, &1)),
      else: false
  end

  defp differs?(changeset, {:attribute, :blocks}) do
    not WorkingCopy.same_blocks?(
      changeset.resource,
      Ash.Changeset.get_attribute(changeset, :blocks),
      changeset.data.blocks
    )
  end

  defp differs?(changeset, {:attribute, :custom_fields}),
    do: blank(custom_map(changeset)) != blank(changeset.data.custom_fields)

  defp differs?(changeset, {:attribute, name}),
    do:
      blank(Ash.Changeset.get_attribute(changeset, name)) != blank(Map.get(changeset.data, name))

  defp differs?(changeset, {:custom, name}),
    do: blank(custom_map(changeset)[name]) != blank((changeset.data.custom_fields || %{})[name])

  defp present?(changeset, {:attribute, :blocks}),
    do: List.wrap(Ash.Changeset.get_attribute(changeset, :blocks)) != []

  defp present?(changeset, {:attribute, name}),
    do: blank(Ash.Changeset.get_attribute(changeset, name)) != nil

  defp present?(changeset, {:custom, name}), do: blank(custom_map(changeset)[name]) != nil

  defp custom_map(changeset), do: Ash.Changeset.get_attribute(changeset, :custom_fields) || %{}

  # An unset field, an empty string, an empty list and an empty map are the same
  # "nothing" — an edit that turns one into another is not a change of content.
  defp blank(value) when value in [nil, "", [], %{}], do: nil
  defp blank(value), do: value
end
