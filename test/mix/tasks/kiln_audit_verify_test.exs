defmodule Mix.Tasks.Kiln.Audit.VerifyTest do
  @moduledoc """
  `mix kiln.audit.verify` output (#356), particularly the #1058 annotation
  that flags a TAMPERED line as possibly the pre-#598 false-tamper bug rather
  than genuine tampering.
  """
  use KilnCMS.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureIO

  alias KilnCMS.CMS
  alias KilnCMS.Governance.Chain
  alias Mix.Tasks.Kiln.Audit.Verify

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "audit-verify-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "audit-verify-#{System.unique_integer([:positive])}"

  defp doctor_content!(post) do
    KilnCMS.Repo.update_all(
      from(v in "posts_versions",
        where: v.version_source_id == type(^post.id, :binary_id),
        update: [set: [changes: type(^%{"title" => "Doctored"}, :map)]]
      ),
      []
    )
  end

  defp downgrade_to_legacy_anchor!(post) do
    org = KilnCMS.Accounts.default_org_id()
    [anchor] = Chain.anchors("post", post.id, org)

    KilnCMS.Repo.update_all(
      from(a in "history_anchors", where: a.id == type(^anchor.id, :binary_id)),
      set: [payload_version: nil]
    )
  end

  # `Verify.run/1` calls `exit({:shutdown, 1})` on any failure. That is a
  # same-process exit (not an EXIT signal from a linked process), so it can be
  # caught with a plain `try/catch` right here without tearing the test down —
  # no separate process or monitor needed. Both output streams are captured:
  # `Mix.shell().info/1` writes to :stdio, `Mix.shell().error/1` to :stderr,
  # and the TAMPERED lines this module cares about go through `.info/1`.
  defp run_verify do
    stdout_ref = make_ref()

    stderr =
      capture_io(:stderr, fn ->
        stdout =
          capture_io(fn ->
            try do
              Verify.run([])
            catch
              :exit, _reason -> :ok
            end
          end)

        send(self(), {stdout_ref, stdout})
      end)

    receive do
      {^stdout_ref, stdout} -> stdout <> stderr
    after
      0 -> stderr
    end
  end

  test "a healthy (all-v6) chain has no legacy annotation" do
    admin = admin()
    post = CMS.create_post!(%{title: "Healthy", slug: slug()}, actor: admin)
    CMS.publish_post!(post, %{}, actor: admin)

    output = run_verify()

    # No signing key is configured in the test environment, so a fresh
    # publish reads "intact (unsigned)" rather than "VERIFIED" — either way,
    # the point here is that it never comes with a legacy note or the word
    # TAMPERED.
    assert output =~ "intact (unsigned)"
    refute output =~ "TAMPERED"
    refute output =~ "fold-order fix"
  end

  test "a TAMPERED chain that predates the #598 fold-order fix is annotated" do
    admin = admin()
    post = CMS.create_post!(%{title: "Legacy", slug: slug()}, actor: admin)
    CMS.publish_post!(post, %{}, actor: admin)

    downgrade_to_legacy_anchor!(post)
    doctor_content!(post)

    output = run_verify()

    assert output =~ "TAMPERED"

    assert output =~
             "(chain predates the #598 fold-order fix — this may be the ordering bug " <>
               "rather than tampering; see #1058)"

    # The aggregate triage line: some fixture content elsewhere in the suite
    # could in principle also be anchored, so this only pins the shape, not an
    # exact count. Deliberately does NOT restate "TAMPERED" (#1058) — a script
    # grepping stdout for that word should not double-count this line on top
    # of the per-document line it summarizes.
    assert output =~ ~r/[1-9]\d* of [1-9]\d* failing document\(s\) predate the #598/
  end

  test "an ordinary TAMPERED chain (no legacy anchor) is NOT annotated" do
    admin = admin()
    post = CMS.create_post!(%{title: "Genuine", slug: slug()}, actor: admin)
    CMS.publish_post!(post, %{}, actor: admin)

    doctor_content!(post)

    output = run_verify()

    assert output =~ "TAMPERED"
    refute output =~ "fold-order fix"
  end
end
