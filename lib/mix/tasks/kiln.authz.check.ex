defmodule Mix.Tasks.Kiln.Authz.Check do
  @moduledoc """
  Fails when a request-facing module bypasses Ash policies without saying why.

  `authorize?: false` skips *every* policy on the resource — including the
  ones a later PR adds, and including any policy declared below a `bypass`
  (`docs/policy-matrix.md`, "The system actor"). In a row-based multi-tenant
  system that makes each bypass a small piece of the authorization surface
  that no policy block documents. #1309 counted 563 of them; the ones that
  matter most are the ones on request paths, where the caller is a browser or
  an API client rather than a worker.

  This gate does not forbid the bypass — public delivery, pre-auth flows and
  system reads for display data all need it. It forbids an *unexplained* one:
  every `authorize?: false` under `lib/kiln_cms_web/` must sit next to a
  comment that names the bypass and says why it is safe (system read, tenant
  already scoped, action's own filter carries the grant, …). A reviewer then
  reads the reason instead of reconstructing it, and a fresh site cannot land
  by copy-paste alone.

  ## What counts as a justification

  A comment that mentions `authorize?` or `bypass`, placed on any of the 12
  lines above the call that carries the bypass, anywhere inside that call
  (a trailing comment, a comment between its options, or on its closing
  line). The window is measured from the call, not from the option: a long
  keyword list with `authorize?: false` at the bottom is still covered by the
  comment above its head.

  A comment serves **one** site. If another bypass call sits between the
  comment and the site — or the comment is inside another call — it belongs
  to that earlier site, and the later one needs its own. So a second
  `authorize?: false` pasted under a justified one is red until it says why
  it, too, is safe. (Two `authorize?: false` inside the *same* call share the
  call's comment.)

  The scan is AST-based, so the phrase inside a string, a `@moduledoc` or a
  comment is not a site — only the actual `authorize?: false` keyword is. A
  bypass spelled without the literal (`authorize?: flag`,
  `Keyword.put(opts, :authorize?, false)`) is not a site either; those need
  a reader, not this gate.

  ## Scope: all of `lib/`, with a shrinking backlog

  Every file under `lib/` is gated. A file that predates the system-actor
  migration and still carries unexplained bypasses has an entry in `@backlog`
  recording exactly how many — 129 files, 313 sites when this landed (#1402).

  That list is a **ratchet, not an exemption**:

    * a file with no entry must be clean, so new code is gated from the day it
      lands;
    * a listed file may not gain a site — the count is a ceiling;
    * a listed file that *loses* one fails too, with the number to write. An
      allowance nobody maintains stops being a ratchet, and the message says
      what to change.

  Nothing may be added to the backlog. Emptying it finishes #1402.

  Pass paths (files or directories) to scan something narrower; the backlog
  still applies, and entries for files the scan did not cover are left alone.

      mix kiln.authz.check
      mix kiln.authz.check lib/kiln_cms/billing.ex
  """
  @shortdoc "Fails on an unexplained `authorize?: false` anywhere in lib/"

  use Mix.Task

  @default_paths ["lib"]

  # Unexplained `authorize?: false` sites that predate the system-actor
  # migration, per file. A ratchet: counts may only go DOWN, and no entry may
  # be added. See "Scope" above; the tracking issue is #1402.
  @backlog %{
    "lib/kiln_cms/accounts.ex" => 3,
    "lib/kiln_cms/accounts/bootstrap.ex" => 2,
    "lib/kiln_cms/accounts/changes/anonymize_user.ex" => 4,
    "lib/kiln_cms/accounts/changes/evict_role_members.ex" => 1,
    "lib/kiln_cms/accounts/changes/register_with_sso.ex" => 2,
    "lib/kiln_cms/accounts/changes/reload_pending_totp_secret.ex" => 1,
    "lib/kiln_cms/accounts/pending_sign_in.ex" => 4,
    "lib/kiln_cms/accounts/scoping.ex" => 3,
    "lib/kiln_cms/accounts/second_factor.ex" => 1,
    "lib/kiln_cms/accounts/sign_in_alert.ex" => 1,
    "lib/kiln_cms/accounts/validations/role_belongs_to_org.ex" => 1,
    "lib/kiln_cms/accounts/web_authn.ex" => 4,
    "lib/kiln_cms/automation.ex" => 1,
    "lib/kiln_cms/beta/round.ex" => 6,
    "lib/kiln_cms/billing/changes/record_transition.ex" => 1,
    "lib/kiln_cms/billing/entitlements.ex" => 6,
    "lib/kiln_cms/billing/subscriptions.ex" => 1,
    "lib/kiln_cms/billing/webhook_worker.ex" => 5,
    "lib/kiln_cms/billing/webhooks.ex" => 4,
    "lib/kiln_cms/blocks/required_field_audit.ex" => 1,
    "lib/kiln_cms/branding.ex" => 1,
    "lib/kiln_cms/cms/changes/apply_custom_fields.ex" => 4,
    "lib/kiln_cms/cms/changes/auto_complete_tasks.ex" => 2,
    "lib/kiln_cms/cms/changes/bust_type_registry.ex" => 1,
    "lib/kiln_cms/cms/changes/cancel_pending_release_items.ex" => 1,
    "lib/kiln_cms/cms/changes/clear_published_version.ex" => 1,
    "lib/kiln_cms/cms/changes/coalesce_autosave_versions.ex" => 4,
    "lib/kiln_cms/cms/changes/fold_working_copy.ex" => 1,
    "lib/kiln_cms/cms/changes/hash_inline_scripts.ex" => 1,
    "lib/kiln_cms/cms/changes/notify_comment.ex" => 1,
    "lib/kiln_cms/cms/changes/notify_webhooks.ex" => 1,
    "lib/kiln_cms/cms/changes/record_published_version.ex" => 2,
    "lib/kiln_cms/cms/changes/record_slug_redirect.ex" => 1,
    "lib/kiln_cms/cms/changes/restore_version.ex" => 3,
    "lib/kiln_cms/cms/changes/route_to_block_thread.ex" => 1,
    "lib/kiln_cms/cms/changes/score_form_submission.ex" => 1,
    "lib/kiln_cms/cms/content.ex" => 1,
    "lib/kiln_cms/cms/content_types.ex" => 1,
    "lib/kiln_cms/cms/editorial_settings.ex" => 1,
    "lib/kiln_cms/cms/fragments.ex" => 1,
    "lib/kiln_cms/cms/health_summary.ex" => 2,
    "lib/kiln_cms/cms/menus.ex" => 4,
    "lib/kiln_cms/cms/name_fields.ex" => 1,
    "lib/kiln_cms/cms/preparations/custom_field_query.ex" => 5,
    "lib/kiln_cms/cms/promotion.ex" => 2,
    "lib/kiln_cms/cms/redirects.ex" => 2,
    "lib/kiln_cms/cms/release_preview.ex" => 1,
    "lib/kiln_cms/cms/releases.ex" => 2,
    "lib/kiln_cms/cms/slug_regeneration.ex" => 2,
    "lib/kiln_cms/cms/slugs.ex" => 9,
    "lib/kiln_cms/cms/starter_content.ex" => 1,
    "lib/kiln_cms/cms/task_settings.ex" => 1,
    "lib/kiln_cms/cms/validations/assignee_is_editor.ex" => 1,
    "lib/kiln_cms/cms/validations/media_alt_text.ex" => 1,
    "lib/kiln_cms/cms/validations/menu_item_placement.ex" => 2,
    "lib/kiln_cms/cms/validations/release_content_exists.ex" => 1,
    "lib/kiln_cms/cms/validations/release_open_for_edit.ex" => 1,
    "lib/kiln_cms/cms/validations/release_within_size_limit.ex" => 1,
    "lib/kiln_cms/cms/validations/required_consent.ex" => 1,
    "lib/kiln_cms/cms/validations/slug_pattern_tokens.ex" => 1,
    "lib/kiln_cms/cms/validations/tag_group_in_tenant.ex" => 1,
    "lib/kiln_cms/cms/workers/release_worker.ex" => 2,
    "lib/kiln_cms/cms/workers/slug_regeneration_worker.ex" => 1,
    "lib/kiln_cms/code_injection.ex" => 1,
    "lib/kiln_cms/collab/crdt/checkpoint.ex" => 3,
    "lib/kiln_cms/compliance/report.ex" => 2,
    "lib/kiln_cms/compliance/settings.ex" => 1,
    "lib/kiln_cms/events.ex" => 2,
    "lib/kiln_cms/experiments.ex" => 2,
    "lib/kiln_cms/experiments/changes/refuse_when_running.ex" => 1,
    "lib/kiln_cms/experiments/changes/require_variants.ex" => 2,
    "lib/kiln_cms/experiments/delivery.ex" => 2,
    "lib/kiln_cms/experiments/health.ex" => 2,
    "lib/kiln_cms/experiments/promotion.ex" => 1,
    "lib/kiln_cms/experiments/results.ex" => 1,
    "lib/kiln_cms/experiments/validations/goal_configured.ex" => 4,
    "lib/kiln_cms/federation.ex" => 5,
    "lib/kiln_cms/federation/announce_worker.ex" => 3,
    "lib/kiln_cms/federation/delivery_worker.ex" => 7,
    "lib/kiln_cms/federation/http_signature.ex" => 1,
    "lib/kiln_cms/federation/inbox.ex" => 5,
    "lib/kiln_cms/federation/seen_signature_sweeper.ex" => 2,
    "lib/kiln_cms/feeds.ex" => 1,
    "lib/kiln_cms/forms.ex" => 2,
    "lib/kiln_cms/forms/autoresponder.ex" => 1,
    "lib/kiln_cms/forms/autoresponder_worker.ex" => 2,
    "lib/kiln_cms/forms/embed_policy.ex" => 1,
    "lib/kiln_cms/forms/notification_worker.ex" => 1,
    "lib/kiln_cms/governance.ex" => 8,
    "lib/kiln_cms/governance/chain.ex" => 7,
    "lib/kiln_cms/governance/checkpoint.ex" => 8,
    "lib/kiln_cms/history.ex" => 5,
    "lib/kiln_cms/links/check_worker.ex" => 2,
    "lib/kiln_cms/links/internal.ex" => 1,
    "lib/kiln_cms/links/report.ex" => 2,
    "lib/kiln_cms/links/settings.ex" => 2,
    "lib/kiln_cms/links/sweep.ex" => 5,
    "lib/kiln_cms/mail.ex" => 4,
    "lib/kiln_cms/media/av_strip_worker.ex" => 3,
    "lib/kiln_cms/media/av_worker.ex" => 3,
    "lib/kiln_cms/media/quarantine_reaper.ex" => 2,
    "lib/kiln_cms/media/regeneration.ex" => 1,
    "lib/kiln_cms/media/variant_worker.ex" => 2,
    "lib/kiln_cms/newsletter.ex" => 2,
    "lib/kiln_cms/newsletter/mail_worker.ex" => 4,
    "lib/kiln_cms/newsletter/send_worker.ex" => 4,
    "lib/kiln_cms/notifications.ex" => 7,
    "lib/kiln_cms/notifications/task_digest_worker.ex" => 3,
    "lib/kiln_cms/notifications/task_mail_worker.ex" => 2,
    "lib/kiln_cms/notifications/tasks.ex" => 1,
    "lib/kiln_cms/oembed/resolve_worker.ex" => 3,
    "lib/kiln_cms/portability/cli.ex" => 3,
    "lib/kiln_cms/push.ex" => 3,
    "lib/kiln_cms/push/worker.ex" => 2,
    "lib/kiln_cms/schema_export.ex" => 2,
    "lib/kiln_cms/search.ex" => 3,
    "lib/kiln_cms/seo/links.ex" => 1,
    "lib/kiln_cms/social.ex" => 2,
    "lib/kiln_cms/social/announcer.ex" => 6,
    "lib/kiln_cms/staging/scrub.ex" => 1,
    "lib/kiln_cms/webhooks.ex" => 2,
    "lib/kiln_cms/webhooks/delivery_worker.ex" => 6,
    "lib/mix/tasks/kiln.audit.verify.ex" => 1,
    "lib/mix/tasks/kiln.embed_all.ex" => 2,
    "lib/mix/tasks/kiln.experiment.ex" => 7,
    "lib/mix/tasks/kiln.federation.ex" => 5,
    "lib/mix/tasks/kiln.gen.content.ex" => 2,
    "lib/mix/tasks/kiln.search.eval.ex" => 1,
    "lib/mix/tasks/kiln.search.measure_floor.ex" => 1
  }
  @window 12
  @justification ~r/authorize\?|bypass/i

  @impl Mix.Task
  def run(args) do
    paths = if args == [], do: @default_paths, else: args
    files = paths |> Enum.flat_map(&source_files/1) |> Enum.uniq() |> Enum.sort()

    sites = Map.new(files, fn path -> {path, path |> File.read!() |> unjustified(path)} end)
    counts = Map.new(sites, fn {path, lines} -> {path, length(lines)} end)

    case problems(counts) do
      [] ->
        Mix.shell().info(summary(paths, counts))

      problems ->
        shell = Mix.shell()
        Enum.each(problems, &shell.error/1)
        report_new_sites(shell, sites)
        Mix.raise(failure_message(length(problems)))
    end
  end

  @doc """
  The #1402 backlog: `%{path => allowed_unjustified_count}`.

  Exposed so the tests can check it stays honest — an entry naming a file that
  no longer exists can never be cleared by the ratchet, and would sit there
  looking like outstanding work that is already done.
  """
  @spec backlog() :: %{Path.t() => pos_integer()}
  def backlog, do: @backlog

  @doc """
  What is wrong with a `%{path => unjustified_count}` scan, as messages.

  Two kinds, and both fail the build:

    * a file with **more** unexplained bypasses than `backlog` allows — zero
      for anything not listed. This is the gate.
    * a backlog entry that is now too **generous**: the file was cleaned up and
      nobody lowered the number. An allowance nobody maintains is an exemption
      rather than a ratchet, so this fails too, with the number to write.

  Only entries for files the scan actually covered are judged, so scanning one
  file does not report every other file's entry as stale.

  Public because the tests drive it directly: a ratchet whose arithmetic is
  wrong in the permissive direction passes forever and nobody finds out.
  """
  @spec problems(%{Path.t() => non_neg_integer()}, %{Path.t() => pos_integer()}) :: [String.t()]
  def problems(counts, backlog \\ @backlog) do
    scanned = counts |> Map.keys() |> MapSet.new()

    regressions =
      for {path, count} <- Enum.sort(counts),
          allowed = Map.get(backlog, path, 0),
          count > allowed do
        "#{path}: #{count} unexplained `authorize?: false`, #{allowed} allowed" <>
          if allowed == 0, do: ".", else: " by the #1402 backlog."
      end

    stale =
      for {path, allowed} <- Enum.sort(backlog),
          MapSet.member?(scanned, path),
          count = Map.fetch!(counts, path),
          count < allowed do
        "#{path}: the #1402 backlog allows #{allowed} but the file has #{count} — " <>
          if count == 0,
            do: "drop the entry, which finishes this file.",
            else: "lower the number to #{count}."
      end

    regressions ++ stale
  end

  # The individual lines behind a regression, so a contributor sees WHERE
  # rather than only how many. Only for files over their allowance; a
  # backlogged file's existing sites are not news.
  defp report_new_sites(shell, sites) do
    for {path, lines} <- Enum.sort(sites),
        length(lines) > Map.get(@backlog, path, 0),
        {^path, line} <- lines do
      shell.error("#{path}:#{line}: `authorize?: false` without an adjacent justification")
    end
  end

  defp summary(paths, counts) do
    remaining =
      counts |> Map.keys() |> Enum.map(&Map.get(@backlog, &1, 0)) |> Enum.sum()

    scope = Enum.join(paths, ", ")

    if remaining == 0 do
      "Authz: every `authorize?: false` under #{scope} is justified."
    else
      files = Enum.count(counts, fn {path, _} -> Map.has_key?(@backlog, path) end)

      "Authz: no new unexplained `authorize?: false` under #{scope} " <>
        "(#{remaining} still in the #1402 backlog, across #{files} files)."
    end
  end

  defp failure_message(count) do
    """
    #{count} file(s) off the authz ratchet.

    `authorize?: false` skips every policy on the resource. Either pass an
    actor — the request's, or `KilnCMS.SystemActor.new/1` for worker and job
    code, which the resource's policies then admit by name — or add a comment
    within #{@window} lines above the call (or inside it) that names the bypass
    (mention `authorize?` or `bypass`) and says why it is safe: a tenant
    already scoped by the router, a delivery action whose own filter carries
    the grant, a pre-auth flow with no actor, ... One comment covers one call.

    The `@backlog` in this task is a ratchet over what predates the
    system-actor migration: counts may only go down, and no entry may be added.
    See #1309 and #1402.
    """
  end

  @doc """
  The `{path, line}` of every `authorize?: false` in `source` that has no
  adjacent justification comment. Exposed for tests: this is the part that
  would silently pass on a real bypass if it went wrong.
  """
  @spec unjustified(String.t(), Path.t()) :: [{Path.t(), pos_integer()}]
  def unjustified(source, path \\ "nofile") do
    case Code.string_to_quoted_with_comments(source,
           file: path,
           literal_encoder: &{:ok, {:__block__, &2, [&1]}},
           token_metadata: true
         ) do
      {:ok, ast, comments} ->
        justified = justified_lines(comments)
        sites = sites(ast)

        for site <- sites,
            not Enum.any?(justified, &serves?(&1, site, sites)),
            line <- site.lines,
            do: {path, line}

      {:error, {meta, message, token}} ->
        Mix.raise("#{path}:#{meta[:line]}: cannot parse: #{parse_error(message, token)}")
    end
  end

  # `Code.string_to_quoted` reports some errors as a `{prefix, suffix}` pair
  # around the offending token rather than a plain string.
  defp parse_error({prefix, suffix}, token), do: prefix <> token <> suffix
  defp parse_error(message, token) when is_binary(message), do: message <> token

  # Line numbers of every comment that reads as a justification.
  defp justified_lines(comments) do
    for %{line: line, text: text} <- comments,
        Regex.match?(@justification, text),
        do: line
  end

  # A comment on line `c` justifies `site` when it sits in the site's window
  # (`@window` lines above the call's head through its last line) and no
  # OTHER site claims it first: a bypass call that starts between the comment
  # and this one, or one whose span contains the comment, owns it.
  defp serves?(c, site, sites) do
    c in (site.start - @window)..site.stop and
      not Enum.any?(sites, fn other ->
        other != site and other.start < site.start and c <= other.stop
      end)
  end

  # Every bypass site: the call carrying one or more `authorize?: false`
  # options (`start` = the call's first line, `stop` = its closing line, or
  # the option's line when the call has no closing token), or the bare
  # option itself when it is not an argument of a call (`opts = [authorize?:
  # false]`). `lines` are the option lines, which is what gets reported.
  #
  # With the literal encoder every literal is wrapped in a `:__block__` node
  # carrying its line, so a keyword-list pair `authorize?: false` shows up as
  # `{{:__block__, meta, [:authorize?]}, {:__block__, _, [false]}}`.
  defp sites(ast) do
    {_, {calls, pairs}} =
      Macro.prewalk(ast, {[], []}, fn
        {{:__block__, meta, [:authorize?]}, {:__block__, _, [false]}} = node, {calls, pairs} ->
          {node, {calls, [Keyword.fetch!(meta, :line) | pairs]}}

        {_fun, meta, args} = node, {calls, pairs} when is_list(args) and is_list(meta) ->
          case {meta[:line], bypass_option_lines(args)} do
            {nil, _} -> {node, {calls, pairs}}
            {_, []} -> {node, {calls, pairs}}
            {line, lines} -> {node, {[{line, meta[:closing][:line], lines} | calls], pairs}}
          end

        node, acc ->
          {node, acc}
      end)

    covered = calls |> Enum.flat_map(fn {_, _, lines} -> lines end) |> MapSet.new()

    call_sites =
      for {start, closing, lines} <- calls do
        %{start: start, stop: closing || Enum.max(lines), lines: Enum.sort(lines)}
      end

    bare_sites =
      for line <- Enum.uniq(pairs), line not in covered do
        %{start: line, stop: line, lines: [line]}
      end

    Enum.sort_by(call_sites ++ bare_sites, & &1.start)
  end

  # The option lines of every `authorize?: false` that is a DIRECT option of
  # a call: an element of a keyword-list (or map) argument. Deeper matches
  # (inside a nested call, a `do` block, or a `fn`) belong to their own node.
  defp bypass_option_lines(args) do
    args
    |> Enum.flat_map(fn
      list when is_list(list) -> list
      {:%{}, _, list} when is_list(list) -> list
      _ -> []
    end)
    |> Enum.flat_map(fn
      {{:__block__, meta, [:authorize?]}, {:__block__, _, [false]}} ->
        [Keyword.fetch!(meta, :line)]

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp source_files(path) do
    cond do
      File.dir?(path) -> Path.wildcard(Path.join(path, "**/*.{ex,exs}"))
      File.exists?(path) -> [path]
      true -> Mix.raise("#{path}: no such file or directory")
    end
  end
end
