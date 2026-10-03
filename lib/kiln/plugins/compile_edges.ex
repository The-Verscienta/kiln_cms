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
  defmacro call_configured do
    for plugin <- Application.get_env(:kiln_cms, :plugins, []) do
      quote do
        _ = unquote(plugin).blocks()
        _ = unquote(plugin).field_types()
      end
    end
  end
end
