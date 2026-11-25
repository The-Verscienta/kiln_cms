defmodule KilnCMS.Media.StagedUploadClaimTest do
  @moduledoc """
  The claim a direct-upload completion holds on its cleanup job (#2724),
  statement by statement: who can take it, what renews it, and what settling
  it leaves behind. The end-to-end races are in
  `KilnCMSWeb.MediaDirectUploadTest`.

  `async: false`: the heartbeat tests set the heartbeat interval in the
  application env.
  """
  use KilnCMS.DataCase, async: false

  import Ecto.Query

  alias KilnCMS.Media.{StagedUploadClaim, StagedUploadCleanup}
  alias KilnCMS.Repo

  setup do
    key = "direct-uploads/" <> Ecto.UUID.generate()
    :ok = StagedUploadCleanup.schedule(key, 3_660)
    %{key: key, original: job(key)}
  end

  defp job(key) do
    Repo.one!(from j in Oban.Job, where: fragment("? @> ?", j.args, ^%{"key" => key}))
  end

  defp set_scheduled_at(key, at),
    do: Repo.update_all(from(j in Oban.Job, where: j.id == ^job(key).id), set: [scheduled_at: at])

  defp set_state(key, state),
    do: Repo.update_all(from(j in Oban.Job, where: j.id == ^job(key).id), set: [state: state])

  test "one claim at a time", %{key: key} do
    assert {:ok, claim} = StagedUploadClaim.claim(key)
    assert job(key).meta["claim"] == claim.id
    assert {:error, :not_uploaded} = StagedUploadClaim.claim(key)
  end

  test "a claim pulls the job's schedule to the lease's end and remembers the original",
       %{key: key, original: original} do
    assert {:ok, _claim} = StagedUploadClaim.claim(key)

    job = job(key)
    assert DateTime.diff(job.scheduled_at, DateTime.utc_now()) in 290..300
    {:ok, remembered} = NaiveDateTime.from_iso8601(job.meta["claim_scheduled_at"])

    assert DateTime.compare(DateTime.from_naive!(remembered, "Etc/UTC"), original.scheduled_at) ==
             :eq
  end

  test "nothing to claim for a job that is not scheduled, or for another key", %{key: key} do
    assert {:error, :not_uploaded} = StagedUploadClaim.claim("direct-uploads/other")

    set_state(key, "executing")
    assert {:error, :not_uploaded} = StagedUploadClaim.claim(key)
  end

  test "a job due within the stager margin is not claimed", %{key: key} do
    set_scheduled_at(key, DateTime.add(DateTime.utc_now(), 2))
    assert {:error, :not_uploaded} = StagedUploadClaim.claim(key)

    set_scheduled_at(key, DateTime.add(DateTime.utc_now(), 30))
    assert {:ok, _claim} = StagedUploadClaim.claim(key)
  end

  test "a lease within the stager margin of its end is lost, not renewed", %{key: key} do
    {:ok, claim} = StagedUploadClaim.claim(key)
    set_scheduled_at(key, DateTime.add(DateTime.utc_now(), 2))

    assert :lost = StagedUploadClaim.renew(claim)
  end

  test "renewal holds while the claim does, and is lost once the job moves on", %{key: key} do
    {:ok, claim} = StagedUploadClaim.claim(key)
    assert :ok = StagedUploadClaim.renew(claim)

    set_state(key, "available")
    assert :lost = StagedUploadClaim.renew(claim)
  end

  test "another claim's id renews nothing", %{key: key} do
    {:ok, claim} = StagedUploadClaim.claim(key)
    assert :lost = StagedUploadClaim.renew(%{claim | id: Ecto.UUID.generate()})
  end

  test "settling an unconsumed claim gives the token back", %{key: key, original: original} do
    {:ok, claim} = StagedUploadClaim.claim(key)
    assert :ok = StagedUploadClaim.settle(claim, false)

    job = job(key)
    assert job.meta == original.meta
    assert job.scheduled_at == original.scheduled_at
    assert {:ok, _claim} = StagedUploadClaim.claim(key)
  end

  test "settling a consumed claim keeps it and makes the job due", %{key: key} do
    {:ok, claim} = StagedUploadClaim.claim(key)
    assert :ok = StagedUploadClaim.settle(claim, true)

    job = job(key)
    assert job.meta["claim"] == claim.id
    assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) != :gt
    assert {:error, :not_uploaded} = StagedUploadClaim.claim(key)
  end

  test "settling a lost claim changes nothing", %{key: key} do
    {:ok, claim} = StagedUploadClaim.claim(key)
    set_state(key, "completed")
    before = job(key)

    assert :ok = StagedUploadClaim.settle(claim, false)
    assert job(key) == before
  end

  test "the heartbeat flags a lost claim and stops", %{key: key} do
    {:ok, claim} = StagedUploadClaim.claim(key)
    set_state(key, "available")

    heartbeat = %{pid: pid} = start_heartbeat(claim, 20)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    assert StagedUploadClaim.lost?(heartbeat)
    assert :ok = StagedUploadClaim.stop_heartbeat(heartbeat)
  end

  test "a stopped heartbeat was never lost", %{key: key} do
    {:ok, claim} = StagedUploadClaim.claim(key)
    heartbeat = start_heartbeat(claim, 60_000)

    assert :ok = StagedUploadClaim.stop_heartbeat(heartbeat)
    refute Process.alive?(heartbeat.pid)
    refute StagedUploadClaim.lost?(heartbeat)
  end

  # The interval is read from the application env when the heartbeat starts.
  defp start_heartbeat(claim, interval) do
    Application.put_env(:kiln_cms, StagedUploadClaim, heartbeat_ms: interval)

    try do
      StagedUploadClaim.start_heartbeat(claim)
    after
      Application.delete_env(:kiln_cms, StagedUploadClaim)
    end
  end

  @tag :capture_log
  test "the cleanup can't be queued: schedule says so instead of :ok" do
    assert {:error, %Ecto.Changeset{}} =
             StagedUploadCleanup.schedule("direct-uploads/x", :not_a_schedule)
  end
end
