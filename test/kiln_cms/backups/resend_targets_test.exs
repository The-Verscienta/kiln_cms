defmodule KilnCMS.Backups.ResendTargetsTest do
  @moduledoc """
  Which runs a re-send accepts and where it sends them (#2949,
  `KilnCMS.Backups.Resend`), on run structs built here: no database, no
  backup directory.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Backups.{Artifact, Resend, Run, RunDestination}

  @stamp "20261118-050607"
  @sha String.duplicate("c", 64)

  defp run(attrs \\ %{}) do
    struct!(
      Run,
      Map.merge(
        %{
          stamp: @stamp,
          origin: :app,
          status: :succeeded,
          offsite_status: :partial,
          dir_id: Ash.UUID.generate(),
          started_at: DateTime.utc_now(),
          log: [],
          artifacts: [artifact()],
          destinations: [
            dest("rclone:r2:kiln", :ok),
            dest("dest:b", :failed),
            dest("dest:gone", :failed)
          ]
        },
        attrs
      )
    )
  end

  defp artifact(attrs \\ %{}) do
    struct!(
      Artifact,
      Map.merge(
        %{
          kind: :db,
          name: "kiln-db-#{@stamp}.dump",
          bytes: 5,
          sha256: @sha,
          verified: true,
          parts: [],
          destinations: %{"local" => %{"status" => "ok"}}
        },
        attrs
      )
    )
  end

  defp dest(key, status), do: %RunDestination{key: key, label: key, status: status}

  defp configured(key, source),
    do: %{"key" => key, "id" => nil, "kind" => "fake", "source" => source, "label" => key}

  describe "offered/1" do
    test "a partly off-site in-app run with verified files is offered" do
      assert :ok = Resend.offered(run())
    end

    test "is refused for a run that isn't partly off-site" do
      assert {:error, :not_partial} = Resend.offered(run(%{status: :failed}))
      assert {:error, :not_partial} = Resend.offered(run(%{origin: :imported}))

      assert {:error, :not_partial} =
               Resend.offered(
                 run(%{offsite_status: :complete, destinations: [dest("dest:b", :ok)]})
               )
    end

    test "is refused for a run without a backup directory id, or unverified files" do
      assert {:error, :no_dir_id} = Resend.offered(run(%{dir_id: nil}))
      assert {:error, :unverified} = Resend.offered(run(%{artifacts: []}))

      assert {:error, :unverified} =
               Resend.offered(run(%{artifacts: [artifact(%{verified: false})]}))

      assert {:error, :unverified} = Resend.offered(run(%{artifacts: [artifact(%{sha256: nil})]}))
    end

    test "is refused for a run whose local files retention pruned, a part's included" do
      pruned = %{"local" => %{"status" => "pruned"}}

      assert {:error, :pruned} =
               Resend.offered(run(%{artifacts: [artifact(%{destinations: pruned})]}))

      set =
        artifact(%{
          kind: :media,
          name: "kiln-media-#{@stamp}",
          sha256: nil,
          parts: [
            %{"name" => Artifact.part_name(@stamp, 1), "bytes" => 1, "sha256" => @sha},
            %{
              "name" => Artifact.part_name(@stamp, 2),
              "bytes" => 1,
              "sha256" => @sha,
              "destinations" => pruned
            }
          ]
        })

      assert {:error, :pruned} = Resend.offered(run(%{artifacts: [set]}))
    end
  end

  describe "eligible/2" do
    test "waits out the settle window of the newest re-send Cancel on the run's log" do
      now = DateTime.utc_now()
      note = %{at: DateTime.add(now, -10, :second), message: Resend.canceled_note()}

      assert {:error, {:canceled_recently, seconds}} =
               Resend.eligible(run(%{log: [note]}), now)

      assert seconds > 0

      old = %{note | at: DateTime.add(now, -3600, :second)}
      assert :ok = Resend.eligible(run(%{log: [old]}), now)
    end
  end

  describe "targets/2" do
    test "the failed entries still configured, in the run's order; the rest skipped" do
      configured = [configured("rclone:r2:kiln", "env"), configured("dest:b", "db")]

      assert %{
               targets: [%{"key" => "dest:b"}],
               skipped: [%{key: "dest:gone"}],
               unreadable?: false
             } =
               Resend.targets(run(), configured)
    end

    test "the unreadable entry expands to the stored destinations the run has no entry for (O3)" do
      run =
        run(%{
          destinations: [
            dest("rclone:r2:kiln", :ok),
            dest("dest:b", :ok),
            dest(RunDestination.unreadable_key(), :failed)
          ]
        })

      configured = [
        configured("rclone:r2:kiln", "env"),
        configured("dest:b", "db"),
        configured("dest:c", "db")
      ]

      assert %{targets: [%{"key" => "dest:c"}], skipped: [], unreadable?: true} =
               Resend.targets(run, configured)

      # With no stored destination left to stand for, it is skipped.
      assert %{targets: [], skipped: [%{key: "unreadable"}], unreadable?: false} =
               Resend.targets(run, [
                 configured("rclone:r2:kiln", "env"),
                 configured("dest:b", "db")
               ])
    end
  end

  describe "outputs/1" do
    test "one entry per file and per part of a media set, as state.json holds them" do
      set =
        artifact(%{
          kind: :media,
          name: "kiln-media-#{@stamp}",
          sha256: nil,
          parts: [
            %{"name" => Artifact.part_name(@stamp, 1), "bytes" => 1, "sha256" => @sha},
            %{"name" => Artifact.part_name(@stamp, 2), "bytes" => 2, "sha256" => @sha}
          ]
        })

      assert [
               %{"kind" => "db", "path" => "db/kiln-db-" <> _, "sha256" => @sha},
               %{"kind" => "media", "part" => 1, "parts_total" => 2, "bytes" => 1},
               %{"kind" => "media", "part" => 2, "parts_total" => 2, "path" => "media/" <> _}
             ] = Resend.outputs(run(%{artifacts: [artifact(), set]}))
    end
  end
end
