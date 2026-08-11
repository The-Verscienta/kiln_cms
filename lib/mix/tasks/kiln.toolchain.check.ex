defmodule Mix.Tasks.Kiln.Toolchain.Check do
  @moduledoc """
  Fails when the declared toolchain versions disagree with each other.

  `.tool-versions` is the source of truth. Three things have to agree with it,
  and until #600 nothing checked that any of them did:

    * **`mix.exs`'s `elixir:` requirement** must accept the pinned Elixir.
      #573 raised it from `~> 1.15` to `~> 1.19` and updated CI, but not the
      Dockerfile — which still selected a 1.18.4 builder image. That image
      cannot compile this project at all.
    * **`Dockerfile`'s `ELIXIR_VERSION` / `OTP_VERSION` ARGs**, which pick the
      builder image. Docker cannot read `.tool-versions` at build time, so these
      are restated and must be checked rather than derived.
    * **CI** reads `.tool-versions` directly through `setup-beam`'s
      `version-file:`, so there is nothing to check there — that is the point.

  ## Why this is a separate gate, not a test

  It is cheap and it is early. CI's `image` job does build the release image
  (#600), so a Dockerfile that cannot build is no longer green everywhere — but
  that job finds the mismatch the slow way, and *not* where you would guess:
  `mix deps.get` and `mix deps.compile` do not check the `:elixir` requirement,
  so the build runs the entire dependency compile before dying at `mix compile`.
  This gate names the same problem in a second, on the developer's machine,
  before a runner spends half an hour on it.

  ## What it deliberately does not check

  The Elixir/OTP actually running. Local development runs ahead of the pin
  (1.20.x / OTP 29) on purpose, and failing there would make the gate something
  to route around. This compares *declarations* to each other, not to the host.

      mix kiln.toolchain.check
  """
  @shortdoc "Fails when .tool-versions, mix.exs and the Dockerfile disagree"

  use Mix.Task

  @tool_versions ".tool-versions"
  @dockerfile "Dockerfile"

  @impl Mix.Task
  def run(_args) do
    {elixir, erlang} = read_tool_versions()

    problems =
      Enum.reject(
        [
          check_mix_requirement(elixir),
          check_dockerfile_arg("ELIXIR_VERSION", elixir),
          check_dockerfile_arg("OTP_VERSION", erlang)
        ],
        &is_nil/1
      )

    if problems == [] do
      Mix.shell().info(
        "Toolchain: #{@tool_versions}, mix.exs and #{@dockerfile} agree " <>
          "(elixir #{elixir}, erlang #{erlang})."
      )
    else
      shell = Mix.shell()
      Enum.each(problems, &shell.error/1)

      Mix.raise("""
      #{length(problems)} toolchain mismatch(es).

      #{@tool_versions} is the source of truth. Update mix.exs and the
      #{@dockerfile} ARGs to agree with it in this same change. CI's `image`
      job would eventually catch a stale Dockerfile pin by failing to build,
      but only after compiling every dependency first. See #600.
      """)
    end
  end

  @doc false
  # Exposed for tests: the parse is the part that silently does the wrong thing
  # if the file format drifts, and a wrong parse would make the gate pass on a
  # genuine mismatch.
  def parse_tool_versions(contents) do
    lines =
      contents
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

    {version_for(lines, "elixir"), version_for(lines, "erlang")}
  end

  defp version_for(lines, tool) do
    Enum.find_value(lines, fn line ->
      case String.split(line, ~r/\s+/, parts: 2) do
        [^tool, version] -> String.trim(version)
        _ -> nil
      end
    end)
  end

  defp read_tool_versions do
    unless File.exists?(@tool_versions) do
      Mix.raise("#{@tool_versions} is missing — it is the source of truth for the toolchain.")
    end

    case @tool_versions |> File.read!() |> parse_tool_versions() do
      {nil, _} -> Mix.raise("#{@tool_versions} declares no `elixir` version.")
      {_, nil} -> Mix.raise("#{@tool_versions} declares no `erlang` version.")
      pair -> pair
    end
  end

  # `.tool-versions` spells Elixir as `1.19.5-otp-27`; the bare version is what
  # mix.exs and the Dockerfile tag use.
  defp base_version(version), do: version |> String.split("-") |> hd()

  defp check_mix_requirement(elixir) do
    requirement = Mix.Project.config()[:elixir]
    version = base_version(elixir)

    cond do
      is_nil(requirement) ->
        "mix.exs declares no `elixir:` requirement, so nothing constrains the toolchain."

      Version.match?(version, requirement) ->
        nil

      true ->
        "mix.exs requires elixir #{requirement}, which #{version} " <>
          "(#{@tool_versions}) does not satisfy."
    end
  end

  defp check_dockerfile_arg(arg, expected) do
    expected = base_version(expected)

    case dockerfile_arg(arg) do
      nil ->
        "#{@dockerfile} declares no `ARG #{arg}`."

      ^expected ->
        nil

      actual ->
        "#{@dockerfile} pins #{arg}=#{actual}, but #{@tool_versions} says #{expected}."
    end
  end

  defp dockerfile_arg(arg) do
    unless File.exists?(@dockerfile) do
      Mix.raise("#{@dockerfile} is missing.")
    end

    # Anchored to the line start so the ARG that *sets the default* is read, not
    # a mention inside BUILDER_IMAGE's interpolation or a comment.
    case Regex.run(~r/^ARG\s+#{arg}=(\S+)/m, File.read!(@dockerfile)) do
      [_, value] -> value
      nil -> nil
    end
  end
end
