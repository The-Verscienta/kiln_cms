defmodule KilnCMS.Keys.Reencrypt do
  @moduledoc """
  Move every `KilnCMS.Keys.Vault` column from an old `secret_key_base` to the
  current one (#1487) — what makes rotating `SECRET_KEY_BASE` recoverable
  instead of destructive.

  Run by `mix kiln.vault.reencrypt` and, in a release (which has no Mix), by
  `KilnCMS.Release.reencrypt_vault/1`. See `docs/secrets-rotation.md` for the
  procedure around it.

  ## What it does to each stored value

    * **current** — already opens with the current secret. Left alone, which is
      what makes a second run a no-op.
    * **rotated** — opens with an old secret. Decrypted and written back under
      the current one.
    * **unreadable** — opens with neither. Reported by id and **never
      written**: overwriting ciphertext nobody can read today destroys the one
      copy that the right old secret could still recover.

  ## How it walks

  The columns come from `KilnCMS.Keys.Vault.encrypted_attributes/0` — every
  attribute of type `KilnCMS.Keys.Vault.Ciphertext` — never from a list here.

  One transaction per resource, reading its rows `FOR UPDATE`, so a write the
  application makes to the same row mid-walk waits for this transaction rather
  than being overwritten with ciphertext re-encrypted from a stale copy.

  It goes to the table through Ecto rather than through an Ash action, on
  purpose: re-encryption changes how a value is stored, not what it is, so no
  change, notifier, paper trail or `updated_at` should see it — and it has to
  cross every tenant, which an action scoped to one org cannot.
  """

  import Ecto.Query, only: [from: 2]

  alias KilnCMS.Keys.Vault

  @typedoc "What one run found in one column."
  @type column_report :: %{
          resource: module(),
          table: String.t(),
          column: String.t(),
          current: non_neg_integer(),
          rotated: non_neg_integer(),
          empty: non_neg_integer(),
          unreadable: [String.t()]
        }

  @doc """
  Walk every vault column.

  Options:

    * `:old_secret_key_bases` — the secrets to try after the current one.
      Defaults to `KilnCMS.Keys.Vault.previous_secret_key_bases/0`, i.e.
      `PREVIOUS_SECRET_KEY_BASE`. With none, the walk still runs, as a check
      that everything opens under the current secret.
    * `:dry_run` — classify, write nothing.
    * `:repo` — defaults to `KilnCMS.Repo`.
  """
  @spec run(keyword()) :: [column_report()]
  def run(opts \\ []) do
    old = Keyword.get_lazy(opts, :old_secret_key_bases, &Vault.previous_secret_key_bases/0)
    current = Vault.secret_key_base()
    # A copy of the current secret among the old ones would "rotate" nothing
    # and only cost a second decrypt per row.
    old = Enum.reject(old, &(&1 == current))
    dry_run? = Keyword.get(opts, :dry_run, false)
    repo = Keyword.get(opts, :repo, KilnCMS.Repo)

    Vault.encrypted_attributes()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort()
    |> Enum.flat_map(fn {resource, attributes} ->
      walk(repo, resource, attributes, current, old, dry_run?)
    end)
  end

  @doc """
  The old secrets a run should try: those in the environment variable **named**
  `var`, or, for `nil`, `KilnCMS.Keys.Vault.previous_secret_key_bases/0`.

  Named rather than passed: a secret on the command line lands in shell
  history and in `ps` for every user on the host.
  """
  @spec old_secrets(String.t() | nil) :: {:ok, [String.t()]} | {:error, String.t()}
  def old_secrets(nil), do: {:ok, Vault.previous_secret_key_bases()}

  def old_secrets(var) when is_binary(var) do
    case System.get_env(var) do
      nil -> {:error, "#{var} is not set"}
      value -> if String.trim(value) == "", do: {:error, "#{var} is blank"}, else: {:ok, [value]}
    end
  end

  @doc """
  `run/1` for an operator: resolve the old secret (`:old_secret_key_base_env`,
  see `old_secrets/1`), walk (`:dry_run`), and print the report through `puts`.
  The mix task and `KilnCMS.Release.reencrypt_vault/1` are both this.

  `{:error, message}` when the old secret cannot be resolved, or when any value
  opened under no secret the run was given — those are left untouched, and an
  operator about to retire the old secret needs to hear it.
  """
  @spec run_and_report(keyword(), (String.t() -> any())) :: :ok | {:error, String.t()}
  def run_and_report(opts, puts) when is_function(puts, 1) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    with {:ok, old} <- old_secrets(Keyword.get(opts, :old_secret_key_base_env)) do
      if old == [] do
        puts.(
          "No old secret given (PREVIOUS_SECRET_KEY_BASE unset, no old-secret variable " <>
            "named): checking that every value opens under the current SECRET_KEY_BASE."
        )
      end

      reports = run(dry_run: dry_run?, old_secret_key_bases: old)
      Enum.each(format(reports, dry_run?), puts)

      case reports |> Enum.map(&length(&1.unreadable)) |> Enum.sum() do
        0 ->
          :ok

        count ->
          {:error,
           "#{count} value(s) open under no secret this run was given and were left " <>
             "untouched. Re-run with the right old secret, or re-create them in the app " <>
             "(see docs/secrets-rotation.md)."}
      end
    end
  end

  defp format(reports, dry_run?) do
    verb = if dry_run?, do: "would re-encrypt", else: "re-encrypted"

    column_lines =
      Enum.map(reports, fn r ->
        "#{r.table}.#{r.column}: #{r.rotated} #{verb}, #{r.current} already current, " <>
          "#{r.empty} empty, #{length(r.unreadable)} unreadable"
      end)

    unreadable_lines =
      for r <- reports, id <- r.unreadable do
        "  unreadable: #{r.table}.#{r.column} id=#{id}"
      end

    column_lines ++ unreadable_lines
  end

  # ── one resource ────────────────────────────────────────────────────────────

  # `walk` is everything one table's walk needs: where the rows are, and the
  # run's secrets and mode.
  defp walk(repo, resource, attributes, current, old, dry_run?) do
    walk = %{
      repo: repo,
      table: AshPostgres.DataLayer.Info.table(resource),
      prefix: AshPostgres.DataLayer.Info.schema(resource),
      pk: primary_key_column(resource),
      current: current,
      old: old,
      dry_run?: dry_run?
    }

    columns = Enum.map(attributes, &column(resource, &1))

    {:ok, reports} =
      repo.transaction(fn ->
        rows = rows(walk, columns)

        Enum.map(columns, fn column ->
          walk
          |> walk_column(column, rows)
          |> Map.merge(%{resource: resource, table: walk.table, column: to_string(column)})
        end)
      end)

    reports
  end

  defp walk_column(walk, column, rows) do
    rows
    |> Enum.reduce(
      %{current: 0, rotated: 0, empty: 0, unreadable: []},
      &tally(walk, column, &1, &2)
    )
    |> Map.update!(:unreadable, &Enum.reverse/1)
  end

  defp tally(walk, column, row, acc) do
    id = Map.fetch!(row, walk.pk)

    case classify(Map.fetch!(row, column), walk.current, walk.old) do
      {:rotate, plaintext} ->
        if not walk.dry_run?, do: write(walk, column, id, plaintext)
        Map.update!(acc, :rotated, &(&1 + 1))

      :unreadable ->
        Map.update!(acc, :unreadable, &[id_string(id) | &1])

      counted when counted in [:empty, :current] ->
        Map.update!(acc, counted, &(&1 + 1))
    end
  end

  defp classify(nil, _current, _old), do: :empty

  defp classify(ciphertext, current, old) do
    case Vault.decrypt(ciphertext, current) do
      {:ok, _plaintext} -> :current
      {:error, :decrypt_failed} -> open_with_old(ciphertext, old)
    end
  end

  defp open_with_old(ciphertext, old) do
    Enum.find_value(old, :unreadable, fn secret ->
      case Vault.decrypt(ciphertext, secret) do
        {:ok, plaintext} -> {:rotate, plaintext}
        {:error, :decrypt_failed} -> nil
      end
    end)
  end

  defp rows(walk, columns) do
    query = from(r in walk.table, select: map(r, ^[walk.pk | columns]))
    query = if walk.dry_run?, do: query, else: from(r in query, lock: "FOR UPDATE")

    walk.repo.all(query, prefix: walk.prefix)
  end

  defp write(walk, column, id, plaintext) do
    {1, _} =
      walk.repo.update_all(
        from(r in walk.table, where: field(r, ^walk.pk) == ^id),
        [set: [{column, Vault.encrypt(plaintext, walk.current)}]],
        prefix: walk.prefix
      )

    :ok
  end

  defp primary_key_column(resource) do
    case Ash.Resource.Info.primary_key(resource) do
      [key] ->
        column(resource, key)

      keys ->
        raise ArgumentError,
              "#{inspect(resource)} has a composite primary key #{inspect(keys)}; " <>
                "the vault re-encryption walk expects a single key column"
    end
  end

  defp column(resource, attribute) do
    %{source: source} = Ash.Resource.Info.attribute(resource, attribute)
    source
  end

  # A schemaless read returns a `uuid` column as its 16 raw bytes.
  defp id_string(<<_::128>> = raw), do: Ecto.UUID.load!(raw)
  defp id_string(other), do: to_string(other)
end
