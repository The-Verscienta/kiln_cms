defmodule Kiln.Plugins.CompileEdges do
  @moduledoc false

  # A compile-time edge from `Kiln.Plugins` to every configured plugin module.
  #
  # `Kiln.Plugins` holds the plugin list (via `compile_env`), so it recompiles
  # when the *list* changes — but not when a listed plugin changes what it
  # contributes. The registries baked from it at compile time
  # (`KilnCMS.CMS.TypedBlocks`, `KilnCMS.CMS.FieldTypes`, every content
  # resource's block union) then kept the old `blocks/0`/`field_types/0`: a
  # block added to an installed plugin was in `KilnCMS.Blocks.registry/0` but
  # nested casts treated it as unknown until a `mix compile --force`.
  #
  # A remote call at compile time is a compile dependency (a bare `require` is
  # only an export dependency, which a changed function body never trips), so
  # expanding this in `Kiln.Plugins`'s body makes an edit to a plugin module
  # recompile `Kiln.Plugins` and, through it, those registries.
  #
  # Each field type is called by name too (#2680): `KilnCMS.CMS.FieldTypes`
  # bakes a type's `multiple?/0` answer, and a call on a module held in a
  # variable records no edge. An edit to a field type compiled in the same
  # project (the test fixture plugin, `projects/`) would otherwise leave the
  # list-capable types stale.
  defmacro call_configured do
    for plugin <- Application.get_env(:kiln_cms, :plugins, []) do
      field_types = for type <- plugin.field_types(), is_atom(type), do: type

      quote do
        _ = unquote(plugin).blocks()
        _ = unquote(plugin).field_types()
        unquote_splicing(for type <- field_types, do: quote(do: _ = unquote(type).name()))
      end
    end
  end

  @doc false
  # The compiled identity of every module the registries bake from: each
  # configured plugin and each block and field type it contributes, by its
  # beam's MD5. The input to `Kiln.Plugins.__mix_recompile__?/0`, which compares
  # it with the digest taken when `Kiln.Plugins` last compiled.
  #
  # The MD5 rather than only the `blocks/0`/`field_types/0` lists: a field
  # added to a dependency plugin's block leaves the lists alone but changes
  # what the core derives from the block at compile time (its storage union
  # member, its GraphQL/JSON:API types). A module that no longer loads
  # (removed, renamed) hashes to a fresh reference, so the answer is
  # "recompile" and the compiler reports the real problem.
  @spec digest([module()]) :: integer() | reference()
  def digest(plugins) do
    :erlang.phash2(
      for plugin <- plugins,
          module <- [plugin | plugin.blocks() ++ plugin.field_types()],
          do: {module, md5(module)}
    )
  rescue
    _ in [UndefinedFunctionError, ArgumentError] -> make_ref()
  end

  # The MD5 of the module's .beam on disk, which is what Mix just wrote, and
  # which is the same value `module_info(:md5)` reports for the code the file
  # holds. Read from disk rather than from the loaded module because
  # `mix test --cover` replaces loaded modules with cover-compiled ones, whose
  # MD5 differs; that would make the digest look stale in every covered run.
  # A module with no file (compiled in memory) falls back to the loaded MD5.
  defp md5(module) do
    with path when is_list(path) and path != [] <- beam_path(module),
         {:ok, {^module, md5}} <- :beam_lib.md5(path) do
      md5
    else
      _ -> module.module_info(:md5)
    end
  end

  defp beam_path(module) do
    case :code.which(module) do
      :cover_compiled -> :code.where_is_file(~c"#{module}.beam")
      path -> path
    end
  end
end
