defmodule KilnCMS.Backups.MarkPrunedLockTest do
  @moduledoc """
  `:mark_pruned` computes its marks from the row as locked, not from the
  struct the caller read (#2846): a mark made through a stale struct keeps
  every write that landed since. Concurrency proper is in
  `KilnCMS.Backups.ReevaluateRaceTest`.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Backups

  @stamp "20260801-031700"
  @at "2026-08-02T03:00:00Z"
  @dest "dest:7f1c3a52-6d1e-4c1b-9a51-2f0e7b6c9d10"

  defp artifact(kind, name),
    do: %{kind: kind, name: name, bytes: 1, destinations: %{"local" => %{"status" => "ok"}}}

  defp mark!(run, names, key),
    do: Backups.mark_run_pruned!(run, %{names: names, key: key, at: @at}, actor: Backups.system())

  test "a mark through a stale struct lands on the current artifacts" do
    stale =
      Backups.import_run!(
        %{
          stamp: @stamp,
          trigger: "cron",
          status: :succeeded,
          artifacts: [
            artifact(:db, "kiln-db-#{@stamp}.dump"),
            artifact(:media, "kiln-media-#{@stamp}.tar.gz")
          ]
        },
        actor: Backups.system()
      )

    # One prune (this host's directory) lands, then another (a destination)
    # through the struct read before it.
    mark!(stale, ["kiln-db-#{@stamp}.dump"], "local")
    marked = mark!(stale, ["kiln-media-#{@stamp}.tar.gz"], @dest)

    assert [db, media] = marked.artifacts
    assert db.destinations["local"] == %{"status" => "pruned", "at" => @at}
    assert media.destinations[@dest] == %{"status" => "pruned", "at" => @at}
    assert media.destinations["local"] == %{"status" => "ok"}

    assert Backups.get_run_by_stamp!(@stamp, actor: Backups.system()).artifacts ==
             marked.artifacts
  end

  test "the caller can't send artifacts of its own" do
    run =
      Backups.import_run!(
        %{
          stamp: @stamp,
          trigger: "cron",
          status: :succeeded,
          artifacts: [artifact(:db, "kiln-db-#{@stamp}.dump")]
        },
        actor: Backups.system()
      )

    assert {:error, %Ash.Error.Invalid{}} =
             Backups.mark_run_pruned(
               run,
               %{artifacts: [], names: [], key: "local", at: @at},
               actor: Backups.system()
             )

    assert [_one] = Backups.get_run_by_stamp!(@stamp, actor: Backups.system()).artifacts
  end
end
