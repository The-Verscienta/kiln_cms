defmodule KilnCMS.Cache.FillGuardSourceTest do
  @moduledoc """
  Every write to a fill-guarded cache goes through `KilnCMS.Cache.FillGuard`
  (#2972).

  The guard only works if nothing else writes the key: one plain
  `Cachex.put/3` in a fill, or one plain `Cachex.del/2` in a bust, reopens the
  window where a fill that read before a write's commit stores the old value
  after that write's bust. So this scans `lib/` for a call into `Cachex` that
  is not a read, naming a guarded instance:

    * by its atom (`:kiln_cms_ip_blocklist_cache`);
    * through a module attribute bound to that atom (`@cache`), in the module
      that binds it;
    * through `IpBlocklist.cache_name()` or `Hosts.cache_name()`, however the
      module is aliased, and, inside those two modules, through a local
      `cache_name()` or `__MODULE__.cache_name()`;
    * as an argument or as the left side of a pipe.

  `KilnCMS.Cache.FillGuard` itself is the one exemption. Not seen: an instance
  name passed through a variable (`KilnCMS.Cache.ClusterBust.broadcast_in/2`
  takes one, which is why it calls `FillGuard.bust/2`, and
  `KilnCMS.Cache.HostsTest` and `KilnCMS.Security.IpBlocklistTest` pin it by
  behavior).
  """
  use ExUnit.Case, async: true

  @guarded [
    KilnCMS.Security.IpBlocklist.cache_name(),
    KilnCMS.Cache.Hosts.cache_name()
  ]

  @guarded_modules [:IpBlocklist, :Hosts]

  # The modules whose own `cache_name/0` names a guarded instance.
  @owners [[:KilnCMS, :Security, :IpBlocklist], [:KilnCMS, :Cache, :Hosts]]

  @exempt ["lib/kiln_cms/cache/fill_guard.ex"]

  # Cachex calls that only read. Anything else on a guarded instance is a
  # finding, so a write Cachex adds later is caught too.
  @reads ~w(get get! ttl ttl! exists? exists! size size! keys keys! stream stream!
            inspect inspect! stats stats! empty? empty!)a

  test "lib/ writes the fill-guarded caches only through FillGuard" do
    paths = Path.wildcard("lib/**/*.ex")
    assert paths != [], "no lib/**/*.ex found: is the test running from the project root?"

    findings =
      for path <- paths, path not in @exempt, finding <- scan_file(path), do: finding

    assert findings == [],
           "write to a fill-guarded cache outside KilnCMS.Cache.FillGuard " <>
             "(use FillGuard.put/5, bust/2 or clear/1):\n  " <> Enum.join(findings, "\n  ")
  end

  test "the scan resolves the attribute each guarded module names its cache by" do
    for path <- ["lib/kiln_cms/security/ip_blocklist.ex", "lib/kiln_cms/cache/hosts.ex"] do
      ast = path |> File.read!() |> Code.string_to_quoted!()
      assert MapSet.member?(guarded_attributes(ast), :cache), "#{path}: no @cache resolved"
    end
  end

  describe "the scan itself" do
    test "flags a raw write by attribute, atom, cache_name/0 and pipe" do
      source = """
      defmodule Stray do
        alias KilnCMS.Security.IpBlocklist
        @cache :kiln_cms_ip_blocklist_cache
        def a(k), do: Cachex.del(@cache, k)
        def b(k), do: Cachex.put(:kiln_cms_host_cache, k, 1)
        def c, do: Cachex.clear(IpBlocklist.cache_name())
        def d(k), do: @cache |> Cachex.put(k, 1, expire: 10)
        def e, do: Cachex.clear!(KilnCMS.Cache.Hosts.cache_name())
      end
      """

      assert [
               "stray.ex:4: Cachex.del",
               "stray.ex:5: Cachex.put",
               "stray.ex:6: Cachex.clear",
               "stray.ex:7: Cachex.put",
               "stray.ex:8: Cachex.clear!"
             ] = scan_source("stray.ex", source)
    end

    test "leaves reads, other caches and FillGuard calls alone" do
      source = """
      defmodule Fine do
        @cache :kiln_cms_ip_blocklist_cache
        @other :some_other_cache
        def a(k), do: Cachex.get(@cache, k)
        def b(k), do: Cachex.put(@other, k, 1)
        def c(k), do: KilnCMS.Cache.FillGuard.bust(@cache, [k])
        def d(k), do: Cachex.ttl(:kiln_cms_host_cache, k)
      end
      """

      assert [] = scan_source("fine.ex", source)
    end

    test "inside a guarded module, flags a write through its own cache_name/0" do
      source = """
      defmodule KilnCMS.Cache.Hosts do
        def cache_name, do: :kiln_cms_host_cache
        def a(k), do: Cachex.del(cache_name(), k)
        def b(k), do: Cachex.put(__MODULE__.cache_name(), k, 1)
        def c(k), do: cache_name() |> Cachex.del(k)
        def d(k), do: Cachex.get(cache_name(), k)
      end
      """

      assert [
               "hosts.ex:3: Cachex.del",
               "hosts.ex:4: Cachex.put",
               "hosts.ex:5: Cachex.del"
             ] = scan_source("hosts.ex", source)
    end

    test "outside a guarded module, a local cache_name/0 is another cache's" do
      source = """
      defmodule KilnCMS.Firing.Cache do
        def cache_name, do: :kiln_cms_firing_cache
        def a(k), do: Cachex.del(cache_name(), k)
        def b(k), do: Cachex.put(__MODULE__.cache_name(), k, 1)
      end
      """

      assert [] = scan_source("firing_cache.ex", source)
    end
  end

  defp scan_file(path), do: scan_source(path, File.read!(path))

  defp scan_source(path, source) do
    ast = Code.string_to_quoted!(source, columns: false)
    ctx = %{attributes: guarded_attributes(ast), owner?: owner?(ast)}

    {_ast, findings} =
      Macro.prewalk(ast, [], fn
        # `subject |> Cachex.fun(...)`: the subject is the instance.
        {:|>, _, [subject, {{:., meta, [{:__aliases__, _, [:Cachex]}, fun]}, _, _args}]} = node,
        acc ->
          {node, finding(acc, path, meta, fun, subject, ctx)}

        {{:., meta, [{:__aliases__, _, [:Cachex]}, fun]}, _, [subject | _]} = node, acc ->
          {node, finding(acc, path, meta, fun, subject, ctx)}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(findings)
  end

  defp finding(acc, path, meta, fun, subject, ctx) do
    if fun not in @reads and guarded?(subject, ctx),
      do: ["#{path}:#{meta[:line]}: Cachex.#{fun}" | acc],
      else: acc
  end

  # The module attributes bound to a guarded instance's atom, by name.
  defp guarded_attributes(ast) do
    {_ast, names} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:@, _, [{name, _, [value]}]} = node, acc when is_atom(name) ->
          {node, if(guarded?(value, nil), do: MapSet.put(acc, name), else: acc)}

        node, acc ->
          {node, acc}
      end)

    names
  end

  # Does this source define one of the modules that own a guarded instance?
  defp owner?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:defmodule, _, [{:__aliases__, _, segments} | _]} = node, acc ->
          {node, acc or segments in @owners}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  # `ctx` is nil while the attributes themselves are being resolved.
  defp guarded?(atom, _ctx) when is_atom(atom), do: atom in @guarded

  defp guarded?({:@, _, [{name, _, context}]}, %{attributes: attributes})
       when is_atom(context),
       do: MapSet.member?(attributes, name)

  defp guarded?({{:., _, [{:__aliases__, _, segments}, :cache_name]}, _, []}, _ctx),
    do: List.last(segments) in @guarded_modules

  defp guarded?({{:., _, [{:__MODULE__, _, context}, :cache_name]}, _, []}, %{owner?: owner?})
       when is_atom(context),
       do: owner?

  defp guarded?({:cache_name, _, args}, %{owner?: owner?}) when args in [[], nil],
    do: owner?

  defp guarded?(_other, _ctx), do: false
end
