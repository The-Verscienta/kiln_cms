defmodule KilnCMS.Automation.SystemActorAuthorizationTest do
  @moduledoc """
  The rule match (`Automation.dispatch/3`) reads the site's rules as
  `Automation.system/0` instead of `authorize?: false` (#1659), and fails
  CLOSED when that grant is gone: a refused read filters to "no rules", which
  would drop every automation for the event while the job reported success.
  """
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  import ExUnit.CaptureLog

  alias KilnCMS.Automation
  alias KilnCMS.Automation.{DispatchWorker, Rule, RuleWorker}
  alias KilnCMS.SystemActor

  defp rule! do
    Ash.Seed.seed!(Rule, %{
      name: "Rule #{System.unique_integer([:positive])}",
      enabled: true,
      config: %{},
      trigger_event: :published,
      action: :broadcast
    })
  end

  defp payload, do: %{"id" => Ash.UUID.generate(), "title" => "Hello", "slug" => "hello"}

  test "Automation.system/0 is a system actor labelled :automation" do
    assert %SystemActor{subsystem: :automation} = Automation.system()
  end

  test "with_actor/2 restores the real actor afterwards, even when the block raises" do
    assert_raise RuntimeError, fn -> Automation.with_actor(nil, fn -> raise "boom" end) end
    assert %SystemActor{subsystem: :automation} = Automation.system()
    assert Automation.with_actor(nil, &Automation.system/0) == nil
  end

  test "the system reads a rule but cannot author, edit or delete one" do
    rule = rule!()
    org = KilnCMS.Accounts.default_org_id()

    assert [%{id: id}] =
             Automation.rules_for!(:published, "post", actor: Automation.system(), tenant: org)
             |> Enum.filter(&(&1.id == rule.id))

    assert id == rule.id

    assert {:error, %Ash.Error.Forbidden{}} =
             Automation.update_rule(rule, %{name: "Hijacked"},
               actor: Automation.system(),
               tenant: org
             )

    assert {:error, %Ash.Error.Forbidden{}} =
             Automation.destroy_rule(rule, actor: Automation.system(), tenant: org)
  end

  test "a matching rule is dispatched as the system" do
    rule = rule!()

    assert :ok = Automation.dispatch("post.published", payload())
    assert_enqueued(worker: RuleWorker, args: %{"rule_id" => rule.id})
  end

  test "a refused rules read fails the job instead of dropping the rule" do
    rule = rule!()

    log =
      capture_log(fn ->
        assert {:error, %Ash.Error.Forbidden{}} =
                 Automation.with_actor(nil, fn ->
                   perform_job(DispatchWorker, %{
                     "event" => "post.published",
                     "payload" => payload(),
                     "org_id" => KilnCMS.Accounts.default_org_id()
                   })
                 end)
      end)

    assert log =~ "could not read the rules"
    refute_enqueued(worker: RuleWorker, args: %{"rule_id" => rule.id})
  end

  test "an event that is not a lifecycle trigger is still a quiet :ok, with no read" do
    assert :ok = Automation.with_actor(nil, fn -> Automation.dispatch("garbage", payload()) end)
    assert :ok = Automation.with_actor(nil, fn -> Automation.dispatch("x.nope", payload()) end)
  end
end
