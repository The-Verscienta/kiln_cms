defmodule KilnCMS.Firing.Validations.KnownDocumentType do
  @moduledoc """
  Validates that a document-type attribute names a real content tier: `:entry`
  (the generic dynamic-type storage tier, D17), any compiled content type in
  the `KilnCMS.CMS.ContentTypes` registry, or `:media`.

  `:media` is a valid reference **target** and never a source: media usage
  tracking (#403) records `content -> media` edges so an editor can be told what
  a delete or a replace affects. A media item is not a document, has no
  artifacts and never fires, so it can never be a `from_type` — `only_target`
  spells that out rather than leaving it to convention.

  Replaces the old `one_of: [:page, :post, :entry]` attribute constraint,
  which silently excluded every `mix kiln.gen.content` type — firing an
  artifact for a generated type failed its upsert. A registry lookup must
  happen at runtime (a compile-time `one_of` would create a compile-order
  cycle between the Firing resources and the CMS domain), so it lives here as
  a validation.
  """
  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, opts, _context) do
    attributes = opts[:attributes] || [:document_type]
    only_target = opts[:only_target] || []

    Enum.reduce_while(attributes, :ok, fn attribute, :ok ->
      value = Ash.Changeset.get_attribute(changeset, attribute)

      cond do
        is_nil(value) ->
          {:cont, :ok}

        value == :entry or KilnCMS.CMS.ContentTypes.type?(value) ->
          {:cont, :ok}

        value in Keyword.get(only_target, attribute, []) ->
          {:cont, :ok}

        true ->
          {:halt, {:error, field: attribute, message: "unknown content type: #{inspect(value)}"}}
      end
    end)
  end
end
