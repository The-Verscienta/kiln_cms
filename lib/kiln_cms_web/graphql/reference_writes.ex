defmodule KilnCMSWeb.Graphql.ReferenceWrites do
  @moduledoc """
  Connect / disconnect / reorder writes on `:reference` custom fields
  (relationships plan, R8): `add<Type>References`, `remove<Type>References`
  and `move<Type>Reference` on every content type, `Entry` included.

  Each is a thin layer over the record's `:update`, through
  `KilnCMS.CMS.ReferenceEdits` (D23): the same policies and `:read_write` API
  key scope as `update<Type>`, the same `expectedLockVersion`, versioning,
  webhooks and re-fire. `Idempotency-Key` applies as to every `/gql` POST
  (`KilnCMSWeb.Plugs.Idempotency`).

  The result has `update<Type>`'s shape, `{ result, errors }`, with `result`
  typed as the content object, so a client handles both the same way. This
  module holds the input objects and the resolvers;
  `KilnCMSWeb.Graphql.ReferenceWrites.Notation` emits the per-type fields.
  """
  use Absinthe.Schema.Notation

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.ReferenceEdits

  @desc """
  A record to connect through a `:reference` field.
  """
  input_object :reference_target_input do
    @desc "The target record's id."
    field :id, non_null(:id)

    @desc """
    The target's content type (`page`, `post`, a dynamic type's name). Needed
    only when the field links to more than one type.
    """
    field :type, :string

    @desc """
    Values for the field's link fields on this connection, as a JSON object
    keyed by link field name (a JSON-encoded string, like `customFields` on
    `update<Type>`). Validated like the field's other values; a key left out
    keeps what the connection stored.
    """
    field :link, :json_string
  end

  @desc """
  Where connected records go, as in Hygraph's `connect`: give exactly one of
  `start`, `end`, `before` or `after`. `before` / `after` name a record already
  connected through the field. Omitted, records go at the end.
  """
  input_object :reference_position_input do
    field :start, :boolean
    field :end, :boolean
    field :before, :id
    field :after, :id
  end

  @doc false
  # Root resolver for `add<Type>References`.
  def add(resource, %{targets: targets} = args, resolution) do
    outcome =
      with {:ok, targets} <- targets(targets),
           {:ok, position} <- position(args[:position]),
           do: write(resource, {:add, targets, position}, args, resolution)

    result(outcome, resource, resolution)
  end

  @doc false
  # Root resolver for `remove<Type>References`.
  def remove(resource, %{targets: targets} = args, resolution) do
    resource
    |> write({:remove, targets}, args, resolution)
    |> result(resource, resolution)
  end

  @doc false
  # Root resolver for `move<Type>Reference`.
  def move(resource, %{target: target, position: position} = args, resolution) do
    outcome =
      with {:ok, position} <- position(position),
           do: write(resource, {:move, target, position}, args, resolution)

    result(outcome, resource, resolution)
  end

  @doc false
  # `result` on `<Type>ReferencesResult`: the updated record, loaded with the
  # fields the document selected, as the reader.
  def load_result(_resource, %{result: nil}, _args, _resolution), do: {:ok, nil}

  def load_result(resource, %{result: record}, _args, resolution),
    do: AshGraphql.load_fields(record, resource, resolution)

  defp write(resource, edit, %{id: id, field: field} = args, %{context: context}) do
    opts = [actor: context[:actor], tenant: context[:tenant]]

    with {:ok, record} <- fetch(resource, id, opts) do
      ReferenceEdits.run(
        record,
        field,
        edit,
        Keyword.put(opts, :expected_lock_version, args[:expected_lock_version])
      )
    end
  end

  # Read as the caller, as `update<Type>` does before it writes: a record the
  # caller can't read is not found.
  defp fetch(resource, id, opts) do
    domain = Ash.Resource.Info.domain(resource)
    fun = String.to_existing_atom("get_#{ContentTypes.type_atom(resource)}")
    Kernel.apply(domain, fun, [id, opts])
  end

  defp result({:ok, record}, _resource, _resolution), do: {:ok, %{result: record, errors: []}}

  defp result({:error, error}, resource, %{context: context}) do
    domain = Ash.Resource.Info.domain(resource)

    {:ok,
     %{
       result: nil,
       errors: AshGraphql.Errors.to_errors(List.wrap(error), context, domain, resource, :update)
     }}
  end

  defp targets(targets) do
    if Enum.all?(targets, &(is_nil(&1[:link]) or is_map(&1[:link]))),
      do: {:ok, Enum.map(targets, &%{id: &1.id, type: &1[:type], link: &1[:link]})},
      else: {:error, invalid(:targets, "a target's link must be a JSON object")}
  end

  defp position(nil), do: {:ok, :end}

  defp position(position) do
    case Enum.reject(position, fn {_key, value} -> value in [nil, false] end) do
      [{:start, true}] -> {:ok, :start}
      [{:end, true}] -> {:ok, :end}
      [{:before, id}] -> {:ok, {:before, id}}
      [{:after, id}] -> {:ok, {:after, id}}
      _other -> {:error, position_error()}
    end
  end

  defp position_error, do: invalid(:position, "give exactly one of start, end, before or after")

  defp invalid(field, message),
    do: Ash.Error.Changes.InvalidArgument.exception(field: field, message: message)
end
