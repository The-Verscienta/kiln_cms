defmodule KilnCMS.BreachedPasswordFixtures do
  @moduledoc """
  Test scaffolding for the breached-password check (#2240).

  The check is off in `config/test.exs`, so no test calls a third party.
  A test that exercises it turns it on for its own duration with
  `enable!/2`, which points the client at a function plug instead of the
  network. Tests that use it are `async: false`: the stub and the policy live
  in application env, which is node-wide (the same reason
  `KilnCMS.FederationFixtures` gives for its deployment switch).

  The plug reports every request it receives to the test process as
  `{:hibp_request, request_path, request_headers}`, so a test can assert both
  *what* went on the wire and that nothing did.
  """

  alias KilnCMS.Accounts.BreachedPassword

  @doc """
  Turn the check on for this test, answering every request with `handler`
  (`fn conn -> conn end`), restoring the configuration on exit. `opts` are
  merged into the module's config (`:default_policy`, `:deadline`, `:host`).
  """
  @spec enable!((Plug.Conn.t() -> Plug.Conn.t()), keyword()) :: :ok
  def enable!(handler, opts \\ []) do
    original = Application.get_env(:kiln_cms, BreachedPassword, [])
    test = self()

    plug = fn conn ->
      send(test, {:hibp_request, conn.request_path, conn.req_headers})
      handler.(conn)
    end

    Application.put_env(
      :kiln_cms,
      BreachedPassword,
      original
      |> Keyword.merge(enabled: true, req_options: [plug: plug])
      |> Keyword.merge(opts)
    )

    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:kiln_cms, BreachedPassword, original) end)
    :ok
  end

  @doc "Set the operator default policy for this test."
  @spec default_policy!(:off | :warn | :block) :: :ok
  def default_policy!(policy) do
    original = Application.get_env(:kiln_cms, BreachedPassword, [])

    Application.put_env(
      :kiln_cms,
      BreachedPassword,
      Keyword.put(original, :default_policy, policy)
    )

    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:kiln_cms, BreachedPassword, original) end)
    :ok
  end

  @doc "A password no other test uses, so a stub can recognise it."
  @spec password() :: String.t()
  def password, do: "Hibp-" <> Base.encode16(:crypto.strong_rand_bytes(8)) <> "-pw"

  @doc """
  A well-formed range response for `password`: its suffix with `count`, among
  `noise` other real-looking entries and a few padding entries (count `0`).
  """
  @spec breached_body(String.t(), non_neg_integer(), non_neg_integer()) :: String.t()
  def breached_body(password, count, noise \\ 5) do
    {_prefix, suffix} = BreachedPassword.split_hash(password)
    body([{suffix, count} | noise_entries(noise, suffix)])
  end

  @doc "A well-formed range response that does not contain `password`."
  @spec clean_body(String.t()) :: String.t()
  def clean_body(password) do
    {_prefix, suffix} = BreachedPassword.split_hash(password)
    body(noise_entries(5, suffix))
  end

  @doc "A response whose only entry for `password` is a padding line (count 0)."
  @spec padding_only_body(String.t()) :: String.t()
  def padding_only_body(password) do
    {_prefix, suffix} = BreachedPassword.split_hash(password)
    body([{suffix, 0} | noise_entries(5, suffix)])
  end

  @doc "A 200 response with `body`."
  @spec ok(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def ok(conn, body), do: Plug.Conn.send_resp(conn, 200, body)

  defp body(entries) do
    entries
    |> Enum.shuffle()
    |> Enum.map_join("\r\n", fn {suffix, count} -> "#{suffix}:#{count}" end)
  end

  defp noise_entries(n, not_suffix) do
    for _ <- 1..n do
      suffix = :crypto.strong_rand_bytes(18) |> Base.encode16() |> binary_part(0, 35)
      {if(suffix == not_suffix, do: String.duplicate("0", 35), else: suffix), 3}
    end
  end
end
