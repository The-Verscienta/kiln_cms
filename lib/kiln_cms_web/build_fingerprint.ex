defmodule KilnCMSWeb.BuildFingerprint do
  @moduledoc """
  A short digest of the code this node runs, for validators over responses
  rendered live on each request (#2463).

  The built-in site renders published HTML on every request, so its `ETag`
  must name everything that decides the markup. The record and the site's
  settings are named already (`KilnCMSWeb.ContentController`); the code is
  not, so a deploy that changes a template or a block renderer would keep
  answering `304` to a browser or CDN holding the old page. This names it.

  The digest covers:

    * the name and version of every application those modules' applications
      depend on, transitively;
    * the code of every `:kiln_cms` module, and of every loaded application
      that depends on `:kiln_cms` or `:kiln_plugin` (an overlay or a plugin),
      by each module's MD5, which ignores compile time and paths;
    * the asset digest manifest (`priv/static/cache_manifest.json`), when
      `mix phx.digest` wrote one.

  So two nodes running one release image agree, and a rebuild of unchanged
  source keeps the value. Runtime configuration is not covered: a markup
  change that only an environment variable makes does not move it.

  Computed once per VM and kept in `:persistent_term`. `KilnCMS.Application`
  starts `warm/0` in a temporary task after the endpoint, so boot does not
  wait for it (reading ~2,000 beam files takes a few hundred milliseconds) and
  the first page usually finds it ready. A request that arrives before the
  task is done computes it under a node-local lock instead, so concurrent
  first requests compute it once and write it once (`:persistent_term.put/2`
  of a new value is cheap; replacing one triggers a global GC scan).
  """

  @key {__MODULE__, :fingerprint}
  # Apps whose dependents are Kiln code: an overlay depends on `:kiln_cms`, a
  # plugin on the SDK.
  @kiln_apps [:kiln_cms, :kiln_plugin]

  @doc "The fingerprint of the running build: 16 lowercase hex characters."
  @spec fingerprint() :: String.t()
  def fingerprint do
    case :persistent_term.get(@key, nil) do
      nil -> compute_once()
      value -> value
    end
  end

  @doc """
  Compute the fingerprint now, if nothing has yet. For the boot-time task in
  `KilnCMS.Application`; always returns `:ok`.
  """
  @spec warm() :: :ok
  def warm do
    _ = fingerprint()
    :ok
  end

  # `:global.trans/3` on this node alone is a plain mutex keyed on the
  # resource: a second caller waits, then finds the value the first one put.
  defp compute_once do
    :global.trans(
      {@key, self()},
      fn ->
        case :persistent_term.get(@key, nil) do
          nil ->
            value = compute()
            :persistent_term.put(@key, value)
            value

          value ->
            value
        end
      end,
      [node()]
    )
  end

  @doc """
  The fingerprint of `apps` (`{app, vsn}` pairs), `modules` (`{module, md5}`
  pairs) and `manifest` (the asset manifest's bytes, or `nil`). Pure, and
  independent of the order either list arrives in.
  """
  @spec compute([{atom(), term()}], [{module(), binary()}], binary() | nil) :: String.t()
  def compute(apps, modules, manifest) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary({Enum.sort(apps), Enum.sort(modules), manifest}))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc false
  # Test seam: pin the fingerprint, as a new build would move it.
  @spec put(String.t()) :: :ok
  def put(value) when is_binary(value), do: :persistent_term.put(@key, value)

  @doc false
  # Test seam: forget the pinned value, so the next call computes it again.
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@key)
    :ok
  end

  @doc """
  The applications whose modules the fingerprint covers: `:kiln_cms` and
  every loaded application that depends on it or on `:kiln_plugin`. In a
  release the boot script loads every application in it before anything
  runs, so an overlay or a plugin is always among them.
  """
  @spec covered_apps() :: [atom()]
  def covered_apps do
    dependents =
      for {app, _description, _vsn} <- Application.loaded_applications(),
          deps = Application.spec(app, :applications) || [],
          Enum.any?(@kiln_apps, &(&1 in deps)),
          do: app

    Enum.uniq([:kiln_cms | dependents])
  end

  defp compute do
    covered = covered_apps()

    apps =
      for app <- closure(covered, %{}),
          vsn = Application.spec(app, :vsn),
          do: {app, vsn}

    modules =
      for app <- covered,
          module <- Application.spec(app, :modules) || [],
          md5 = module_md5(module),
          do: {module, md5}

    compute(apps, modules, manifest())
  end

  # The covered apps and everything they depend on, from their `.app` specs:
  # a set fixed by the release, not by what happens to be loaded when the
  # first page is served (a later `Application.load/1` of something unrelated
  # would otherwise make two nodes disagree).
  # `seen` is a plain map, not a MapSet: Dialyzer rejects an opaque MapSet
  # threaded through a recursive private function.
  defp closure([], seen), do: Map.keys(seen)

  defp closure([app | rest], seen) do
    if Map.has_key?(seen, app) do
      closure(rest, seen)
    else
      deps =
        (Application.spec(app, :applications) || []) ++
          (Application.spec(app, :included_applications) || [])

      closure(deps ++ rest, Map.put(seen, app, true))
    end
  end

  # From the beam file when there is one, so dev and test don't load every
  # module to ask. A module with no file on disk is asked directly.
  defp module_md5(module) do
    with path when is_list(path) <- :code.which(module),
         {:ok, {^module, md5}} <- :beam_lib.md5(path) do
      md5
    else
      _ -> if Code.ensure_loaded?(module), do: module.module_info(:md5)
    end
  end

  # The app's own digest manifest under priv/static: a fixed path, never built
  # from request or user input.
  # sobelow_skip ["Traversal.FileModule"]
  defp manifest do
    path = Application.app_dir(:kiln_cms, "priv/static/cache_manifest.json")

    case File.read(path) do
      {:ok, bytes} -> bytes
      {:error, _} -> nil
    end
  end
end
