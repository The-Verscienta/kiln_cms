defmodule KilnCMS.CMS.Validations.PathAliasValid do
  @moduledoc """
  Validates a multi-segment `path_alias` (#485): slug-shaped lowercase
  segments (`/acupuncture/needle/size/14mm`), a first segment the router
  doesn't own (an `/editor/...` alias could never be served), and no collision
  with another record's alias in the same locale (advisory cross-table check —
  the alias lives on every content table, so this can't be a DB constraint;
  real content always beats an alias at delivery regardless).
  """
  use Ash.Resource.Validation

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Slugs

  @format ~r|\A(/[a-z0-9-]+)+\z|

  @impl true
  def validate(changeset, _opts, _context) do
    alias_path = Ash.Changeset.get_attribute(changeset, :path_alias)

    if Ash.Changeset.changing_attribute?(changeset, :path_alias) and is_binary(alias_path) do
      check(changeset, alias_path)
    else
      :ok
    end
  end

  defp check(changeset, alias_path) do
    cond do
      not Regex.match?(@format, alias_path) ->
        {:error,
         field: :path_alias,
         message: "must look like /lowercase/segments-like-this (no trailing slash)"}

      reserved_first_segment?(alias_path) ->
        {:error, field: :path_alias, message: "starts with a URL segment the system already owns"}

      alias_taken?(changeset, alias_path) ->
        {:error, field: :path_alias, message: "is already used by another record"}

      true ->
        :ok
    end
  end

  defp reserved_first_segment?(alias_path) do
    [first | _rest] = String.split(alias_path, "/", trim: true)
    first in ContentTypes.reserved_path_segments()
  end

  defp alias_taken?(changeset, alias_path) do
    Slugs.alias_taken?(
      alias_path,
      Ash.Changeset.get_attribute(changeset, :locale),
      changeset.tenant,
      Map.get(changeset.data, :id)
    )
  end
end
