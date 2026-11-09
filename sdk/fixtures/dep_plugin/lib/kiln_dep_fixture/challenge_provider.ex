defmodule KilnDepFixture.ChallengeProvider do
  @moduledoc """
  A human-verification provider shipped from a dependency (kiln_cms#2249),
  so the core's suite proves one compiled before the core is registered,
  resolved and used. It verifies through the `:post` function the core hands
  it, like any provider: `"dep-pass"` is answered as a pass solved on
  `localhost`, anything else as a refusal. The core's tests point the
  transport at a stub, so nothing leaves the machine.
  """
  use Kiln.Challenge.Provider

  @origin "https://captcha.dep-fixture.test"

  @impl Kiln.Challenge.Provider
  def id, do: "dep_fixture"

  @impl Kiln.Challenge.Provider
  def label, do: "Dependency fixture"

  @impl Kiln.Challenge.Provider
  def widget,
    do: %{
      script_url: @origin <> "/v1/api.js?render=explicit",
      global: "depFixtureCaptcha",
      action_option: "action"
    }

  @impl Kiln.Challenge.Provider
  def csp_sources, do: %{script_src: [@origin <> "/v1/"], frame_src: [@origin], connect_src: []}

  @impl Kiln.Challenge.Provider
  def verify(token, opts) do
    post = Keyword.fetch!(opts, :post)

    case post.(@origin <> "/v1/verify", [{"secret", opts[:secret]}, {"response", token}]) do
      {:ok, %{status: 200, body: "pass"}} ->
        {:ok, %{hostname: "localhost", action: opts[:action]}}

      {:ok, %{status: 200}} ->
        {:error, :invalid}

      {:ok, %{status: status}} when status >= 500 ->
        {:error, {:unavailable, :http_status}}

      {:ok, _refused} ->
        {:error, :invalid}

      {:error, :timeout} ->
        {:error, {:unavailable, :timeout}}

      {:error, _transport} ->
        {:error, {:unavailable, :transport}}
    end
  end
end
