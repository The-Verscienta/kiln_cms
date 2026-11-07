defmodule Kiln.Plugins.PlugRoute do
  @moduledoc false

  # Shape and overlap rules for `c:Kiln.Plugin.plug_routes/0` (#2272), shared by
  # the router macro (which raises on a malformed route at compile time) and
  # `mix kiln.plugins.doctor` (which reports every problem at once), so the two
  # cannot disagree about what a valid route is.

  @verbs [:get, :post, :put, :patch, :delete, :match]

  # Roots the endpoint answers outside the router (`/live`, `/ws/*`) and the
  # roots a plugin must never take. The doctor adds every static root of the
  # compiled core route table to these; this list is what holds even if a
  # route is renamed.
  @reserved_roots ~w(editor api gql mcp live ws)

  @doc "The roots no plugin route may sit under, before the core route table is read."
  @spec reserved_roots() :: [String.t()]
  def reserved_roots, do: @reserved_roots

  @doc """
  A plugin's declared plug routes, tolerating a plugin compiled against a
  `kiln_plugin` older than 1.4, which has no `plug_routes/0`.
  """
  @spec of(module()) :: [Kiln.Plugin.plug_route()]
  def of(plugin) do
    Code.ensure_loaded(plugin)
    if function_exported?(plugin, :plug_routes, 0), do: plugin.plug_routes(), else: []
  end

  @doc "Whether `route` is well formed; the error is a sentence fragment naming what is wrong."
  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate({verb, path, plug, opts}) when verb in @verbs or verb == :forward do
    with :ok <- validate_path(verb, path),
         :ok <- validate_plug(plug) do
      validate_opts(opts)
    end
  end

  def validate(other) do
    {:error,
     "#{inspect(other)} is not {verb, path, plug_module, plug_opts} " <>
       "(verb one of #{inspect(@verbs)}) or {:forward, path, plug_module, plug_opts}"}
  end

  defp validate_plug(plug) when is_atom(plug) and plug not in [nil, true, false], do: :ok
  defp validate_plug(plug), do: {:error, "#{inspect(plug)} is not a module"}

  # `Macro.escape/1` is what bakes the options into the router; a pid, a
  # reference or an anonymous function cannot survive it.
  defp validate_opts(opts) do
    _ = Macro.escape(opts)
    :ok
  rescue
    ArgumentError -> {:error, "plug_opts #{inspect(opts)} cannot be compiled into the router"}
  end

  defp validate_path(_verb, path) when not is_binary(path),
    do: {:error, "path #{inspect(path)} is not a string"}

  defp validate_path(verb, path) do
    segments = segments(path)

    cond do
      not String.starts_with?(path, "/") ->
        {:error, "path #{inspect(path)} must be absolute"}

      String.contains?(path, "//") or String.contains?(path, "?") ->
        {:error, "path #{inspect(path)} has an empty segment or a query string"}

      segments == [] ->
        {:error, "path #{inspect(path)} has no first segment (it would take over the whole site)"}

      dynamic?(hd(segments)) ->
        {:error,
         "path #{inspect(path)} starts with a parameter or wildcard, which would swallow content slugs"}

      verb == :forward and Enum.any?(segments, &dynamic?/1) ->
        {:error, "forward path #{inspect(path)} must be static"}

      true ->
        :ok
    end
  end

  @doc "The non-empty segments of a path."
  @spec segments(String.t()) :: [String.t()]
  def segments(path), do: String.split(path, "/", trim: true)

  @doc "The first segment of a route's path, or `nil` for a path with none."
  @spec root(String.t()) :: String.t() | nil
  def root(path), do: path |> segments() |> List.first()

  defp dynamic?(segment), do: String.starts_with?(segment, [":", "*"])

  @doc """
  Whether two `{verb, path}` claims can answer the same request, compared on
  segment boundaries (`/hooks` does not overlap `/hooks-extra`). A `:forward`
  owns everything below its path; `:match` is any method; a `:get` also answers
  `HEAD`.
  """
  @spec overlap?({atom(), String.t()}, {atom(), String.t()}) :: boolean()
  def overlap?({verb_a, path_a}, {verb_b, path_b}) do
    verbs_overlap?(verb_a, verb_b) and
      paths_overlap?(verb_a, segments(path_a), verb_b, segments(path_b))
  end

  defp verbs_overlap?(a, b), do: a == b or :forward in [a, b] or :match in [a, b]

  defp paths_overlap?(:forward, a, _verb_b, b), do: prefix?(a, b)
  defp paths_overlap?(_verb_a, a, :forward, b), do: prefix?(b, a)
  defp paths_overlap?(_verb_a, a, _verb_b, b), do: same?(a, b)

  # `prefix` is a prefix of `path`, parameters standing for any one segment and
  # a wildcard for the rest.
  defp prefix?([], _path), do: true
  defp prefix?(_prefix, []), do: false
  defp prefix?(["*" <> _ | _], _path), do: true
  defp prefix?([seg | rest], [other | more]), do: compatible?(seg, other) and prefix?(rest, more)

  defp same?([], []), do: true
  defp same?(["*" <> _ | _], _), do: true
  defp same?(_, ["*" <> _ | _]), do: true
  defp same?([seg | rest], [other | more]), do: compatible?(seg, other) and same?(rest, more)
  defp same?(_, _), do: false

  defp compatible?(a, b), do: a == b or dynamic?(a) or dynamic?(b)
end
