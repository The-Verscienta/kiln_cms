defmodule KilnCMS.Backups.Destination.S3EndpointTest do
  @moduledoc """
  Where an S3 destination may connect (#2221): the endpoint's name is
  resolved on save and before every call, and every address it resolves to
  must be allowed: public, or private and loopback for a host
  `BACKUP_S3_PRIVATE_HOSTS` lists, never link-local or metadata. The request
  then connects to the address checked.

  `async: false`: it turns on `KilnCMS.Webhooks.SafeUrl`'s DNS resolution
  with a stub resolver and sets the private hosts, both application env,
  which is VM-global.
  """
  use KilnCMS.DataCase, async: false

  alias Kiln.BackupDestination.Config
  alias KilnCMS.Backups
  alias KilnCMS.Backups.Destination.S3
  alias KilnCMS.Backups.Destination.S3.{Client, Endpoint}
  alias KilnCMS.Storage.S3.ReqClient
  alias KilnCMS.Test.BackupSchedules

  @answers %{
    ~c"s3.test" => [{93, 184, 216, 34}],
    ~c"kiln-backups.s3.test" => [{93, 184, 216, 35}],
    ~c"minio.lan" => [{10, 0, 0, 5}],
    ~c"sneaky.example" => [{93, 184, 216, 34}, {10, 0, 0, 5}],
    ~c"metadata.lan" => [{169, 254, 169, 254}],
    ~c"mapped.lan" => [{0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE}]
  }

  setup do
    safe_url = Application.get_env(:kiln_cms, KilnCMS.Webhooks.SafeUrl, [])
    s3 = Application.get_env(:kiln_cms, S3, [])

    resolver = fn name ->
      case Map.fetch(@answers, name) do
        {:ok, [first | _] = addresses} ->
          type = if tuple_size(first) == 4, do: :inet, else: :inet6
          {:ok, {:hostent, name, [], type, tuple_size(first), addresses}}

        :error ->
          {:error, :nxdomain}
      end
    end

    Application.put_env(
      :kiln_cms,
      KilnCMS.Webhooks.SafeUrl,
      Keyword.merge(safe_url, resolve_dns: true, resolver: resolver)
    )

    Application.put_env(
      :kiln_cms,
      S3,
      Keyword.put(s3, :private_hosts, ["minio.lan", "metadata.lan", "mapped.lan"])
    )

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Webhooks.SafeUrl, safe_url)
      Application.put_env(:kiln_cms, S3, s3)
    end)
  end

  defp endpoint(endpoint, settings \\ %{}) do
    {:ok, parsed} =
      Endpoint.parse(
        Map.merge(
          %{
            "endpoint" => endpoint,
            "region" => "us-east-1",
            "bucket" => "kiln-backups",
            "path_style" => true
          },
          settings
        )
      )

    parsed
  end

  test "a public name pins to the address it resolves to" do
    assert Endpoint.pin(endpoint("https://s3.test")) == {:ok, {93, 184, 216, 34}}
  end

  test "virtual-hosted, the bucket's own name is what is resolved and pinned" do
    assert Endpoint.pin(endpoint("https://s3.test", %{"path_style" => false})) ==
             {:ok, {93, 184, 216, 35}}
  end

  test "a name with any private answer is refused unless listed" do
    assert {:error, {:permanent, message}} = Endpoint.pin(endpoint("https://sneaky.example"))
    assert message =~ "BACKUP_S3_PRIVATE_HOSTS"

    assert Endpoint.pin(endpoint("http://minio.lan:9000")) == {:ok, {10, 0, 0, 5}}
  end

  test "a listed name still never reaches link-local or metadata, mapped or not" do
    for host <- ["http://metadata.lan", "http://mapped.lan"] do
      assert {:error, {:permanent, message}} = Endpoint.pin(endpoint(host))
      assert message =~ "link-local or metadata"
    end
  end

  test "a name that doesn't resolve is an error that may pass" do
    assert {:error, message} = Endpoint.pin(endpoint("https://nowhere.example"))
    assert is_binary(message)
  end

  test "the private hosts variable is a list of exact names" do
    assert Endpoint.parse_private_hosts(
             " MinIO.lan, ,10.0.0.5,http://x.lan,a.lan:9000,*.lan,garage.internal. "
           ) ==
             ["minio.lan", "10.0.0.5", "garage.internal"]

    assert Endpoint.parse_private_hosts(nil) == []
  end

  test "a request connects to the pinned address, with no redirects" do
    {:ok, client} = Client.new(endpoint("https://s3.test"), "AKID", "secret")
    assert client.pinned == {93, 184, 216, 34}

    options =
      ReqClient.build_options(:get, "https://s3.test/kiln-backups/x", "", [],
        pinned: true,
        pinned_address: client.pinned,
        receive_timeout: 1_234,
        req_options: [plug: {Req.Test, :elsewhere}]
      )

    assert options[:url] == "https://93.184.216.34/kiln-backups/x"
    assert options[:redirect] == false
    assert options[:receive_timeout] == 1_234
    assert options[:plug] == {Req.Test, :elsewhere}

    assert options[:connect_options][:transport_opts][:server_name_indication] == ~c"s3.test"
  end

  test "every call refuses an endpoint that resolves somewhere it may not go" do
    config = %Config{
      kind: "s3",
      settings: %{
        "endpoint" => "https://sneaky.example",
        "region" => "auto",
        "bucket" => "kiln-backups",
        "path_style" => true
      },
      secrets: %{"access_key_id" => "AKID", "secret_access_key" => "secret"}
    }

    assert {:error, {:permanent, _message}} = S3.list(config)
    assert {:error, {:permanent, _message}} = S3.test(config)
  end

  describe "saving a destination" do
    defp create(endpoint, actor \\ BackupSchedules.platform_admin()) do
      Backups.create_backup_destination(
        %{
          name: "Offsite #{System.unique_integer([:positive])}",
          kind: "s3",
          settings: %{
            "endpoint" => endpoint,
            "region" => "auto",
            "bucket" => "kiln-backups",
            "path_style" => true
          },
          secrets: %{"access_key_id" => "AKID", "secret_access_key" => "secret"}
        },
        actor: actor
      )
    end

    test "resolves the endpoint and refuses one that reaches a private address" do
      assert {:error, error} = create("https://sneaky.example")
      assert Exception.message(error) =~ "BACKUP_S3_PRIVATE_HOSTS"

      assert {:ok, row} = create("https://s3.test")
      assert row.kind == "s3"
      refute Map.has_key?(row.settings, "access_key_id")
    end

    test "is a platform admin's alone" do
      assert {:error, %Ash.Error.Forbidden{}} =
               create("https://s3.test", BackupSchedules.user(:editor))
    end
  end
end
