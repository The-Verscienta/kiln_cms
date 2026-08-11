# Measures what periodic socket re-authorization (#775) actually costs, so the
# interval in `KilnCMSWeb.SocketReauth` comes from a number rather than from a
# round one.
#
#     MIX_ENV=dev mix run priv/bench/socket_reauth.exs
#
# Three things are timed, against a throwaway org/user/page this script creates
# and then purges:
#
#   * `reload_actor` — the one query that makes the check mean anything;
#   * `authorize` — the content-type lookup, the document read and
#     `Ash.can?({record, :autosave})`, i.e. exactly what `CollabChannel.join/3`
#     runs, so the re-check and the join cost the same by construction;
#   * `apply_update` — the CRDT work the room already does *per inbound
#     message*, which is the thing the check has to be cheap relative to.
#
# The number that actually sizes the interval is in the summary: queries per
# second added across the deployment at `Crdt.max_documents/0` open documents.
# One room's CPU was never the constraint.

require Logger
Logger.configure(level: :warning)

alias KilnCMS.CMS
alias KilnCMS.CMS.ContentTypes
alias KilnCMS.Collab.Crdt
alias KilnCMSWeb.SocketReauth

iterations = String.to_integer(System.get_env("BENCH_N") || "200")
peers = String.to_integer(System.get_env("BENCH_PEERS") || "5")

org = KilnCMS.Accounts.Organization |> Ash.read!(authorize?: false) |> hd()

actor =
  Ash.Seed.seed!(KilnCMS.Accounts.User, %{
    email: "bench-reauth-#{System.unique_integer([:positive])}@example.com",
    hashed_password: Bcrypt.hash_pwd_salt("password123456"),
    confirmed_at: DateTime.utc_now(),
    role: :admin
  })

page =
  CMS.create_page!(
    %{title: "Reauth bench", slug: "reauth-bench-#{System.unique_integer([:positive])}"},
    actor: actor,
    tenant: org
  )

# Mirrors `CollabChannel.authorize/3`. Kept here rather than reaching into the
# private function so the bench compiles against the public surface; if the two
# ever diverge, the bench is measuring the wrong thing and this comment is the
# place that says so.
authorize = fn actor ->
  ct = ContentTypes.get("page", org.id)
  record = ContentTypes.get_record!(ct.type, page.id, actor: actor, tenant: org)
  true = Ash.can?({record, :autosave}, actor, tenant: org)
end

# A Yjs update of the size a keystroke produces, for the apply_update baseline.
sample_update =
  (fn ->
     doc = Yex.Doc.new()
     text = Yex.Doc.get_text(doc, "block-bench")
     before = Yex.encode_state_vector!(doc)
     Yex.Text.insert(text, 0, "the quick brown fox")
     Yex.encode_state_as_update!(doc, before)
   end).()

time = fn label, fun ->
  fun.()

  {us, _} = :timer.tc(fn -> Enum.each(1..iterations, fn _ -> fun.() end) end)
  per_call = us / iterations / 1000
  IO.puts("  #{String.pad_trailing(label, 28)} #{:erlang.float_to_binary(per_call, decimals: 3)} ms")
  per_call
end

IO.puts("\n#{iterations} iterations each\n")

reload_ms = time.("reload_actor", fn -> {:ok, _} = SocketReauth.reload_actor(actor) end)
authorize_ms = time.("authorize (read + can?)", fn -> authorize.(actor) end)

check_ms =
  time.("full check", fn ->
    {:ok, fresh} = SocketReauth.reload_actor(actor)
    authorize.(fresh)
  end)

{:ok, server} = Crdt.ensure_server("collab:page:#{page.id}", org.id)
apply_ms = time.("Crdt.apply_update", fn -> :ok = Crdt.apply_update(server, sample_update) end)

interval_s = SocketReauth.interval_ms() / 1000
max_docs = Crdt.max_documents()
channels = max_docs * peers
queries_per_check = 3
qps = channels * queries_per_check / interval_s
busy_s = channels * check_ms / 1000 / interval_s

IO.puts("""

  ── sizing the interval ───────────────────────────────────────────────
  check / apply_update            #{Float.round(check_ms / apply_ms, 1)}x
  interval                        #{interval_s}s
  ceiling (#{max_docs} docs x #{peers} peers)     #{channels} channels
  added queries                   #{Float.round(qps, 1)}/s
  connection-seconds per second   #{Float.round(busy_s, 3)}
  (reload #{Float.round(reload_ms, 3)} ms + authorize #{Float.round(authorize_ms, 3)} ms)
""")

Ash.destroy!(page, action: :purge, actor: actor, tenant: org, authorize?: false)

# `User` has no destroy action (accounts are anonymized, not deleted), so the
# throwaway account goes out the way it came in — under the repo, not the domain.
{:ok, uuid} = Ecto.UUID.dump(actor.id)
KilnCMS.Repo.query!("DELETE FROM users WHERE id = $1", [uuid])
