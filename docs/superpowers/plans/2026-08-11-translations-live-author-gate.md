# TranslationsLive author gate (#1156) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hide the `+ Missing` create-translation chip on `TranslationsLive` for types the actor may not author, keep those coverage rows visible, and silently refuse forged create events.

**Architecture:** Annotate each coverage row with `may_author?` using the same `Scoping` question as `EditorLive` / `Checks.EditableContentType`. Gate the create button (and handler) on that flag; show a static missing chip when false.

**Tech Stack:** Phoenix LiveView, Ash policies via `KilnCMS.Accounts.Scoping`, ExUnit `Phoenix.LiveViewTest`

## Global Constraints

- Keep coverage rows for unauthorable types (decision A).
- Silent handler refusal (no error flash) when `may_author?` is false — match `ContentEditorLive`.
- Do not extract a shared `may_author?` helper in this PR.
- Do not change XLIFF export/import behavior.
- Dynamic types compare as `"entry"` for `editable_types` (same as `EditorLive.type_name_of/1`).
- Use domain code interfaces (`CMS.create_*!`, `Accounts.manage_user_access`) — never raw `Ash.create!` in tests.
- Every LiveView template change stays inside existing `Layouts.console`.

## File map

| File | Responsibility |
|------|----------------|
| `lib/kiln_cms_web/live/translations_live.ex` | `may_author?` helpers, row flag, template gate, handler refuse |
| `test/kiln_cms_web/live/translations_live_test.exs` | Scoped-editor UI + forged-event coverage |

---

### Task 1: Failing tests for the scoped-editor gate

**Files:**
- Modify: `test/kiln_cms_web/live/translations_live_test.exs`
- Test: `test/kiln_cms_web/live/translations_live_test.exs`

**Interfaces:**
- Consumes: existing `log_in/2`, `CMS.create_page!/2`, `CMS.create_post!/2`, `Accounts.manage_user_access/3`
- Produces: describe `"scoped editor (#1156)"` with three tests the implementation must pass

- [ ] **Step 1: Add helpers and the failing describe**

After the existing `@password` / `authed_admin` / `log_in` / `slug` helpers in `test/kiln_cms_web/live/translations_live_test.exs`, add an editor helper and a `manage_user_access` path (same shape as `duplicate_content_test.exs`). Then append this describe at the end of the module (before the final `end`):

```elixir
  defp authed_user(role) do
    email = "trl-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  # #1156. The coverage dashboard used to offer `+ Missing` on every row,
  # including types the actor may not author — a dead button whose only
  # outcome was the create-policy flash. Rows stay (read-only coverage);
  # the create chip and forged events must not.
  describe "scoped editor (#1156)" do
    setup %{conn: conn} do
      admin = authed_admin()

      page =
        CMS.create_page!(%{title: "Off-limits page", slug: slug(), locale: "en"}, actor: admin)

      post =
        CMS.create_post!(%{title: "In-scope post", slug: slug(), locale: "en"}, actor: admin)

      scoped = authed_user(:editor)

      {:ok, scoped} =
        KilnCMS.Accounts.manage_user_access(scoped, %{editable_types: ["post"]}, actor: admin)

      {:ok, lv, _html} = conn |> log_in(scoped) |> live(~p"/editor/translations")

      %{lv: lv, page: page, post: post, scoped: scoped, admin: admin}
    end

    test "keeps the unauthorable row but offers no create chip", %{lv: lv, page: page} do
      assert has_element?(lv, ~s(#row-page-#{page.id}))

      refute has_element?(
               lv,
               ~s(button[phx-click="create_translation"][phx-value-id="#{page.id}"])
             )
    end

    test "still offers create on types the editor may author", %{lv: lv, post: post} do
      assert has_element?(
               lv,
               ~s(button[phx-click="create_translation"][phx-value-id="#{post.id}"][phx-value-locale="fr"])
             )
    end

    test "a forged create_translation for an unauthored type is refused", %{
      lv: lv,
      page: page,
      scoped: scoped,
      admin: admin
    } do
      render_click(lv, "create_translation", %{
        "kind" => "page",
        "id" => page.id,
        "locale" => "fr"
      })

      refute has_element?(lv, "#flash-error")

      assert [] =
               CMS.list_pages!(
                 actor: admin,
                 query: [filter: [slug: page.slug, locale: "fr"]]
               )

      # Actor still cannot create either — the gate did not widen policy.
      assert [] =
               CMS.list_pages!(
                 actor: scoped,
                 query: [filter: [slug: page.slug, locale: "fr"]]
               )
    end
  end
```

Ensure `alias KilnCMS.Accounts.User` and `alias KilnCMS.CMS` remain at the top (already present).

- [ ] **Step 2: Run the new tests and confirm they fail**

Run:

```bash
export PATH="/opt/homebrew/bin:$PATH"
mix test test/kiln_cms_web/live/translations_live_test.exs --only line:REPLACE
```

Or run the whole file:

```bash
mix test test/kiln_cms_web/live/translations_live_test.exs
```

Expected: the two scoped-editor UI/handler tests fail — create buttons still present on the page row, and/or a forged click produces `#flash-error` / a translation row. The admin describe tests should still pass.

- [ ] **Step 3: Commit the failing tests**

```bash
git add test/kiln_cms_web/live/translations_live_test.exs
git commit -m "$(cat <<'EOF'
test: pin TranslationsLive create chip to editable_types (#1156)

Scoped editors must keep coverage rows but lose the dead + Missing
button; forged create_translation events must not flash or mint.
EOF
)"
```

---

### Task 2: Implement the author gate in `TranslationsLive`

**Files:**
- Modify: `lib/kiln_cms_web/live/translations_live.ex`
- Test: `test/kiln_cms_web/live/translations_live_test.exs`

**Interfaces:**
- Consumes: `KilnCMS.Accounts.Scoping.effective_tier/2`, `Scoping.permitted?/4`, `ContentTypes.get/2`
- Produces: `row.may_author?` boolean; gated button; silent handler refuse

- [ ] **Step 1: Alias Scoping and add helpers**

At the top of `lib/kiln_cms_web/live/translations_live.ex`, add:

```elixir
  alias KilnCMS.Accounts.Scoping
```

next to the existing `ContentTypes` / `Translations` aliases.

After the `@max_upload_bytes` module attribute (before `mount`), or just above `load_rows`, add the same helpers `EditorLive` uses:

```elixir
  # The same question the create policy asks (`Checks.EditableContentType`), so
  # the Missing chip and create_translation cannot disagree (#1156).
  defp may_author?(actor, org_id, content_type) do
    case Scoping.effective_tier(actor, org_id) do
      :admin ->
        true

      :editor ->
        Scoping.permitted?(actor, org_id, :editable_types, type_name_of(content_type))

      _ ->
        false
    end
  end

  # `editable_types` groups every dynamic type under `entry` (see
  # docs/granular-rbac.md) — deliberately, unlike field grants.
  defp type_name_of(%{source: :dynamic}), do: "entry"
  defp type_name_of(%{type: type}), do: to_string(type)
```

- [ ] **Step 2: Annotate each row with `may_author?`**

Change `load_rows/1` so `row/3` receives the author flag. Replace the `Enum.map` that builds rows:

```elixir
        |> Enum.map(fn {_slug, records} ->
          row(ct, records, default, may_author?(actor, org.id, ct))
        end)
```

And update `row/4`:

```elixir
  defp row(ct, records, default, may_author?) do
    by_locale = Map.new(records, &{&1.locale, &1})
    source = by_locale[default] || hd(records)

    cells =
      for locale <- I18n.locales() do
        variant = by_locale[locale]

        %{
          locale: locale,
          record: variant,
          status: if(variant, do: variant.state, else: :missing),
          stale?:
            variant != nil and locale != default and by_locale[default] != nil and
              DateTime.after?(by_locale[default].updated_at, variant.updated_at)
        }
      end

    %{
      kind: ct.type,
      label: ct.label,
      source: source,
      title: source.title,
      updated_at: records |> Enum.map(& &1.updated_at) |> Enum.max(DateTime),
      cells: cells,
      may_author?: may_author?
    }
  end
```

- [ ] **Step 3: Gate the template chip**

Replace the missing-cell `<button>` block in `render/1` with:

```heex
                  <button
                    :if={is_nil(cell.record) and row.may_author?}
                    type="button"
                    phx-click="create_translation"
                    phx-value-kind={row.kind}
                    phx-value-id={row.source.id}
                    phx-value-locale={cell.locale}
                    class={[
                      "rounded border px-2 py-0.5 text-xs hover:bg-base-200",
                      chip_class(:missing)
                    ]}
                  >
                    + {status_label(:missing)}
                  </button>
                  <span
                    :if={is_nil(cell.record) and not row.may_author?}
                    class={[
                      "inline-flex items-center rounded border px-2 py-0.5 text-xs",
                      chip_class(:missing)
                    ]}
                  >
                    {status_label(:missing)}
                  </span>
```

- [ ] **Step 4: Refuse in the handler before create**

Replace the body of `handle_event("create_translation", …)` (keep the rescue clauses) with:

```elixir
  def handle_event(
        "create_translation",
        %{"kind" => kind, "id" => id, "locale" => locale},
        socket
      )
      when is_binary(kind) and is_binary(id) and is_binary(locale) do
    actor = socket.assigns.current_user
    org = socket.assigns.current_org

    # Hidden button is not the boundary — a forged event lands here regardless
    # (#922 / #1156). Match ContentEditorLive: silent refuse, no error flash.
    case ContentTypes.get(kind, org) do
      ct when not is_nil(ct) ->
        if may_author?(actor, org.id, ct) do
          source = ContentTypes.get_record!(kind, id, actor: actor, tenant: org)

          {translation, withheld} =
            Translations.create_translation_with_notes!(kind, source, locale,
              actor: actor,
              tenant: org
            )

          {:noreply,
           socket
           |> put_flash(:info, translation_flash(locale, withheld))
           |> push_navigate(to: ~p"/editor/content/#{kind}/#{translation.id}")}
        else
          {:noreply, socket}
        end

      nil ->
        {:noreply, socket}
    end
  rescue
    _error in KilnCMS.CMS.Translations.BlocksWithheldError ->
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext("Your role cannot copy this content's blocks, so it cannot be translated.")
       )}

    _error ->
      {:noreply, put_flash(socket, :error, gettext("Couldn't create that translation."))}
  end
```

Optionally tighten the page blurb under the H1 so it does not imply every missing chip creates — only if the existing copy is now misleading. Prefer leaving copy alone unless tests/docs require it.

- [ ] **Step 5: Run the translations LiveView tests**

```bash
export PATH="/opt/homebrew/bin:$PATH"
mix test test/kiln_cms_web/live/translations_live_test.exs
```

Expected: all tests in the file PASS (admin dashboard + XLIFF + editor panel + scoped editor).

- [ ] **Step 6: Commit the implementation**

```bash
git add lib/kiln_cms_web/live/translations_live.ex test/kiln_cms_web/live/translations_live_test.exs
git commit -m "$(cat <<'EOF'
fix(i18n): gate TranslationsLive create chip on editable_types (#1156)

Keep coverage rows for types an editor may only read; hide + Missing
and silently refuse forged create_translation events.
EOF
)"
```

---

### Task 3: Precommit and open the PR

**Files:**
- (none new — verification + ship)

- [ ] **Step 1: Run `mix precommit` and fix any issues it reports**

```bash
export PATH="/opt/homebrew/bin:$PATH"
mix precommit
```

Expected: compile (warnings as errors), format check, credo, sobelow, deps.audit, kiln checks, and full test suite all green. If format fails, run `mix format` on the touched files and re-check.

- [ ] **Step 2: Push and open/update the PR**

```bash
git push -u origin cursor/1156-translations-live-author-gate-c385
```

PR title: `fix(i18n): gate TranslationsLive create chip on editable_types (#1156)`

PR body:

```markdown
Closes #1156.

## Summary
- Coverage rows for types an editor may not author stay visible (read-only).
- `+ Missing` is replaced with a static missing chip when `may_author?` is false.
- `create_translation` silently refuses forged events for those types (same pattern as ContentEditorLive / #922).

## Test plan
- [x] `mix test test/kiln_cms_web/live/translations_live_test.exs`
- [x] `mix precommit`
- Manual: sign in as an editor with `editable_types: ["post"]`, open `/editor/translations`, confirm page rows show static "missing" and post rows still offer `+ Missing`.
```

Base branch: `main`.

---

## Spec coverage self-review

| Spec requirement | Task |
|------------------|------|
| Keep unauthorable rows | Task 2 template (row still rendered); Task 1 test 1 |
| Hide create chip / static missing | Task 2 template span; Task 1 test 1 |
| Still create when may author | Task 1 test 2; unchanged happy path |
| Silent handler refuse | Task 2 handler; Task 1 test 3 |
| Local helpers, no shared extract | Task 2 helpers only in `TranslationsLive` |
| XLIFF out of scope | No task touches export/import |
| Files listed in spec | Both tasks |

## Placeholder / consistency check

- No TBD/TODO left in steps.
- `may_author?/3` and `type_name_of/1` signatures match between Task 2 steps.
- Row field is consistently `may_author?` (boolean) in data, template, and tests.
