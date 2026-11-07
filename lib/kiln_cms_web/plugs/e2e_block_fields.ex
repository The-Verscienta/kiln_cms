defmodule KilnCMSWeb.Plugs.E2EBlockFields do
  @moduledoc """
  Sets the deployment's per-locale block fields
  (`config :kiln_cms, :i18n, block_fields: ...`, #2270) for the browser E2E
  suite.

  `config/e2e.exs` configures none, so every block stays localized as before.
  `e2e/tests/field_localization.spec.js` marks fields of the core `image`
  block `shared` / `fallback` here for its block cases and puts the previous
  setting back afterwards. The setting is VM-global and read on every request,
  which is safe only because the suite runs one spec at a time (`workers: 1`).

  `POST` with `block_fields` as an object of block type to
  `{"shared": [field, ...], "fallback": [field, ...]}`, or an empty object to
  clear it. The answer is `{"block_fields": new, "was": previous}` in that same
  shape, and the caller restores `was`. Block types and field names are matched
  against the registered blocks' own fields, so nothing reaches the config (or
  the atom table) that the blocks do not already name.

  Mounted only inside the router's compile-gated dev-tools scope, like
  `KilnCMSWeb.Plugs.E2ELocales`, which `KilnCMS.Application` refuses in
  `:prod`. That scope runs `protect_from_forgery`, so the spec calls it from a
  signed-in page with the page's CSRF token.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "POST"} = conn, _opts) do
    with raw when is_map(raw) <- conn.params["block_fields"],
         {:ok, config} <- to_config(raw) do
      i18n = Application.get_env(:kiln_cms, :i18n, [])
      was = Keyword.get(i18n, :block_fields, %{})

      i18n =
        if config == %{},
          do: Keyword.delete(i18n, :block_fields),
          else: Keyword.put(i18n, :block_fields, config)

      Application.put_env(:kiln_cms, :i18n, i18n)
      reply(conn, 200, %{block_fields: to_json(config), was: to_json(was)})
    else
      _other ->
        reply(conn, 400, %{
          error:
            "block_fields must be an object of block type to " <>
              ~s({"shared": [field], "fallback": [field]}, naming fields the block has)
        })
    end
  end

  def call(conn, _opts) do
    conn
    |> put_resp_header("allow", "POST")
    |> reply(405, %{error: "POST only"})
  end

  # JSON -> `%{"image" => [shared: [:url], fallback: [:alt]]}`. A name becomes an
  # atom only by being found among the block's own field names.
  defp to_config(raw) do
    registry = Map.new(KilnCMS.Blocks.modules(), &{to_string(Kiln.Block.Info.name(&1)), &1})

    Enum.reduce_while(raw, {:ok, %{}}, fn {type, entry}, {:ok, acc} ->
      with {:ok, module} <- Map.fetch(registry, type),
           true <- is_map(entry) and Enum.all?(Map.keys(entry), &(&1 in ["shared", "fallback"])),
           {:ok, shared} <- field_names(module, entry["shared"]),
           {:ok, fallback} <- field_names(module, entry["fallback"]) do
        {:cont, {:ok, Map.put(acc, type, shared: shared, fallback: fallback)}}
      else
        _invalid -> {:halt, :error}
      end
    end)
  end

  defp field_names(_module, nil), do: {:ok, []}

  defp field_names(module, names) when is_list(names) do
    fields = Map.new(Kiln.Block.Info.fields(module), &{to_string(&1.name), &1.name})

    if Enum.all?(names, &is_binary/1) and Enum.all?(names, &Map.has_key?(fields, &1)),
      do: {:ok, names |> Enum.uniq() |> Enum.map(&Map.fetch!(fields, &1))},
      else: :error
  end

  defp field_names(_module, _other), do: :error

  defp to_json(config) when is_map(config) do
    Map.new(config, fn {type, entry} ->
      {type,
       %{
         "shared" => entry |> Keyword.get(:shared, []) |> Enum.map(&to_string/1),
         "fallback" => entry |> Keyword.get(:fallback, []) |> Enum.map(&to_string/1)
       }}
    end)
  end

  defp to_json(_other), do: %{}

  defp reply(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
