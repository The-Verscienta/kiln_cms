# Compiled with the package under MIX_ENV=test (`elixirc_paths/1` in mix.exs)
# rather than defined in the test file: they implement protocols, which are
# consolidated before the test files load.
defmodule Kiln.ContractTest.Note do
  @moduledoc false
  use Kiln.Block

  block :sdk_note do
    version(2)
    field :text, :string, required: true
    field :tone, :string, default: "info", editable_by: [:admin]

    migrate(from: 1, to: 2, fun: &__MODULE__.up/1)
  end

  def up(map), do: map

  @impl Kiln.Block.Renderer
  def render(block, :json), do: %{"_type" => "sdk_note", "text" => block.text}
  def render(_block, _surface), do: nil
end

defmodule Kiln.ContractTest.Plugin do
  @moduledoc false
  use Kiln.Plugin

  @impl Kiln.Plugin
  def blocks, do: [Kiln.ContractTest.Note]
end

defmodule Kiln.ContractTest.Stars do
  @moduledoc false
  use Kiln.FieldType

  @impl Kiln.FieldType
  def cast(value, _definition) when value in 1..5, do: {:ok, value}
  def cast(_value, _definition), do: {:error, "1 to 5"}
end

defmodule Kiln.ContractTest.Links do
  @moduledoc false
  use Kiln.Forms.SpamCheck

  @impl Kiln.Forms.SpamCheck
  def check(context) do
    if String.contains?(Kiln.Forms.SpamCheck.Context.text(context), "http"),
      do: flag(:link, 10),
      else: :ok
  end
end

defmodule Kiln.ContractTest.Backend do
  @moduledoc false
  use Kiln.ImageBackend

  @impl Kiln.ImageBackend
  def name, do: "sdk_test"
  @impl Kiln.ImageBackend
  def configured?, do: true
  @impl Kiln.ImageBackend
  def accepts?(_candidate), do: true
  @impl Kiln.ImageBackend
  def store(key, _path), do: {:ok, key}
  @impl Kiln.ImageBackend
  def fetch(_key), do: {:ok, ""}
  @impl Kiln.ImageBackend
  def delete(_key), do: :ok
  @impl Kiln.ImageBackend
  def url(key), do: "https://img.example/" <> key
end

defmodule Kiln.ContractTest.Captcha do
  @moduledoc false
  use Kiln.Challenge.Provider

  @impl Kiln.Challenge.Provider
  def id, do: "sdk_captcha"

  @impl Kiln.Challenge.Provider
  def widget,
    do: %{script_url: "https://captcha.example/v1/api.js?render=explicit", global: "sdkCaptcha"}

  @impl Kiln.Challenge.Provider
  def csp_sources,
    do: %{script_src: ["https://captcha.example/v1/"], frame_src: [], connect_src: []}

  @impl Kiln.Challenge.Provider
  def verify("good", _opts), do: {:ok, %{hostname: "example.com"}}
  def verify(_token, _opts), do: {:error, :invalid}
end

defmodule Kiln.ContractTest.ConfigurableCaptcha do
  @moduledoc false
  # One provider module per set of overrides, compiled on demand, so each
  # conformance case can break exactly one thing.
  @base [
    id: "configurable",
    script_url: "https://captcha.example/v1/api.js",
    global: "configurable",
    script_src: ["https://captcha.example/v1/"],
    frame_src: [],
    connect_src: []
  ]

  @widget_keys [
    :api,
    :render_options,
    :action_option,
    :onload_param,
    :response_field,
    :interactive
  ]

  def with(overrides) do
    opts = Keyword.merge(@base, overrides)
    name = Module.concat(__MODULE__, "V#{:erlang.phash2(opts)}")

    unless Code.ensure_loaded?(name) do
      widget =
        Map.merge(
          %{script_url: opts[:script_url], global: opts[:global]},
          Map.new(Keyword.take(opts, @widget_keys))
        )

      csp = %{
        script_src: opts[:script_src],
        frame_src: opts[:frame_src],
        connect_src: opts[:connect_src]
      }

      raising = opts[:raise]

      Module.create(
        name,
        quote do
          use Kiln.Challenge.Provider

          def id, do: unquote(opts[:id])

          def widget do
            if unquote(raising) == :widget, do: raise("boom")
            unquote(Macro.escape(widget))
          end

          def csp_sources, do: unquote(Macro.escape(csp))
          def verify(_token, _opts), do: {:error, :invalid}
        end,
        Macro.Env.location(__ENV__)
      )
    end

    name
  end
end
