defmodule KilnCMS.CMS.Validations.CommentIsThreadRoot do
  @moduledoc """
  Resolving/unresolving is a property of a block's one thread, not any single
  comment (#404) — so `:resolve`/`:unresolve` only accept the thread's root
  (`thread_id: nil`). The editor UI only ever calls these on a root it already
  fetched; this is the resource-level guarantee that holds regardless of caller.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    if is_nil(changeset.data.thread_id) do
      :ok
    else
      {:error, field: :thread_id, message: "only a thread's first comment can be resolved"}
    end
  end
end
