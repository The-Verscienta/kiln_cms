defmodule KilnCMS.ChallengeFake do
  @moduledoc """
  A human-verification provider for tests (#2249): the token says what the
  verification answers, so a test drives every branch of
  `KilnCMS.Challenge.Gate` without a network.

    * `"pass"` (or anything starting `"pass"`) → a pass solved on
      `localhost` (the test endpoint's host), with the action it was asked for
    * `"fail"` → `{:error, :invalid}`
    * `"expired"` → `{:error, :expired}`
    * `"wrong-host"` → a pass solved on `"evil.example.net"`, which the core's
      hostname check then refuses unless it is off
    * `"host:<name>"` → the same, for `<name>`
    * `"down"` → `{:error, {:unavailable, :transport}}`
    * `"slow"` → sleeps past any deadline a test sets
    * `"crash"` → raises

  Every call is reported to the process registered in
  `config :kiln_cms, KilnCMS.ChallengeFake, notify: pid` as
  `{:challenge_verify, token, opts}` (the secret removed), so a test can assert
  both what was verified and that nothing was.
  """
  use Kiln.Challenge.Provider

  @impl true
  def id, do: "fake"

  @impl true
  def label, do: "Fake"

  @impl true
  def widget,
    do: %{
      script_url: "https://challenge.test/api.js?render=explicit",
      global: "kilnFakeChallenge",
      render_options: %{"response-field" => false},
      action_option: "action"
    }

  @impl true
  def csp_sources,
    do: %{
      script_src: ["https://challenge.test"],
      frame_src: ["https://challenge.test"],
      connect_src: []
    }

  @impl true
  def verify(token, opts) do
    notify(token, opts)
    answer(token, opts)
  end

  defp answer("pass" <> _rest, opts), do: solved_on("localhost", opts)
  defp answer("fail", _opts), do: {:error, :invalid}
  defp answer("expired", _opts), do: {:error, :expired}
  defp answer("wrong-host", opts), do: solved_on("evil.example.net", opts)
  defp answer("host:" <> host, opts), do: solved_on(host, opts)
  defp answer("down", _opts), do: {:error, {:unavailable, :transport}}

  defp answer("slow", _opts) do
    Process.sleep(5_000)
    :ok
  end

  defp answer("crash", _opts), do: raise("fake provider crashed")
  defp answer(_other, _opts), do: {:error, :invalid}

  defp solved_on(host, opts), do: {:ok, %{hostname: host, action: Keyword.get(opts, :action)}}

  defp notify(token, opts) do
    case Keyword.get(Application.get_env(:kiln_cms, __MODULE__, []), :notify) do
      pid when is_pid(pid) -> send(pid, {:challenge_verify, token, Keyword.delete(opts, :secret)})
      _none -> :ok
    end
  end
end
