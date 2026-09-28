# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.



## Security

<a id="federation-runs-under-the-policies"></a>

- **Federation runs under the policies.** The inbox, the publish fan-out, the
  delivery worker, the replay-nonce store and its sweeper, and
  `mix kiln.federation` reached `Follower`, `Delivery`, `Block`,
  `SiteFederation` and `SeenSignature` through `authorize?: false`, which skips
  every policy on the resource. They now run as `KilnCMS.SystemActor`, and
  each resource admits it for exactly what it needs: the follower list in full,
  the delivery ledger's `create`/`settle` (not its prune), the block list's
  reads (not its writes), the site settings' read, delivery stamp and the
  operator's `enable`/`disable`/`rekey` (not the settings form), and the nonce
  store's `record`/`expired`/`destroy` (not a plain read). `KilnCMS.CMS.OrgSettings`
  gains a `system_actions:` option that narrows the grant inside the macro's
  policies. The `mix kiln.authz.check` backlog drops by 24 sites and five files.

  Two of those reads used to fail **open**, and now fail closed whatever the
  grants say. The replay-nonce write logged and accepted on the date window
  when the store refused or failed it; the inbox now answers such a delivery
  `503` with `Retry-After: 60`, so an honest sender retries it and a replay is
  never accepted unrecorded. And the inbox's follower-ceiling count, which a
  refused read would have answered with 0, is preceded by a one-row read with
  `authorize_with: :error`; a refusal or a failed count is treated as "at the
  ceiling", and the follow is refused and logged. Honest senders see no
  difference unless the nonce store is down. (#1659)
