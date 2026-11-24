defmodule KilnCMS.Beta.RoundAtomicityTest do
  @moduledoc """
  A new beta seat is seeded and then raised to its tier through
  `:manage_access` (#2641), in one transaction: when the grant fails, no
  account is left behind whose generated password nobody was ever handed.

  The grant is made to fail by a trigger on `security_events` that refuses its
  `role_granted` row, the audit event `:manage_access` writes inside the
  caller's transaction (here the seat's), so refusing it rolls the seed back
  too. Nothing in the round can be told to fail otherwise.

  Tagged `:table_lock` and **excluded from the normal run**: `CREATE TRIGGER`
  locks `security_events` until the sandbox transaction rolls back, and every
  other connection's write to the table queues behind it (see
  `test/test_helper.exs`). CI runs it in its own pass
  (`mix test --only table_lock`). The trigger rolls back with the sandbox.
  """
  use KilnCMS.DataCase, async: false

  @moduletag :table_lock
  @moduletag :capture_log

  alias KilnCMS.Accounts
  alias KilnCMS.Beta.Round
  alias KilnCMS.Repo

  setup do
    Repo.query!("""
    CREATE FUNCTION pg_temp.refuse_role_granted() RETURNS trigger AS $$
    BEGIN
      IF NEW.type = 'role_granted' THEN
        RAISE EXCEPTION 'role_granted refused by the test';
      END IF;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER refuse_role_granted BEFORE INSERT ON security_events
    FOR EACH ROW EXECUTE FUNCTION pg_temp.refuse_role_granted()
    """)

    :ok
  end

  test "a failed grant leaves no account behind" do
    round = "t#{System.unique_integer([:positive])}"
    email = "beta-r#{round}-t1@beta.kiln.test"

    assert_raise Ash.Error.Unknown, ~r/role_granted refused by the test/, fn ->
      Round.provision_seats(round: round, testers: 1, facilitator_email: "f-#{round}@x.test")
    end

    for address <- [email, "f-#{round}@x.test"] do
      assert {:ok, nil} =
               Accounts.get_user_by_email(address, not_found_error?: false, authorize?: false)
    end
  end
end
