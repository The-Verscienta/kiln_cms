defmodule Mix.Tasks.Kiln.Api.Specs do
  @moduledoc """
  Writes the committed API descriptions, or checks they are current.

      mix kiln.api.specs           # rewrite docs/api/schema.graphql and docs/api/openapi.json
      mix kiln.api.specs --check   # fail if either differs from what the code generates

  The files are what a client author runs codegen against without a dev
  server: a production build disables GraphQL introspection and does not serve
  the OpenAPI document (#567). See `KilnCMSWeb.ApiSpecs` for how they are
  rendered and what they do and do not describe.

  ## When to run it

  After changing anything either API is built from — a resource's attributes,
  actions, `graphql` or `json_api` block, a block type, `KilnCMSWeb.OpenApi` —
  and after bumping `@version` in `mix.exs`, which the OpenAPI document states
  as `info.version`. CI's documentation job runs `--check` and names this task
  when it fails.

  ## Always the `:dev` build

  The schemas are compiled, and the test build compiles a fixture plugin that
  adds block types (`config/test.exs`). A spec generated there would describe
  blocks no deployment has, so the task runs in `:dev` (`preferred_envs` in
  `mix.exs`) and refuses any other environment rather than writing a wrong file
  quietly.

  A `config/project.exs` overlay is compiled into `:dev` too, and its domains
  land in both documents. That is what a downstream project wants for its own
  copy; the reusable core's committed files come from a checkout without one,
  which is what CI has.

  ## The pinned toolchain is the reference

  The files are rendered from the compiled resources, and one thing about
  them depends on the Erlang/OTP that compiled them: the position of the
  state-machine `state` attribute among a content resource's attributes. It
  differs between OTP 27 and 29, and that order is baked into strings in the
  OpenAPI document (each sort parameter's pattern and example) as well as the
  SDL's field order, so no sort can normalize it away. Seen on the first CI
  run of this task: a clean OTP 29 rendering failed OTP 27's check with 131
  lines moved and none changed.

  So the reference is `.tool-versions` — what CI's check and the release
  image run. On any other OTP major the task still writes, but says the
  result may not be what CI expects. When `--check` then fails in CI, its job
  uploads the files it generated as the `api-specs` artifact: commit those.

  The task compiles but does not start the application, so it needs no
  database.
  """
  @shortdoc "Writes (or --check's) the committed GraphQL SDL and OpenAPI document"

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [check: :boolean])

    if Mix.env() != :dev do
      Mix.raise("""
      mix kiln.api.specs describes the :dev build, and this is #{inspect(Mix.env())}.

      The test build compiles a fixture plugin whose block types would end up in
      the committed schema. Run it without MIX_ENV (it prefers :dev), or with
      MIX_ENV=dev.
      """)
    end

    Mix.Task.run("compile")
    warn_on_unpinned_otp()

    specs = [
      {KilnCMSWeb.ApiSpecs.sdl_path(), KilnCMSWeb.ApiSpecs.graphql_sdl()},
      {KilnCMSWeb.ApiSpecs.open_api_path(), KilnCMSWeb.ApiSpecs.open_api()}
    ]

    if opts[:check], do: check(specs), else: write(specs)
  end

  # Not an error: a developer ahead of the pin (the usual case, see
  # `.tool-versions`) should still be able to regenerate and read the diff.
  defp warn_on_unpinned_otp do
    with {:ok, contents} <- File.read(".tool-versions"),
         {_elixir, "" <> erlang} <- Mix.Tasks.Kiln.Toolchain.Check.parse_tool_versions(contents),
         pinned = erlang |> String.split(".") |> hd(),
         running = System.otp_release(),
         true <- pinned != running do
      Mix.shell().info([
        :yellow,
        "Running on OTP #{running}; .tool-versions pins OTP #{pinned}. The specs are ",
        "rendered from compiled resources whose attribute order can differ between ",
        "OTP majors, so CI's check may disagree with this output. If it does, commit ",
        "the files from the failing job's `api-specs` artifact.",
        :reset
      ])
    end
  end

  defp write(specs) do
    for {path, content} <- specs do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
      Mix.shell().info("Wrote #{path}")
    end
  end

  defp check(specs) do
    stale = for {path, content} <- specs, File.read(path) != {:ok, content}, do: path

    if stale == [] do
      Mix.shell().info("API specs are current: #{Enum.map_join(specs, ", ", &elem(&1, 0))}")
    else
      Mix.raise("""
      #{Enum.join(stale, " and ")} #{if length(stale) == 1, do: "is", else: "are"} out of date with the code.

      Run `mix kiln.api.specs` and commit the result. These files are what API
      clients generate code from, so a change to either schema is a change to
      them — review the diff as you would an API change.

      Rendering depends on the OTP major (see the task's moduledoc); the
      reference is the one .tool-versions pins. In CI, the failing job uploads
      the files it generated as the `api-specs` artifact.
      """)
    end
  end
end
