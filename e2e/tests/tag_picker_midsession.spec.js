// @ts-check
// #948. `TagFilter`'s bind()/unbind() split in assets/js/app.js exists for one
// transition: the tag picker (`#tag-picker`) renders no filter box at mount
// when nothing applies to this content type (#524), a later LiveView patch can
// grow one, and the box that appears then has to be *rebound* — or its
// keystrokes leak past the `phx-update="ignore"` wrapper into the content
// form's own `phx-change`: a dirty document, a debounced draft autosave, and a
// paper-trail version per keystroke, plus a full form submit on Enter. Elixir
// LiveView tests run no JS, and re-collapsing `bind()` back into `mounted()`
// reads like tidying — nothing catches it but a real browser.
//
// Two structural blockers kept this out of editor.spec.js (see #948 for the
// full writeup):
//
//   1. Reaching the empty state at all. The suite runs against a persistent,
//      never-sandboxed database (`workers: 1`, only `mix e2e.reset` drops it),
//      so a tag left applicable to every content type would make the empty
//      state unreachable on any reused database. `editor.spec.js`'s own
//      tag-picker spec (#939) scopes its group to "page" content for exactly
//      this reason. This spec uses a *post* draft instead, so it never
//      collides with that group, and creates only plain (ungrouped) tags of
//      its own — deleted again in a `finally`, so nothing it creates outlives
//      the test either. As long as no other spec leaves a "post"-scoped or
//      ungrouped tag behind, "post" stays reachable from empty regardless of
//      run order.
//
//   2. Driving the transition. `@tags`/`@tag_groups` are loaded once at
//      `ContentEditorLive` mount, so a tag created afterwards only reaches a
//      session already looking at the record via `record.tags` — which means
//      it has to be attached by *another* session. A second, independent
//      browser context (`newGuardedContext`) signed in as the seeded editor
//      plays that other session: it creates two tags, attaches one to the
//      same draft, and saves.
//
//      That leaves the first session's own `@form` — built once, at mount —
//      pointing at a `lock_version` the editor's write just moved past. Its
//      own next save is therefore rejected by the optimistic lock
//      (`stale_conflict?/1`) rather than succeeding quietly: `flag_conflict/1`
//      pauses saving and surfaces "Reload latest". Clicking that runs
//      `reload_conflict`, which re-fetches the record and calls
//      `assign_record/2` — the same function every *successful* save also
//      runs, and the one that rebuilds `@tag_index` (`refresh_tag_index/1`).
//      That rebuild is what turns "record.tags now has a tag this session
//      never rendered" into an actual `@sections` entry — and the resulting
//      DOM patch, on the socket this session already had open, is the "later
//      patch" #524/#948 are about. A `page.reload()` would show the same
//      grown filter box, but through a brand new `mounted()` call that binds
//      regardless of whether `updated()` still pulls its weight — it would
//      not exercise the code path this test exists to cover (confirmed while
//      writing this test: a reload-driven version of this assertion kept
//      passing with `updated()`'s rebind commented out).
//
//      `reload_conflict` doesn't refresh `@tag_groups`/`@tags` themselves
//      (only a true mount does — see `refresh_tag_index/1`'s own comment), so
//      the attached tag's group is unknown to this session and it lands in
//      the picker's "Ungrouped" catch-all (`bucket_for/3`) rather than under a
//      named section. That's fine here: this test only needs *a* section to
//      appear, not a specific one.
const {
  test,
  expect,
  signInAsAdmin,
  signInAsEditor,
  newDraftContent,
  newGuardedContext,
} = require("./fixtures");

test.describe("tag picker mid-session growth", () => {
  test("a tag attached by another session rebinds the filter box, not the content form", async ({
    page,
    browser,
  }) => {
    test.slow();

    const stamp = Date.now();
    const attached = `e2e-948-attach-${stamp}`;
    const distractor = `e2e-948-distract-${stamp}`;

    // Cleanup runs even if an assertion below throws, so a failed run doesn't
    // leave a tag behind to break the *next* run's empty state (see blocker 1
    // above).
    let editorSession;
    try {
      await signInAsAdmin(page);

      // A post draft is post-#524 empty by construction here: nothing else in
      // the suite leaves an applicable group or an ungrouped tag lying
      // around. The whole `#tag-picker` fieldset is always rendered (it holds
      // the legend + empty-state copy), but the filter box and every section
      // inside it are conditional on `@sections != []` — that's the DOM state
      // this test drives through.
      await newDraftContent(page, "post");
      const draftUrl = page.url();
      await page.getByRole("tab", { name: /settings/i }).click();

      const picker = page.locator("#tag-picker");
      await expect(picker).toBeVisible();
      await expect(picker.locator("[data-tag-filter-input]")).toHaveCount(0);
      await expect(picker.locator("details[data-tag-section]")).toHaveCount(0);

      // The second session: a different signed-in editor, in a separate
      // browser context (own cookies, own LiveView socket), playing the
      // collaborator who tags the draft while the first session sits idle.
      editorSession = await newGuardedContext(browser);
      const editorPage = editorSession.page;
      await signInAsEditor(editorPage);

      // Plain, ungrouped tags (leave the group `<select>` on its "— Ungrouped
      // —" prompt) — see blocker 1 above for why this test doesn't create a
      // tag group.
      await editorPage.goto("/editor/taxonomy");
      for (const name of [attached, distractor]) {
        await editorPage.fill('#new-tag-form input[name$="[name]"]', name);
        await editorPage.locator("#new-tag-form button[type=submit]").click();
        await expect(editorPage.getByText(name, { exact: true }).first()).toBeVisible();
      }

      // Attach only `attached` to the draft, from the editor's own session.
      await editorPage.goto(draftUrl);
      await editorPage.getByRole("tab", { name: /settings/i }).click();

      const editorSection = editorPage.locator("#tag-section-ungrouped");
      // Freshly populated and empty of ticks, this section mounts collapsed —
      // same as any other tag-picker section on a fresh render (#523).
      await editorSection.locator("summary").click();
      await editorSection.getByRole("checkbox", { name: attached }).check();
      await editorPage.getByRole("button", { name: /^save$/i }).click();
      await expect(editorPage.locator('span[aria-live="polite"]')).toHaveText("Saved", {
        timeout: 10_000,
      });

      // Back on the first session, still on the very same mounted socket —
      // no reload (see the "Driving the transition" comment at the top).
      const indicator = page.locator('span[aria-live="polite"]');

      // This session's `@form` is still built from the pre-attach record, so
      // submitting it now is guaranteed to lose the optimistic-lock race the
      // editor's save already won — that's the point, see above.
      await page.getByRole("button", { name: /^save$/i }).click();
      const conflictBanner = page.locator("#edit-conflict");
      await expect(conflictBanner).toBeVisible();

      // The conflict's own error flash renders `fixed top-3 right-3` (see
      // `core_components.ex`'s `flash/1`) and, at this viewport, physically
      // overlaps "Reload latest" — a genuine layout collision, not a test
      // artifact, so a plain `.click()` fights Playwright's pointer-event
      // interception check indefinitely. Dispatching the click via the DOM
      // directly sidesteps that: `phx-click`/`data-confirm` are ordinary
      // event listeners and don't care whether the click was "trusted".
      page.once("dialog", dialog => dialog.accept());
      await conflictBanner
        .getByRole("button", { name: /reload latest/i })
        .evaluate(el => el.click());
      await expect(conflictBanner).toBeHidden();
      await expect(indicator).toHaveText("Saved");
      // Best-effort: clear the lingering error flash so it can't go on to
      // intercept a later click the same way.
      await page
        .locator("#flash-error")
        .evaluate(el => el.click())
        .catch(() => {});

      // The grown filter box (blocker 2's payoff) and the "Ungrouped" section
      // it now governs — `attached` on it (`record.tags`, survives any
      // filter — see `all_pickable_tags/2`), `distractor` not (this
      // session's `@tags` is still the pre-attach, empty snapshot from mount,
      // so an untagged tag it never saw simply isn't pickable yet).
      const filterInput = picker.locator("[data-tag-filter-input]");
      await expect(filterInput).toBeVisible();

      const section = picker.locator("#tag-section-ungrouped");
      await expect(section).toBeVisible();
      await expect(section.getByRole("checkbox", { name: attached })).toBeChecked();
      await expect(section.getByRole("checkbox", { name: distractor })).toHaveCount(0);

      // Typing is a server round-trip (`filter_tags`, #1149): it replaces
      // `@tags` with a fresh, query-matching read, which is how `distractor`
      // can appear here even though it was invisible a moment ago.
      await filterInput.pressSequentially("distract", { delay: 60 });
      await expect(section.getByRole("checkbox", { name: distractor })).toBeVisible();

      // Now narrow to `attached` only. `distractor` isn't on the record, so
      // it disappears when the query stops matching it; `attached` stays
      // either way (it's on the record, so it survives any filter).
      await filterInput.fill("");
      await filterInput.pressSequentially("attach", { delay: 60 });

      // A single `expect(...).toHaveText()` here would auto-retry, and a
      // regression that flips Unsaved → Saving → Saved again inside its
      // window would read as "passed" — the exact kind of assertion that
      // silently stops testing anything once the bug it was written for
      // exists (a "moved" indicator settles right back to "Saved"). Sample a
      // plain string instead, across the client's 300ms filter debounce and
      // the full 2s server autosave debounce, so a transient "Unsaved
      // changes"/"Saving…" cannot hide between polls.
      for (let waited = 0; waited <= 2600; waited += 250) {
        const text = (await indicator.textContent())?.trim();
        expect(text).toBe("Saved");
        await page.waitForTimeout(250);
      }

      await expect(section.getByRole("checkbox", { name: distractor })).toBeHidden();
      await expect(section.getByRole("checkbox", { name: attached })).toBeVisible();
    } finally {
      // `page` (session one) is already signed in as admin from the top of
      // the test — deletes are admin-only, and re-visiting /sign-in while
      // authenticated would just bounce off the form this needs.
      //
      // Guarded by an existence check (rather than assuming creation
      // succeeded): a failure earlier in the `try` — say, the taxonomy form
      // itself — must not turn cleanup into a second, masking failure over a
      // row that was never created.
      await page.goto("/editor/taxonomy");
      for (const name of [attached, distractor]) {
        const row = page.locator("li").filter({ hasText: name }).first();
        if ((await row.count()) === 0) continue;

        page.once("dialog", dialog => dialog.accept());
        await row.getByRole("button", { name: `Delete ${name}` }).click();
        await expect(page.getByText(name, { exact: true })).toHaveCount(0);
      }

      if (editorSession) await editorSession.context.close();
    }
  });
});
