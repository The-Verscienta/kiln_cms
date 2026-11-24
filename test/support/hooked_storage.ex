defmodule KilnCMS.Test.HookedStorage do
  @moduledoc """
  The Local storage adapter with a hook per operation, for tests that need a
  storage call to fail, or something to happen at an exact point in a job.

  Install it with `install/1`, which makes it the `KilnCMS.Storage` adapter
  for the rest of the test. The hooks are a map keyed by operation:
  `:fetch`, `:fetch_range`, `:fetch_private_range`, `:store`, `:delete`
  and `:delete_private`. A hook is either

    * `{:error, reason}`, returned in place of the call, or
    * a 0- or 1-arity function (given the key), run before the Local call.
      For `:store` it runs **after** the store, so a test can act at the
      moment the bytes have landed.

  An operation with no hook is the Local adapter's. The hooks live in the
  app env, which is VM-global, so a test using this must be `async: false`.
  """
  alias KilnCMS.Storage.Local

  @doc """
  Makes this the storage adapter with `hooks` for the rest of the test, and
  puts the previous adapter back on exit.
  """
  @spec install(map()) :: :ok
  def install(hooks) when is_map(hooks) do
    previous = Application.fetch_env(:kiln_cms, KilnCMS.Storage)
    Application.put_env(:kiln_cms, KilnCMS.Storage, adapter: __MODULE__)
    Application.put_env(:kiln_cms, __MODULE__, hooks)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:kiln_cms, __MODULE__)

      case previous do
        {:ok, value} -> Application.put_env(:kiln_cms, KilnCMS.Storage, value)
        :error -> Application.delete_env(:kiln_cms, KilnCMS.Storage)
      end
    end)
  end

  def store(key, source_path) do
    case hook(:store) do
      {:error, _reason} = error ->
        error

      nil ->
        Local.store(key, source_path)

      fun ->
        result = Local.store(key, source_path)
        run(fun, key)
        result
    end
  end

  def fetch(key), do: around(:fetch, key, fn -> Local.fetch(key) end)

  def fetch_range(key, first, last),
    do: around(:fetch_range, key, fn -> Local.fetch_range(key, first, last) end)

  def fetch_private_range(key, first, last),
    do: around(:fetch_private_range, key, fn -> Local.fetch_private_range(key, first, last) end)

  def delete(key), do: around(:delete, key, fn -> Local.delete(key) end)

  def delete_private(key),
    do: around(:delete_private, key, fn -> Local.delete_private(key) end)

  defdelegate url(key), to: Local
  defdelegate store_private(key, source_path), to: Local
  defdelegate fetch_private(key), to: Local
  defdelegate private_available?, to: Local

  defp around(operation, key, local) do
    case hook(operation) do
      {:error, _reason} = error ->
        error

      nil ->
        local.()

      fun ->
        run(fun, key)
        local.()
    end
  end

  defp hook(operation),
    do: :kiln_cms |> Application.get_env(__MODULE__, %{}) |> Map.get(operation)

  defp run(fun, _key) when is_function(fun, 0), do: fun.()
  defp run(fun, key) when is_function(fun, 1), do: fun.(key)
end
