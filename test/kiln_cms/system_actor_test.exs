defmodule KilnCMS.SystemActorTest do
  @moduledoc """
  The system actor and the policy check that admits it (#1402).

  Two things are pinned here, and both are load-bearing:

    * `KilnCMS.Checks.SystemActor` matches a system actor whose subsystem the
      clause names (#1747) and **nothing else** — not another subsystem, and
      not a plain map that happens to look like one;
    * the actor resolves to *no* tier and *no* audience, so it cannot pick up
      a grant through a role/audience check written for people. Every grant it
      ever gets has to be a `Checks.SystemActor` clause someone typed.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.Checks.SystemActor, as: Check
  alias KilnCMS.SystemActor

  defp context, do: %{subject: nil, resource: KilnCMS.Firing.ReferenceEdge, action: nil}
  defp context(action), do: %{context() | action: %{name: action}}

  # The options as a resource's `authorize_if` hands them over, after `init/1`.
  defp opts(opts) do
    {:ok, opts} = Check.init(opts)
    opts
  end

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
    test "matches a system actor of a subsystem it names" do
      assert Check.match?(SystemActor.new(:firing), context(), opts(subsystem: :firing))

      assert Check.match?(
               SystemActor.new(:billing),
               context(),
               opts(subsystem: [:firing, :billing])
             )
    end

    test "does not match a system actor of any other subsystem" do
      refute Check.match?(SystemActor.new(:billing), context(), opts(subsystem: :firing))
      refute Check.match?(SystemActor.new(:automation), context(), opts(subsystem: [:firing]))
    end

    test "`action:` narrows the clause to the actions it names" do
      clause = opts(subsystem: :cms_bookkeeping, action: :complete)

      assert Check.match?(SystemActor.new(:cms_bookkeeping), context(:complete), clause)
      refute Check.match?(SystemActor.new(:cms_bookkeeping), context(:reopen), clause)
      refute Check.match?(SystemActor.new(:automation), context(:complete), clause)
      # No action to compare against is not a match.
      refute Check.match?(SystemActor.new(:cms_bookkeeping), context(), clause)
    end

    # The build-time half (#1747): `Ash.Policy.Check.transform/1` runs `init/1`
    # when the resource compiles, and a `{:error, _}` is a DslError there.
    test "a clause that names no subsystem does not initialize" do
      assert {:error, message} = Check.init([])
      assert message =~ "needs `subsystem:`"

      for bad <- [[], nil, true, "firing", [:firing, "billing"], [nil]] do
        assert {:error, _} = Check.init(subsystem: bad), "accepted subsystem: #{inspect(bad)}"
      end

      assert {:error, _} = Check.init(subsystem: :firing, action: [])
    end

    test "init/1 normalizes an atom to a sorted list" do
      assert {:ok, opts} = Check.init(subsystem: :firing, action: :upsert)
      assert opts[:subsystem] == [:firing]
      assert opts[:action] == [:upsert]

      assert {:ok, opts} = Check.init(subsystem: [:search, :firing, :search])
      assert opts[:subsystem] == [:firing, :search]
    end

    test "does not match an absent actor" do
      refute Check.match?(nil, context(), opts(subsystem: :firing))
    end

    test "does not match a user" do
      user =
        Ash.Seed.seed!(KilnCMS.Accounts.User, %{
          email: "system-actor-check@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          role: :admin
        })

      refute Check.match?(user, context(), opts(subsystem: :firing))
    end

    test "does not match a bare map shaped like one" do
      refute Check.match?(%{subsystem: :firing}, context(), opts(subsystem: :firing))
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
