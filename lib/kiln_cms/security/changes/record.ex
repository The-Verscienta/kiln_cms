defmodule KilnCMS.Security.Changes.Record do
  @moduledoc """
  Adds a security audit event (#2241) to an Ash action, so an emit site is one
  line: `change {KilnCMS.Security.Changes.Record, type: :passkey_added}`.

  Options:

    * `:type` - the event type (required). A function `(record, changeset ->
      atom | nil)` decides it from what the action did; `nil` writes no event
      (a role edit that left the role as it was).
    * `:mode` - `:in_transaction` (default; an `after_action` hook, so the
      event commits or rolls back with the change, for credential changes) or
      `:after_commit` (an `after_transaction` hook, best-effort, never fails
      the action).
    * `:user` - `(record, changeset -> User.t() | nil)`; who acted. Default:
      the changeset's actor when it is a user.
    * `:target` - `(record, changeset -> {target_type, target_id} | nil)`.
    * `:metadata` - `(record, changeset -> map)`; sanitised by the event's
      allowlist.
    * `:when` - `(record, changeset -> boolean)`; the event is written only
      when it returns true (default: always). For an action that is an audit
      event only sometimes: a revoke of a key already revoked, or a write made
      by a person rather than the system.
    * `:tenant` - `(record, changeset -> org id | nil)`; overrides the org the
      event belongs to (below), for a record whose org is not its tenant, such as
      a membership, which names its org in `organization_id`.

  The request context is read from the changeset context under
  `KilnCMS.Security.Recorder.context_key/0`, and the tenant from the changeset,
  else the context under `KilnCMS.Security.Recorder.tenant_key/0` (a global
  resource such as a user or passkey), else the record's `org_id`. No tenant, no
  event (`Recorder` documents why).
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.User
  alias KilnCMS.Security.Recorder

  @impl true
  def change(changeset, opts, _context) do
    _type = Keyword.fetch!(opts, :type)

    case Keyword.get(opts, :mode, :in_transaction) do
      :in_transaction ->
        Ash.Changeset.after_action(changeset, fn changeset, record ->
          record_in_transaction(opts, changeset, record)
        end)

      :after_commit ->
        Ash.Changeset.after_transaction(changeset, fn changeset, result ->
          record_after_commit(opts, changeset, result)
        end)
    end
  end

  defp record_in_transaction(opts, changeset, record) do
    case type(opts, changeset, record) do
      nil ->
        {:ok, record}

      type ->
        case Recorder.record(type, options(opts, changeset, record)) do
          {:error, error} -> {:error, error}
          _ok_or_skipped -> {:ok, record}
        end
    end
  end

  defp record_after_commit(opts, changeset, result) do
    with {:ok, record} <- result,
         type when not is_nil(type) <- type(opts, changeset, record) do
      Recorder.record_after_commit(type, options(opts, changeset, record))
    end

    result
  end

  # The event type, or nil for "write nothing".
  defp type(opts, changeset, record) do
    type =
      case Keyword.fetch!(opts, :type) do
        fun when is_function(fun, 2) -> fun.(record, changeset)
        type -> type
      end

    if type != nil and emit?(opts, changeset, record), do: type
  end

  defp emit?(opts, changeset, record) do
    case opts[:when] do
      nil -> true
      fun -> fun.(record, changeset) == true
    end
  end

  defp options(opts, changeset, record) do
    {target_type, target_id} = call(opts[:target], record, changeset) || {nil, nil}

    [
      tenant: call(opts[:tenant], record, changeset) || tenant(changeset, record),
      user: user(opts, changeset, record),
      target_type: target_type,
      target_id: target_id,
      metadata: call(opts[:metadata], record, changeset) || %{},
      request: changeset.context[Recorder.context_key()]
    ]
  end

  defp user(opts, changeset, record) do
    case opts[:user] do
      nil ->
        case changeset.context[:private][:actor] do
          %User{} = user -> user
          _other -> nil
        end

      fun ->
        fun.(record, changeset)
    end
  end

  defp call(nil, _record, _changeset), do: nil
  defp call(fun, record, changeset), do: fun.(record, changeset)

  defp tenant(changeset, record) do
    case {changeset.tenant, changeset.context[Recorder.tenant_key()]} do
      {tenant, _context} when is_binary(tenant) -> tenant
      {_none, tenant} when is_binary(tenant) -> tenant
      _other -> Map.get(record, :org_id)
    end
  end
end
