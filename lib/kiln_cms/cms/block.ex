defmodule KilnCMS.CMS.Block do
  @moduledoc """
  An embedded content block (decision D3).

  Blocks are stored as a JSON tree on the parent content resource. Each block
  carries a `type` (the variant), free-form `content` (e.g. rich-text HTML/JSON),
  a flexible `data` map for type-specific attributes, and an `order` for layout.
  Nested/slice blocks are supported via `children`.
  """
  use Ash.Resource,
    data_layer: :embedded,
    embed_nil_values?: false

  actions do
    defaults [:read, :create, :update, :destroy]
    # `:id` is accepted so block ids stay stable across version restores
    # (and round-trips); it still defaults to a generated UUID when omitted.
    default_accept [:id, :type, :content, :data, :order, :children]
  end

  attributes do
    uuid_primary_key :id, writable?: true

    attribute :type, :atom do
      constraints one_of: [
                    :rich_text,
                    :heading,
                    :image,
                    :quote,
                    :embed,
                    :divider,
                    :columns,
                    :custom
                  ]

      allow_nil? false
      default :rich_text
      public? true
    end

    # Rich-text payload (TipTap JSON or rendered HTML) or a plain string value.
    attribute :content, :string, public?: true

    # Type-specific attributes: heading level, image media_item id, embed url, etc.
    attribute :data, :map, default: %{}, public?: true

    # Position within the parent's block list.
    attribute :order, :integer, default: 0, public?: true

    # Nested blocks for composable slices (Storyblok-style).
    attribute :children, {:array, :map}, default: [], public?: true
  end
end
