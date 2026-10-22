defmodule KilnCMS.CMS.PlainFields do
  @moduledoc """
  The plain-text rendition of a record's `:text` custom fields that opt in
  with `deliver_plain` (`KilnCMS.CMS.FieldDefinition`).

  A `:text` field is a plain textarea, but importers put HTML fragments in
  it, and delivery passes the stored value through untouched. A web client
  renders that; a native one has to run a browser engine's HTML parser to
  show a paragraph. So delivery carries a sibling map,
  `custom_fields_plain`, holding each flagged field's value through
  `KilnCMS.PlainText.from_html/1`, beside `custom_fields` — which is never
  rewritten.

  One rule, three surfaces: the fired `:json` artifact
  (`KilnCMS.Firing.Engine`, so `/api/content` and `/api/sync`), the
  `custom_fields_plain` calculation (JSON:API and GraphQL, on request), and
  the schema (`KilnCMS.SchemaExport`).

  Every flagged field has a key, `nil` when the record holds no string for
  it, so a client reads one shape per type.
  """

  alias KilnCMS.PlainText

  @doc "The names of the fields among `definitions` that deliver a plain rendition."
  @spec names([KilnCMS.CMS.FieldDefinition.t()]) :: [String.t()]
  def names(definitions) do
    for %{deliver_plain: true, field_type: :text} = definition <- definitions,
        is_nil(Map.get(definition, :link_of_id)),
        do: definition.name
  end

  @doc """
  The `custom_fields_plain` map for `values` under `definitions`, or `nil`
  when no definition opts in — the caller leaves the key out then.

      iex> defs = [%{name: "body", field_type: :text, deliver_plain: true}]
      iex> KilnCMS.CMS.PlainFields.project(%{"body" => "<p>A &amp; B</p>"}, defs)
      %{"body" => "A & B"}
      iex> KilnCMS.CMS.PlainFields.project(%{}, defs)
      %{"body" => nil}
      iex> KilnCMS.CMS.PlainFields.project(%{"body" => "x"}, [])
      nil
  """
  @spec project(map() | nil, [KilnCMS.CMS.FieldDefinition.t()]) :: map() | nil
  def project(values, definitions) do
    case names(definitions) do
      [] -> nil
      names -> Map.new(names, &{&1, plain(Map.get(values || %{}, &1))})
    end
  end

  defp plain(value) when is_binary(value), do: PlainText.from_html(value)
  defp plain(_value), do: nil
end
