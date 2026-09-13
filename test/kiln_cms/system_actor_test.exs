defmodule KilnCMS.SystemActorTest do
  @moduledoc """
  The system actor and the policy check that admits it (#1402).

  Two things are pinned here, and both are load-bearing:

    * `KilnCMS.Checks.SystemActor` matches the system actor and **nothing
      else** — a plain map that happens to look like one does not pass;
    * the actor resolves to *no* tier and *no* audience, so it cannot pick up
      a grant through a role/audience check written for people. Every grant it
      ever gets has to be a `Checks.SystemActor` clause someone typed.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.Checks.SystemActor, as: Check
  alias KilnCMS.SystemActor

  defp context, do: %{subject: nil, resource: KilnCMS.Firing.ReferenceEdge, action: nil}

  describe "new/1" do
    test "labels the actor with its subsystem" do
      assert SystemActor.new(:firing) == %SystemActor{subsystem: :firing}
    end

    test "an actor cannot exist without a subsystem label" do
      # `@enforce_keys` is what makes the provenance non-optional: a bare
      # `%SystemActor{}` would authorize exactly the same and say nothing
      # about who ran it.
      assert_raise ArgumentError, fn -> struct!(SystemActor, %{}) end
    end

    test "carries no :id and no :role" do
      # Load-bearing: `Scoping.affiliation/2` keys off `:id` and
      # `effective_tier/2` off `:role`. An actor with either could be admitted
      # by a check meant for people.
      refute Map.has_key?(SystemActor.new(:firing), :id)
      refute Map.has_key?(SystemActor.new(:firing), :role)
    end
  end

  describe "Checks.SystemActor" do
    test "matches a system actor" do
      assert Check.match?(SystemActor.new(:firing), context(), [])
    end

    test "matches whatever the subsystem label says" do
      assert Check.match?(SystemActor.new(:billing), context(), [])
    end

    test "does not match an absent actor" do
      refute Check.match?(nil, context(), [])
    end

    test "does not match a user" do
      user =
        Ash.Seed.seed!(KilnCMS.Accounts.User, %{
          email: "system-actor-check@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          role: :admin
        })

      refute Check.match?(user, context(), [])
    end

    test "does not match a bare map shaped like one" do
      refute Check.match?(%{subsystem: :firing}, context(), [])
    end
  end

  describe "the actor resolves to nothing on the people axes" do
    test "has no effective tier anywhere" do
      assert Scoping.effective_tier(SystemActor.new(:firing), nil) == :none
    end

    test "holds no audiences" do
      assert Scoping.audiences(SystemActor.new(:firing), nil) == []
    end
  end
end
