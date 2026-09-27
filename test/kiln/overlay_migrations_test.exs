defmodule Kiln.OverlayMigrationsTest do
  @moduledoc """
  An overlay's migrations are copied into the core's `priv/repo/migrations` at
  image-build time (the Dockerfile's `PROJECT=` step, and `overlay_drift` in
  CI), so they share one directory with the core's. Ecto refuses to run a
  directory in which two migrations share a name or a version — **every**
  migration, not just the pair — and two files defining the same module
  redefine it.

  `overlay_drift` only runs codegen, never the migrations, so this went
  unseen: from 0.7.0 on, the in-tree example's
  `20260815142530_add_content_lifecycles.exs` collided with the core's
  `20260815142625_add_content_lifecycles.exs` (same name, same module), and an
  example-activated build could not migrate at all. The upgrade rehearsal
  (#1540) was the first thing to run them together.
  """
  use ExUnit.Case, async: true

  @core "priv/repo/migrations"

  defp migrations(dir) do
    for path <- Path.wildcard(Path.join(dir, "*.exs")) do
      [version, name] = path |> Path.basename(".exs") |> String.split("_", parts: 2)
      [_, module] = Regex.run(~r/^defmodule\s+([\w.]+)/m, File.read!(path))
      %{path: path, version: version, name: name, module: module}
    end
  end

  for overlay <- Path.wildcard("projects/*/priv/repo/migrations") do
    @overlay overlay

    test "#{overlay} merges into the core's migrations without a collision" do
      merged = migrations(@core) ++ migrations(@overlay)

      for key <- [:version, :name, :module] do
        clashes =
          merged
          |> Enum.group_by(&Map.fetch!(&1, key))
          |> Enum.filter(fn {_value, files} -> length(files) > 1 end)
          |> Enum.map(fn {value, files} ->
            "#{value}: #{Enum.map_join(files, ", ", & &1.path)}"
          end)

        assert clashes == [], """
        Two migrations share a #{key} once #{@overlay} is merged into #{@core}:

            #{Enum.join(clashes, "\n    ")}

        Ecto will refuse to migrate that directory. Rename the overlay's file
        (and its module) — Ecto records migrations by version, so renaming one
        that has already run is safe; keep its timestamp.
        """
      end
    end
  end
end
