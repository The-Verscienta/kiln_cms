defmodule KilnCMSWeb.GraphqlDefaultOffset do
  @moduledoc """
  Defaults `offset` to `0` on offset-paginated GraphQL queries (#1883).

  An omitted `offset` means the first page, so `hasNextPage` must still be a
  boolean. Without this middleware it is not. The `:published` reads support
  both offset and keyset paging, and `config :ash, default_page_type: :keyset`
  makes Ash answer a page request with no `offset` as a keyset page.
  AshGraphql (1.12.0) renders a keyset page on an offset query's `PageOf*`
  type without `hasNextPage`, `hasPreviousPage`, `pageNumber` or `lastPage`.
  The non-null `hasNextPage` then nulls the whole field.

  Passing `offset: 0` explicitly asks Ash for an offset page, so this
  middleware fills it in before the AshGraphql resolver runs. It is installed
  as the schema's `action_middleware`, so it runs on every root query,
  mutation and generic action AshGraphql generates, including a project
  overlay's. It acts only on a field that returns an offset page (a
  `page_of_*` type) and declares an `offset` argument, so an action argument
  that merely happens to be called `offset` is left alone.

  Not covered: a relationship paginated with `paginate_relationship_with
  ... :offset`. AshGraphql reads a nested page's arguments while resolving the
  parent, so no middleware on the child field runs in time, and such a field
  has the same bug. Kiln paginates no relationships today.

  Remove this module once AshGraphql defaults `offset` itself. The fix there
  is one line in `AshGraphql.Graphql.Resolver.validate_offset_opts/3`:
  `Keyword.put_new(opts, :offset, 0)`. Upstream:
  https://github.com/ash-project/ash_graphql/issues/480
  """
  @behaviour Absinthe.Middleware

  @impl true
  def call(%Absinthe.Resolution{state: :unresolved} = resolution, _config) do
    if offset_paginated?(resolution) and is_nil(resolution.arguments[:offset]) do
      %{resolution | arguments: Map.put(resolution.arguments, :offset, 0)}
    else
      resolution
    end
  end

  def call(resolution, _config), do: resolution

  defp offset_paginated?(%{definition: %{schema_node: %{args: args, type: type}}})
       when is_map(args) do
    Map.has_key?(args, :offset) and offset_page_type?(Absinthe.Type.unwrap(type))
  end

  defp offset_paginated?(_resolution), do: false

  defp offset_page_type?(identifier) when is_atom(identifier),
    do: String.starts_with?(Atom.to_string(identifier), "page_of_")

  defp offset_page_type?(_type), do: false
end
