defmodule KilnCMS.CMS.ContentTypes do
  @moduledoc """
  Registry of content types for the admin UI.

  Content types are **discovered automatically**: any resource built on
  `KilnCMS.CMS.Content` (and therefore registered on the `KilnCMS.CMS` domain)
  is picked up here, so a type generated with `mix kiln.gen.content` shows up in
  the editor with no extra wiring.

  It also centralizes dispatch to the per-type `CMS.*` code interfaces (whose
  names follow the project's convention), so the LiveViews can stay generic
  instead of hard-coding `:page`/`:post`.
  """
  alias KilnCMS.CMS

  @type t :: %{
          type: atom(),
          resource: module(),
          label: String.t(),
          plural: String.t(),
          excerpt?: boolean()
        }

  @doc "All content types, sorted by label."
  @spec all() :: [t()]
  def all do
    CMS
    |> Ash.Domain.Info.resources()
    |> Enum.filter(&function_exported?(&1, :__kiln_content_type__, 0))
    |> Enum.map(&describe/1)
    |> Enum.sort_by(& &1.label)
  end

  defp describe(resource) do
    type = resource.__kiln_content_type__()

    %{
      type: type,
      resource: resource,
      label: resource |> Module.split() |> List.last(),
      plural: "#{type}s",
      excerpt?: not is_nil(Ash.Resource.Info.attribute(resource, :excerpt))
    }
  end

  @doc "Look up a content type by its atom or string type. Returns nil if unknown."
  @spec get(atom() | String.t() | nil) :: t() | nil
  def get(nil), do: nil
  def get(type) when is_atom(type), do: Enum.find(all(), &(&1.type == type))

  def get(type) when is_binary(type) do
    case safe_existing_atom(type) do
      nil -> nil
      atom -> get(atom)
    end
  end

  @doc "Like `get/1` but raises for an unknown type."
  @spec get!(atom() | String.t()) :: t()
  def get!(type) do
    get(type) || raise ArgumentError, "unknown content type: #{inspect(type)}"
  end

  @doc "Whether `type` is a known content type."
  @spec type?(atom() | String.t()) :: boolean()
  def type?(type), do: not is_nil(get(type))

  # --- dispatch to the per-type CMS.* code interfaces ------------------------
  #
  # Each helper accepts a type atom/string (or a `t()` map) and calls the
  # convention-named domain code interface, e.g. `CMS.list_pages!/1`.

  def list!(type, opts \\ []), do: call("list_#{plural(type)}!", [opts])

  def get_record!(type, id, opts \\ []), do: call("get_#{atom(type)}!", [id, opts])

  def create!(type, attrs, opts \\ []), do: call("create_#{atom(type)}!", [attrs, opts])

  def list_versions!(type, opts \\ []), do: call("list_#{atom(type)}_versions!", [opts])

  def restore_version(type, record, version_id, opts \\ []) do
    call("restore_#{atom(type)}_version", [record, %{version_id: version_id}, opts])
  end

  @doc "Run a workflow transition: publish, unpublish, submit, or archive."
  def transition(type, verb, record, opts \\ []) do
    call(transition_fun(atom(type), verb), [record, %{}, opts])
  end

  def list_trashed!(type, opts \\ []), do: call("list_trashed_#{plural(type)}!", [opts])

  def restore(type, record, opts \\ []), do: call("restore_#{atom(type)}", [record, %{}, opts])

  def purge(type, record, opts \\ []), do: call("purge_#{atom(type)}", [record, opts])

  def destroy(type, record, opts \\ []), do: call("destroy_#{atom(type)}", [record, opts])

  # --- internals -------------------------------------------------------------

  # Resolve a convention-built interface name to the existing function on the
  # domain and call it. `to_existing_atom` (not interpolation) keeps this safe
  # for request-derived types — the code interfaces are defined at compile time.
  defp call(fun_name, args), do: apply(CMS, String.to_existing_atom(fun_name), args)

  defp transition_fun(type, "publish"), do: "publish_#{type}"
  defp transition_fun(type, "unpublish"), do: "unpublish_#{type}"
  defp transition_fun(type, "submit"), do: "submit_#{type}_for_review"
  defp transition_fun(type, "archive"), do: "archive_#{type}"

  defp atom(%{type: type}), do: type
  defp atom(type) when is_atom(type), do: type
  defp atom(type) when is_binary(type), do: get!(type).type

  defp plural(%{plural: plural}), do: plural
  defp plural(type), do: get!(type).plural

  defp safe_existing_atom(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> nil
  end
end
