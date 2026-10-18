defmodule KilnCMSWeb.Graphql.ContentRecord do
  @moduledoc """
  Typed nested reads through `:reference` custom fields (relationships plan,
  R7): the `ContentRecord` interface and the `ContentReference` /
  `ContentReferrer` objects every content type's `references` and
  `referencedBy` fields return.

  `ContentRecord` is an **interface**, not a union. Every compiled type has its
  own GraphQL object, but every dynamic type shares the one `Entry` object
  (D17), so a union could only ever say "some Entry". An interface lets a
  client select the common fields directly and narrow with `... on Post` (or
  `... on Entry { typeName }`) where it needs more.

  `KilnCMSWeb.Graphql.ContentRecord.Notation.implement_content_record/1` makes
  every content object implement it; `KilnCMSWeb.Graphql.References` resolves
  the fields.
  """
  use Absinthe.Schema.Notation

  require KilnCMSWeb.Graphql.ContentRecord.Notation

  alias KilnCMSWeb.Graphql.ContentRecord.Notation
  alias KilnCMSWeb.Graphql.References

  @desc """
  A content record of any type: a compiled type (`Page`, `Post`, …) or an
  `Entry` of an admin-defined type. Narrow with `... on Post { … }`.
  """
  interface :content_record do
    field :id, non_null(:id)
    field :title, non_null(:string)
    field :slug, non_null(:string)
    field :locale, :string
    field :state, non_null(:string)
    field :published, :boolean
    field :published_at, :datetime
    field :inserted_at, non_null(:datetime)
    field :updated_at, non_null(:datetime)
    field :custom_fields, non_null(:json_string)

    Notation.reference_fields()

    resolve_type &References.resolve_type/2
  end

  @desc """
  One target of a `:reference` field, in the field's order. `target` is null
  only when the edge points at a record the reader may not read in full.
  """
  object :content_reference do
    @desc "The target's place in the field's list, from 0."
    field :position, non_null(:integer)

    @desc """
    Data stored on the connection itself (the field's link fields), passed
    through as stored. An empty object when the field has none.
    """
    field :link, :json

    field :target, :content_record do
      resolve &References.target/3
    end
  end

  @desc "One record that links to this one through a `:reference` field."
  object :content_referrer do
    @desc "The source's custom field the link was written from."
    field :field, non_null(:string)

    @desc "This record's place in the source field's list, from 0."
    field :position, non_null(:integer)

    @desc "Data stored on the connection itself, passed through as stored."
    field :link, :json

    field :source, :content_record do
      resolve &References.source/3
    end
  end
end
