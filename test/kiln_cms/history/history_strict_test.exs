defmodule KilnCMS.History.StrictTenancyTest do
  @moduledoc """
  The History API under strict tenancy (#419, the production default), where a
  tenant-less read of `DocumentEvent` is refused outright.

  `History.record/5`'s sequence read used to run with no tenant at all, so on
  a strict build every append raised `TenantRequired` before it was written
  (#1659 moved it under the document's own org). The main suite compiles
  fail-open and cannot see that, so this runs on the strict CI leg only.
  """
  use KilnCMS.DataCase, async: true

  @moduletag :strict_tenancy

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.History

  test "record/5 and replay/3 work under the document's own org" do
    org_id = org("history-strict").id
    id = Ash.UUID.generate()

    assert {:ok, %{seq: 1}} =
             History.record(:page, id, :snapshot, %{"blocks" => [%{"id" => "a"}]}, org_id: org_id)

    assert {:ok, %{seq: 2}} =
             History.record(:page, id, :block_added, %{"block" => %{"id" => "b"}, "index" => 1},
               org_id: org_id
             )

    assert ["a", "b"] == Enum.map(History.replay(:page, id, org_id: org_id), & &1["id"])
  end

  test "the erasure sweep runs org by org" do
    org_id = org("history-strict-erase").id
    id = Ash.UUID.generate()
    erased = Ash.UUID.generate()

    {:ok, _} =
      History.record(:page, id, :snapshot, %{"blocks" => []}, org_id: org_id, actor_id: erased)

    assert :ok = History.anonymize_actor(erased)

    assert [%{actor_id: nil}] =
             History.events_for!(:page, id, actor: History.system(), tenant: org_id)
  end
end
