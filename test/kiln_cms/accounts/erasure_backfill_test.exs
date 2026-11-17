defmodule KilnCMS.Accounts.ErasureBackfillTest do
  @moduledoc """
  `KilnCMS.Accounts.ErasureBackfill` gives an account erased by an earlier
  release the erasure steps added since: today, deleting its linked newsletter
  subscriptions (#2991), which erasure used to leave mailing the real address.
  """
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.ErasureBackfill
  alias KilnCMS.Accounts.User
  alias KilnCMS.Newsletter

  defp user(attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "erasure-backfill-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :viewer
        },
        attrs
      )
    )
  end

  # An account erased before #2991: tombstoned, its subscriber rows left in
  # place, still linked and confirmed at the address it was erased from.
  defp pre_fix_tombstone do
    user = user()
    rows = [link(user, Accounts.default_org_id()), link(user, org("erasure-backfill").id)]

    tombstone =
      Ash.Seed.update!(user, %{
        email: "anonymized-#{user.id}@deleted.invalid",
        name: nil,
        anonymized_at: DateTime.utc_now()
      })

    {tombstone, rows}
  end

  defp link(user, org_id) do
    opts = [authorize?: false, tenant: org_id]

    user.id
    |> Newsletter.link_member_subscriber!(%{email: to_string(user.email)}, opts)
    |> Newsletter.confirm_subscriber!(opts)
  end

  defp exists?(subscriber) do
    Newsletter.get_subscriber(subscriber.id,
      authorize?: false,
      tenant: subscriber.org_id,
      not_found_error?: false
    ) != {:ok, nil}
  end

  test "deletes an erased account's linked rows and leaves a live account's alone" do
    {_tombstone, rows} = pre_fix_tombstone()
    live = link(user(), Accounts.default_org_id())

    assert ErasureBackfill.run() == %{
             newsletter_accounts: 1,
             newsletter_subscribers: 2,
             failed: 0
           }

    refute Enum.any?(rows, &exists?/1)
    assert exists?(live)
  end

  test "a second run finds nothing to do" do
    pre_fix_tombstone()

    assert %{newsletter_accounts: 1} = ErasureBackfill.run()

    assert ErasureBackfill.run() == %{
             newsletter_accounts: 0,
             newsletter_subscribers: 0,
             failed: 0
           }
  end

  test "the job runs the pass" do
    {_tombstone, rows} = pre_fix_tombstone()

    assert :ok = perform_job(ErasureBackfill, %{})
    refute Enum.any?(rows, &exists?/1)
  end

  test "enqueue/0 queues one job however often a node boots" do
    assert :ok = ErasureBackfill.enqueue()
    assert :ok = ErasureBackfill.enqueue()

    assert [_one] = all_enqueued(worker: ErasureBackfill)
  end

  test "the test build does not enqueue it on boot" do
    # A boot-time enqueue commits outside every sandbox (see config/test.exs).
    assert Application.get_env(:kiln_cms, :erasure_backfill_on_boot) == false
  end
end
