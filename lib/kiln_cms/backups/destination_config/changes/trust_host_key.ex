defmodule KilnCMS.Backups.DestinationConfig.Changes.TrustHostKey do
  @moduledoc """
  `:trust_host_key` (#2222, ADR 0079): the host key a platform admin
  confirmed for an SFTP destination, stored in `host_key` as
  `%{"algorithm", "fingerprint", "how", "trusted_at"}`.

    * only an SFTP destination has one;
    * the type is one Kiln trusts (`Sftp.HostKey.types/0`) and the
      fingerprint an OpenSSH SHA-256 one;
    * `how` says whether the admin trusted what a scan showed (`scanned`) or
      typed the fingerprint they expected (`entered`, which the server was
      scanned for too);
    * a compare-and-swap on the stored fingerprint: the write matches the
      row only while its fingerprint is still `previous_fingerprint`, the
      one the admin saw when the scan began (`nil` for none), so two admins
      trusting different keys at once can't overwrite each other unseen.
      A lost race is `Ash.Error.Changes.StaleRecord`.
  """
  use Ash.Resource.Change

  require Ash.Expr

  alias KilnCMS.Backups.Destination.Sftp.HostKey

  @impl true
  def change(changeset, _opts, _context) do
    algorithm = Ash.Changeset.get_argument(changeset, :algorithm)
    fingerprint = Ash.Changeset.get_argument(changeset, :fingerprint)
    how = Ash.Changeset.get_argument(changeset, :how)
    previous = Ash.Changeset.get_argument(changeset, :previous_fingerprint)

    cond do
      changeset.data.kind != "sftp" ->
        Ash.Changeset.add_error(changeset,
          field: :host_key,
          message: "only an SFTP destination has a host key"
        )

      algorithm not in HostKey.types() ->
        Ash.Changeset.add_error(changeset,
          field: :algorithm,
          message: "is not a host key type Kiln trusts"
        )

      not HostKey.fingerprint?(fingerprint) ->
        Ash.Changeset.add_error(changeset,
          field: :fingerprint,
          message: "must be a SHA256 fingerprint, as ssh-keygen -lf prints it"
        )

      true ->
        changeset
        |> Ash.Changeset.force_change_attribute(:host_key, %{
          "algorithm" => algorithm,
          "fingerprint" => fingerprint,
          "how" => Atom.to_string(how),
          "trusted_at" => DateTime.to_iso8601(DateTime.utc_now())
        })
        |> Ash.Changeset.filter(
          Ash.Expr.expr(
            fragment("(? ->> 'fingerprint') IS NOT DISTINCT FROM ?::text", host_key, ^previous)
          )
        )
    end
  end
end
