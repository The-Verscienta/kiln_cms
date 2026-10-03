defmodule KilnCMS.Docs.DeployTemplatesTest do
  @moduledoc """
  The one-click deploy templates (#1529) parse, and keep the properties
  `docs/deploy-platforms.md` promises for each.

  This is not the platforms' own validation: no Render, Fly or DigitalOcean
  tool runs in CI, and their schemas change on their side. It is what a typo,
  a stale tag or a dropped variable would break first: the files parse as
  YAML/TOML, every template pins the same exact image tag, the secrets and the
  database are wired, health checks hit `/up`, and each platform's
  `CLIENT_IP_HEADER` (#1548) is one `KilnCMSWeb.Plugs.ClientIp` accepts there.
  """
  use ExUnit.Case, async: true

  alias KilnCMSWeb.Plugs.ClientIp

  @render "render.yaml"
  @fly "fly.toml"
  @digitalocean ".do/app.yaml"

  defp yaml!(path), do: YamlElixir.read_from_file!(path)
  defp toml!(path), do: path |> File.read!() |> Toml.decode!()

  defp tags do
    [web] = yaml!(@render)["services"]
    "ghcr.io/the-verscienta/kiln_cms:" <> render = web["image"]["url"]
    "ghcr.io/the-verscienta/kiln_cms:" <> fly = toml!(@fly)["build"]["image"]
    [do_web] = yaml!(@digitalocean)["services"]

    %{render: render, fly: fly, digitalocean: do_web["image"]["tag"]}
  end

  test "every template pins the same exact release tag" do
    tags = tags()

    assert tags |> Map.values() |> Enum.uniq() |> length() == 1,
           "the templates disagree on the image tag: #{inspect(tags)}"

    for {platform, tag} <- tags do
      assert {:ok, %Version{pre: []}} = Version.parse(tag),
             "#{platform} pins #{inspect(tag)}, not an exact final release (never `latest`)"
    end
  end

  test "render.yaml: secrets, database and disk are wired" do
    blueprint = yaml!(@render)
    [web] = blueprint["services"]
    envs = Map.new(web["envVars"], &{&1["key"], &1})

    assert web["healthCheckPath"] == "/up"
    assert envs["DATABASE_URL"]["fromDatabase"]["name"] == hd(blueprint["databases"])["name"]
    # Prompted at deploy time: Render's generated values are too short for it.
    assert envs["SECRET_KEY_BASE"]["sync"] == false
    assert envs["TOKEN_SIGNING_SECRET"]["generateValue"] == true
    assert envs["KILN_MEDIA_ROOT"]["value"] == web["disk"]["mountPath"]
    # No platform header to trust on Render (deploy-platforms.md).
    refute Map.has_key?(envs, "CLIENT_IP_HEADER")
    refute Map.has_key?(envs, "TRUSTED_PROXIES")
  end

  test "fly.toml: volume, health check and the client-address header" do
    fly = toml!(@fly)
    env = fly["env"]

    assert env["KILN_MEDIA_ROOT"] == fly["mounts"]["destination"]
    assert [%{"path" => "/up"}] = fly["http_service"]["checks"]
    assert fly["http_service"]["internal_port"] == String.to_integer(env["PORT"])

    # Fly sets these two in every Machine.
    markers = %{"FLY_APP_NAME" => "kiln", "FLY_MACHINE_ID" => "148e123a"}
    header = env["CLIENT_IP_HEADER"]

    assert ClientIp.header_setting(Map.put(markers, "CLIENT_IP_HEADER", header)) ==
             {:header, header}
  end

  test ".do/app.yaml: database, health check and the client-address header" do
    spec = yaml!(@digitalocean)
    [web] = spec["services"]
    [db] = spec["databases"]
    envs = Map.new(web["envs"], &{&1["key"], &1["value"]})

    assert web["health_check"]["http_path"] == "/up"
    assert envs["DATABASE_URL"] == "${#{db["name"]}.DATABASE_URL}"
    assert envs["PHX_HOST"] == "${APP_DOMAIN}"
    assert web["http_port"] == String.to_integer(envs["PORT"])

    for secret <- ~w(SECRET_KEY_BASE TOKEN_SIGNING_SECRET AWS_SECRET_ACCESS_KEY) do
      assert Enum.find(web["envs"], &(&1["key"] == secret))["type"] == "SECRET"
    end

    # The marker is App Platform's own binding; it resolves to the app's UUID.
    assert envs["APP_ID"] == "${APP_ID}"
    header = envs["CLIENT_IP_HEADER"]
    resolved = %{"APP_ID" => Ecto.UUID.generate(), "CLIENT_IP_HEADER" => header}
    assert ClientIp.header_setting(resolved) == {:header, header}
  end
end
