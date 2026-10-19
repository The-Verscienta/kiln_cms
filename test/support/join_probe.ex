defmodule KilnCMS.JoinProbe do
  @moduledoc """
  A graduated join resource for tests (#2024): the generator's own output for
  a field (`Mix.Tasks.Kiln.Gen.Join.resource_body/1`), compiled under a
  probe name on a probe domain registered in `:ash_domains` — so
  `KilnCMS.CMS.JoinGraduation.join_resources/0` finds it as it would a real
  one — over a throwaway table with the columns `mix ash.codegen` gives it,
  foreign keys included.

  For a field with no link fields. Creating a table locks nothing that
  exists, so a sandboxed test may build one; an unboxed test drops it with
  `drop!/1`.
  """

  alias KilnCMS.Repo

  @doc "Build the table and the resource for `spec`, returning `spec` pointed at them."
  def build!(spec) do
    n = System.unique_integer([:positive])
    table = "join_probe_#{n}"
    on_delete = if spec.on_target_delete == :restrict, do: "RESTRICT", else: "CASCADE"

    Repo.query!("""
    CREATE TABLE #{table} (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      org_id uuid NOT NULL,
      source_id uuid NOT NULL REFERENCES #{spec.source.table}(id) ON DELETE CASCADE,
      target_id uuid NOT NULL REFERENCES #{spec.target.table}(id) ON DELETE #{on_delete},
      position bigint NOT NULL DEFAULT 0,
      inserted_at timestamp NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      updated_at timestamp NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      UNIQUE (org_id, source_id, target_id)
    )
    """)

    module = Module.concat(KilnCMS.CMS, "JoinProbe#{n}")
    domain = Module.concat(KilnCMS, "JoinProbeDomain#{n}")
    spec = %{spec | table: table, module: module}

    body =
      spec
      |> Mix.Tasks.Kiln.Gen.Join.resource_body()
      |> String.replace("domain: KilnCMS.CMS,", "domain: #{inspect(domain)},")

    ExUnit.CaptureIO.with_io(:stderr, fn ->
      Code.compile_string("defmodule #{inspect(module)} do\n#{body}\nend\n")

      Code.compile_string("""
      defmodule #{inspect(domain)} do
        use Ash.Domain, validate_config_inclusion?: false

        resources do
          resource #{inspect(module)}
        end
      end
      """)
    end)

    domains = Application.get_env(:kiln_cms, :ash_domains)
    Application.put_env(:kiln_cms, :ash_domains, domains ++ [domain])
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:kiln_cms, :ash_domains, domains) end)

    spec
  end

  @doc "Drop a probe's table (an unboxed test's, which commits)."
  def drop!(spec), do: Repo.query!("DROP TABLE IF EXISTS #{spec.table}")

  @doc "Connect `source` to `target` through the probe, as `actor`."
  def connect(spec, source, target, opts) do
    spec.module
    |> Ash.Changeset.for_create(:create, %{source_id: source.id, target_id: target.id}, opts)
    |> Ash.create()
  end
end
