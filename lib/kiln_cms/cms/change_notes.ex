defmodule KilnCMS.CMS.ChangeNotes do
  @moduledoc """
  *Why* an edit was made: a short note stored on the edit's own version row
  (`change_note`) and shown in the editor's History.

  ## Where a note can be given

  `:update`, `:publish`, `:publish_changes` and `:restore_version` take a
  `change_note` argument, on every surface that runs them (the editor,
  JSON:API, GraphQL, MCP). `KilnCMS.CMS.Changes.RecordChangeNote` copies it to
  the version. Saving a published record's working copy does not take one:
  those saves are drafts of a change, coalesced as text autosaves, and the
  change readers see is **Publish changes**, which does.

  ## When one is asked for

  A site lists the content types that ask (`change_note_types` on
  `KilnCMS.CMS.SiteEditorialSettings`, set on the Safety fields page). For
  those types the editor shows a **Why this change?** input next to Save and
  refuses a draft's Save and a Publish changes without one. It does that by
  setting the `require_change_note` context marker on those two writes. No
  other writer is refused for leaving a note out — an API client, an MCP tool,
  the reverse field, a scheduled publish — the posture
  `KilnCMS.CMS.Severity` takes with severities: asking is the editor's job,
  and a write that cannot ask must not fail for it.
  """

  alias KilnCMS.CMS.EditorialSettings

  @max_length 2000

  @doc "The longest note stored, in characters."
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @doc "A note trimmed, or `nil` when blank or not a string."
  @spec normalize(term()) :: String.t() | nil
  def normalize(note) when is_binary(note) do
    case String.trim(note) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def normalize(_note), do: nil

  @doc """
  Whether `org_id`'s site asks for a note on `type_name` (a
  `KilnCMS.CMS.ContentTypes.type_name_for/1` name). Uncached: it is read only
  for a write that carries the editor's marker, and from inside its
  transaction (see `KilnCMS.CMS.EditorialSettings`).
  """
  @spec required?(Ash.UUID.t() | nil, String.t() | nil) :: boolean()
  def required?(nil, _type_name), do: false
  def required?(_org_id, nil), do: false

  def required?(org_id, type_name),
    do: to_string(type_name) in EditorialSettings.change_note_types(org_id)
end
