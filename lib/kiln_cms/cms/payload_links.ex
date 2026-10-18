defmodule KilnCMS.CMS.PayloadLinks do
  @moduledoc """
  Payload links over the API (relationships plan, R8): a `ContentLink` with
  no `field` — a curated link between two records with a `kind`, a `label`
  and free `metadata` — created, changed and deleted through
  `POST/PATCH/DELETE /api/json/content-links`.

  A link belongs to its **source**: writing one is authorized as an update of
  the source record (`Checks.SourceUpdatable`), so an editor who may not edit
  a page may not hang links off it either, and a read-only API key may not
  write one at all. The target must be a record the writer can read, in the
  same site.

  Reference edges (`kind: :reference`) are not payload links. They are a copy
  of a `:reference` custom field's value, kept by
  `KilnCMS.CMS.ContentLinks`, and are written by writing that field
  (`add<Type>References`, or a `PATCH` of `custom_fields`). These routes
  refuse to create, change or delete one.

  A payload link is not part of its source's stored document: it does not
  bump the source's `lock_version`, write a version, or fire its webhook.
  Fired artifacts do not read links, so none goes stale.
  """

  require Ash.Query

  alias KilnCMS.CMS.ContentTypes

  @doc """
  The content record `id` names in `tenant`, of any type, read without
  authorization (the caller decides what the actor may do with it), or
  `:error` when there is none.
  """
  @spec locate(Ash.UUID.t() | nil, term()) :: {:ok, Ash.Resource.Record.t()} | :error
  def locate(nil, _tenant), do: :error

  def locate(id, tenant) do
    ContentTypes.blocks_resources()
    |> Enum.map(&elem(&1, 1))
    |> Enum.uniq()
    |> Enum.find_value(:error, fn resource ->
      resource
      |> Ash.Query.filter(id == ^id)
      # authorize?: false — a lookup of which record an id names; the
      # callers authorize what the actor may do with it.
      |> Ash.read_one(tenant: tenant, authorize?: false)
      |> case do
        {:ok, %{} = record} -> {:ok, record}
        _none -> nil
      end
    end)
  end
end
