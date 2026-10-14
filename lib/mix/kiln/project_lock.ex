defmodule Mix.Kiln.ProjectLock do
  @moduledoc false
  # The overlay's lockfile, `config/project.lock` (#1967), as `mix kiln.update`
  # and `mix kiln.plugins.doctor` see it.
  #
  # While an overlay ships `config/project_deps.exs`, Mix locks into
  # `config/project.lock` instead of `mix.lock` (see
  # `config/project_deps_hook.exs`, which mix.exs requires). That lock holds two
  # kinds of entry: the core's, which must stay what this release's `mix.lock`
  # pins, and the overlay's own. Every app `mix.lock` names is core-owned;
  # anything else belongs to the overlay.
  #
  # Read and written here rather than through `Mix.Dep.Lock`, which is Mix's
  # private API and writes only the running project's lockfile.

  @deps_file "config/project_deps.exs"
  @lock_file "config/project.lock"
  @core_lock "mix.lock"

  @doc "Whether the checkout at `root` has an overlay dependency list."
  @spec present?(Path.t()) :: boolean()
  def present?(root), do: File.exists?(Path.join(root, @deps_file))

  @doc "The overlay lock's path under `root`."
  @spec lock_path(Path.t()) :: Path.t()
  def lock_path(root), do: Path.join(root, @lock_file)

  @doc "The core lock's path under `root`."
  @spec core_lock_path(Path.t()) :: Path.t()
  def core_lock_path(root), do: Path.join(root, @core_lock)

  @doc """
  A lockfile as a map of app name (string) to lock entry; `%{}` when absent.

  Parsed as literal data, never evaluated: a lock is a map of tuples, lists,
  strings and atoms, and anything else in one is refused rather than run.
  """
  @spec read(Path.t()) :: %{String.t() => tuple()}
  # sobelow_skip ["Traversal.FileModule"]
  # Every caller passes a fixed path under the checkout (`lock_path/1`,
  # `core_lock_path/1`); nothing user-supplied reaches it.
  def read(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> Code.string_to_quoted!(file: path, emit_warnings: false)
        |> literal!(path)
        |> Map.new(fn {app, entry} -> {to_string(app), entry} end)

      {:error, :enoent} ->
        %{}
    end
  end

  defp literal!({:%{}, _meta, pairs}, path),
    do: Map.new(pairs, fn {key, value} -> {literal!(key, path), literal!(value, path)} end)

  defp literal!({:{}, _meta, elements}, path),
    do: elements |> Enum.map(&literal!(&1, path)) |> List.to_tuple()

  defp literal!({left, right}, path), do: {literal!(left, path), literal!(right, path)}
  defp literal!(list, path) when is_list(list), do: Enum.map(list, &literal!(&1, path))

  defp literal!(value, _path)
       when is_binary(value) or is_atom(value) or is_number(value),
       do: value

  defp literal!(other, path),
    do: Mix.raise("#{path} is not a lockfile: unexpected #{Macro.to_string(other)}")

  @doc "Writes a lock in the layout `mix deps.get` writes, so a later run leaves it unchanged."
  @spec write!(Path.t(), map()) :: :ok
  # sobelow_skip ["Traversal.FileModule"]
  # Fixed paths only, as in `read/1`.
  def write!(path, lock) do
    lines =
      for {app, entry} <- Enum.sort(lock), entry != nil do
        ~s(  "#{app}": #{inspect(entry, limit: :infinity)},\n)
      end

    File.write!(path, ["%{\n", lines, "}\n"])
  end

  @doc """
  The overlay lock after the core moved: every app the core lock names takes
  the core's entry, and the overlay-only entries carry over.
  """
  @spec reseed(map(), map()) :: map()
  def reseed(project_lock, core_lock), do: Map.merge(project_lock, core_lock)

  @doc """
  Core-owned apps whose entry in the overlay lock differs from the core lock's,
  as `{app, project_entry, core_entry}`. Empty when they agree.
  """
  @spec drift(map(), map()) :: [{String.t(), tuple(), tuple()}]
  def drift(project_lock, core_lock) do
    for {app, core_entry} <- Enum.sort(core_lock),
        project_entry = Map.get(project_lock, app),
        project_entry != nil and project_entry != core_entry,
        do: {app, project_entry, core_entry}
  end
end
