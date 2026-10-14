# The overlay's dependency hook (#1967): how a site adds a plugin that ships as
# a Mix dependency without editing the core's mix.exs.
#
# An overlay already plugs its configuration in through a git-ignored
# `config/project.exs`. This is the same for dependencies: a git-ignored
# `config/project_deps.exs`, shipped by the overlay, evaluating to a list of
# dependency tuples that `mix.exs` appends to `deps/0`:
#
#     [
#       {:kiln_ratings, "~> 1.0"},
#       {:kiln_cloudflare_images, github: "The-Verscienta/kiln_cloudflare_images", tag: "v0.1.0"}
#     ]
#
# While the file exists, Mix locks into `config/project.lock` (also
# git-ignored) instead of `mix.lock`, so the core's committed lock never
# changes and `mix kiln.update` never sees a patched pin. The project lock
# starts as a copy of `mix.lock`, so the core's own dependencies stay at the
# versions the release was tested with; `mix kiln.update` re-seeds it after
# moving the pin. A clean core checkout has neither file, and nothing changes.
#
# A standalone `.exs` like `ml_flag.exs` next to it, for the same reason:
# mix.exs is evaluated before `lib/` compiles, so no project module exists yet.
defmodule KilnCMS.Config.ProjectDeps do
  @moduledoc false

  @deps_file "config/project_deps.exs"
  @lock_file "config/project.lock"
  @core_lock "mix.lock"

  @doc "Whether the overlay ships a dependency list."
  def present?(root), do: File.exists?(Path.join(root, @deps_file))

  @doc """
  The overlay's dependencies, validated. `[]` without the file.

  An overlay dependency may never override a core one: `override: true` would
  silently replace a version the release was tested with. A real conflict
  should fail where Mix reports it, as a diverged dependency.
  """
  def deps(root) do
    if present?(root), do: root |> Path.join(@deps_file) |> load!(), else: []
  end

  @doc "The app names the overlay adds, for `mix kiln.plugins.doctor`."
  def apps(root), do: Enum.map(deps(root), &elem(&1, 0))

  @doc """
  The `lockfile:` for mix.exs: `config/project.lock` while the overlay has
  dependencies, seeded from `mix.lock` the first time; `mix.lock` otherwise.
  """
  def lockfile(root) do
    if present?(root) do
      seed(root)
      @lock_file
    else
      @core_lock
    end
  end

  # Only when it is missing: once it exists it is the overlay's record, and
  # `mix kiln.update` is what moves its core entries.
  defp seed(root) do
    lock = Path.join(root, @lock_file)
    core = Path.join(root, @core_lock)

    if not File.exists?(lock) and File.exists?(core), do: File.cp!(core, lock)
  end

  @doc false
  # Public so the validation can be tested against any term.
  def validate!(deps, file) do
    unless is_list(deps) do
      Mix.raise("#{file} must evaluate to a list of dependencies, got: #{inspect(deps)}")
    end

    Enum.each(deps, &validate_dep!(&1, file))
    deps
  end

  defp load!(file) do
    {deps, _binding} = Code.eval_file(file)
    validate!(deps, file)
  end

  defp validate_dep!(dep, file)
       when is_tuple(dep) and tuple_size(dep) in 2..3 and is_atom(elem(dep, 0)) do
    opts = dep |> Tuple.to_list() |> List.last()

    if is_list(opts) and Keyword.keyword?(opts) and opts[:override] do
      Mix.raise("""
      #{file}: #{inspect(elem(dep, 0))} sets `override: true`.

      An overlay dependency may not override a core dependency: it would
      silently replace a version this release was tested with. Remove the
      option; if Mix then reports a diverged dependency, use a version of the
      plugin built for this core.
      """)
    end
  end

  defp validate_dep!(dep, file) do
    Mix.raise(
      "#{file}: #{inspect(dep)} is not a dependency. " <>
        ~s(Write it the way mix.exs does: {:app, "~> 1.0"} or {:app, path: "..."}.)
    )
  end
end
