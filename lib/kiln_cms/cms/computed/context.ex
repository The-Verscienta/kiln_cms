defmodule KilnCMS.CMS.Computed.Context do
  @moduledoc """
  Builds the value map a computed-field formula (`KilnCMS.CMS.Computed`) is
  evaluated against — the only data a formula can reach.

  Two entry points, one per evaluation site (#429):

    * `from_changeset/2` on write, reading the *effective* attribute values so
      a formula sees the merged result of the write rather than the record's
      pre-update state;
    * `from_document/3` on fire, reading a loaded document struct.

  Both produce the same shape, so a formula can't behave differently at the two
  sites:

      %{document: %{"title" => …, "body" => …, …}, fields: %{"price" => …}}

  `body` is the block tree's plain text (`KilnCMS.CMS.BlockText`), which is
  what `word_count`/`reading_time` are for. A scalar the resource doesn't
  declare — `excerpt` on a type without one — resolves to nil, so the same
  formula is safe to reuse across content types.
  """
  alias KilnCMS.CMS.BlockText

  # The document scalars exposed to formulas, kept in step with
  # `KilnCMS.CMS.Computed.document_refs/0` (`body` is derived, not an
  # attribute, so it isn't in this list).
  @scalars [:title, :slug, :locale, :excerpt, :seo_title, :seo_description, :seo_keywords]

  @doc "The context for a write, from the changeset's effective values."
  @spec from_changeset(Ash.Changeset.t(), map()) :: map()
  def from_changeset(changeset, fields) do
    document =
      @scalars
      |> Enum.filter(&Ash.Resource.Info.attribute(changeset.resource, &1))
      |> Map.new(&{to_string(&1), scalar(Ash.Changeset.get_attribute(changeset, &1))})
      |> Map.put("body", BlockText.to_text(Ash.Changeset.get_attribute(changeset, :blocks)))

    %{document: document, fields: fields}
  end

  @doc """
  The context for a loaded document. `body` may be supplied when the caller has
  already extracted the block text (firing does), sparing a second walk of the
  tree.
  """
  @spec from_document(struct(), map(), String.t() | nil) :: map()
  def from_document(document, fields, body \\ nil) do
    scalars = Map.new(@scalars, &{to_string(&1), scalar(Map.get(document, &1))})

    %{
      document: Map.put(scalars, "body", body || BlockText.to_text(Map.get(document, :blocks))),
      fields: fields
    }
  end

  # Formulas work over JSON-native scalars. `seo_keywords` is a list, so join it
  # into something a formula can interpolate or slugify rather than handing the
  # evaluator a term it renders as blank.
  defp scalar(value) when is_list(value), do: Enum.map_join(value, ", ", &to_string/1)
  defp scalar(value), do: value
end
