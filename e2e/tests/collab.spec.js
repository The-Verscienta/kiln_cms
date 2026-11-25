// @ts-check
// Live collaborative editing of a rich-text block (KilnCMS.Collab.Crdt): two
// browsers on one draft, each block bound to the same Y.Doc over /ws/collab
// (`mountCollab` in assets/js/rich_text.js, `acquireDoc` in assets/js/collab.js).
//
// Nothing else in the suite checks that the words actually travel. During the
// TipTap 3 move (#1957) y-tiptap began rendering the shared doc synchronously
// inside `new Editor`, so `onUpdate` fired before `hook.slash` existed; the
// throw aborted the constructor, no peer ever synced, and every editor spec
// still passed — each of them is one browser, and a block that renders its
// stored HTML looks the same whether or not it is wired to anybody. Only a
// second peer seeing the first one's keystrokes proves the binding is live.
//
// Two different accounts, not the admin twice: the advisory field lock (#140)
// and the remote caret's label are both per user. While A's caret is in the
// block, B's copy is `contenteditable=false` (the lock); A clicking away
// releases it, which is how the turn passes to B here.
//
// The flag is off for the rest of the suite (config/e2e.exs, as in prod), so
// this spec turns it on through the e2e-only `/dev/e2e-collab` route and puts
// it back afterwards. It is VM-global and read on every editor mount, so it is
// switched on before either peer opens the editor.
const {
  test,
  expect,
  signInAsAdmin,
  signInAsEditor,
  newDraftPage,
  addBlock,
  save,
  newGuardedContext,
  deleteContentById,
} = require("./fixtures");

const EDITOR_SELECTOR = '[phx-hook="RichText"] .ProseMirror';

// Every uncaught error on a page, so the test can say there were none. The
// #1957 regression was exactly this: a throw inside the editor's constructor
// that broke the block without breaking anything a single-peer spec looks at.
function collectPageErrors(page) {
  const errors = [];
  page.on("pageerror", err => errors.push(err.message));
  return errors;
}

// Switch `:collab_prototype` (KilnCMSWeb.Plugs.E2ECollab), returning the value
// it had. Sent from a signed-in page, which carries the CSRF token the
// dev-tools scope's `protect_from_forgery` asks for.
async function setCollab(page, enabled) {
  const reply = await page.evaluate(async enabled => {
    const token = document.querySelector('meta[name="csrf-token"]')?.getAttribute("content");
    const res = await fetch("/dev/e2e-collab", {
      method: "POST",
      headers: {"content-type": "application/json", "x-csrf-token": token || ""},
      body: JSON.stringify({enabled}),
    });
    return {status: res.status, body: await res.json()};
  }, enabled);
  expect(reply.status).toBe(200);
  expect(reply.body.enabled).toBe(enabled);
  return reply.body.was;
}

// The document's own text. A remote caret is a widget INSIDE the editor, and
// its label holds the collaborator's initials, so `toHaveText` on the editor
// reads "Alpha from A and BDE" the moment B's caret arrives. Strip the carets
// first, polling like `toHaveText` would.
function expectDocText(editor, text) {
  return expect
    .poll(() =>
      editor.evaluate(el => {
        const copy = el.cloneNode(true);
        copy.querySelectorAll(".collaboration-carets__caret").forEach(caret => caret.remove());
        return copy.textContent;
      })
    )
    .toBe(text);
}

// Put the caret at the end of the block's (single-line) text and type.
async function typeAtEnd(page, editor, text) {
  await editor.click();
  await expect(editor).toBeFocused();
  await page.keyboard.press("End");
  await page.keyboard.type(text);
}

test.describe("live collaborative editing", () => {
  test("two peers see each other's typing, and the other's caret", async ({page, browser}) => {
    const errorsA = collectPageErrors(page);
    await signInAsAdmin(page);
    const collabWas = await setCollab(page, true);
    let id;
    const peer = await newGuardedContext(browser);
    const errorsB = collectPageErrors(peer.page);

    try {
      id = await newDraftPage(page);

      // ── Peer A starts the document ──────────────────────────────────────
      await addBlock(page, "rich_text");
      const first = page.locator(EDITOR_SELECTOR).first();
      await expect(first).toBeVisible();
      await first.click();
      await page.keyboard.type("Alpha");
      await save(page);

      // A saved block has its stable id, so after the reload it binds to the
      // block's own fragment of the document's room.
      await page.reload();
      const host = page.locator('[phx-hook="RichText"]').first();
      await expect(host).toHaveAttribute("data-collab-topic", `collab:page:${id}`);
      await expect(host).toHaveAttribute("data-collab-fragment", /^block-/);
      const editorA = page.locator(EDITOR_SELECTOR).first();
      await expectDocText(editorA, "Alpha");

      // ── Peer B joins the same editor URL ────────────────────────────────
      await signInAsEditor(peer.page);
      await peer.page.goto(new URL(page.url()).pathname);
      const editorB = peer.page.locator(EDITOR_SELECTOR).first();
      await expect(editorB).toBeVisible();
      // The joiner takes the room's state rather than seeding from the stored
      // HTML too — seeding on top of the CRDT would show the prose twice.
      await expectDocText(editorB, "Alpha");
      await expectDocText(editorA, "Alpha");

      // ── A types, B sees it ──────────────────────────────────────────────
      await typeAtEnd(page, editorA, " from A");
      await expectDocText(editorB, "Alpha from A");
      // A holds the block's field lock while focused, so B's copy is read-only.
      await expect(editorB).toHaveAttribute("contenteditable", "false");

      // ── A clicks away, B takes the turn, A sees it ──────────────────────
      await page.locator('input[name$="[title]"]').click();
      await expect(editorB).toHaveAttribute("contenteditable", "true");
      await typeAtEnd(peer.page, editorB, " and B");
      await expectDocText(editorA, "Alpha from A and B");
      await expectDocText(editorB, "Alpha from A and B");

      // ── B's caret renders in A's editor, colored and labelled ───────────
      const caret = editorA.locator(".collaboration-carets__caret");
      await expect(caret).toHaveCount(1);
      const borderColor = await caret.evaluate(el => getComputedStyle(el).borderLeftColor);
      expect(borderColor).not.toBe("rgba(0, 0, 0, 0)");
      expect(borderColor).not.toBe("transparent");
      // "Demo Editor", the seeded editor (priv/repo/seeds.exs).
      await expect(caret.locator(".collaboration-carets__label")).toHaveText("DE");

      // Nothing was doubled by either join, and neither page threw.
      expect(errorsA).toEqual([]);
      expect(errorsB).toEqual([]);
    } finally {
      await peer.context.close();
      await setCollab(page, collabWas);
      if (id) await deleteContentById(page, "page", id);
    }
  });

  // #2772: the block used to wait on the collab join before mounting TipTap,
  // and a socket that never connected left it with no editor at all. Closing
  // every /ws/collab handshake stands in for an expired token after a deploy
  // or a proxy that drops WebSockets; the LiveView socket is left alone.
  test("a block whose collab socket can't connect still mounts and saves", async ({page}) => {
    const errors = collectPageErrors(page);
    await signInAsAdmin(page);
    const collabWas = await setCollab(page, true);
    let id;

    try {
      id = await newDraftPage(page);
      await addBlock(page, "rich_text");
      const first = page.locator(EDITOR_SELECTOR).first();
      await expect(first).toBeVisible();
      await first.click();
      await page.keyboard.type("Before");
      await save(page);

      await page.routeWebSocket(/\/ws\/collab\//, ws => ws.close());
      await page.reload();

      const host = page.locator('[phx-hook="RichText"]').first();
      await expect(host).toHaveAttribute("data-collab-topic", `collab:page:${id}`);
      const editor = page.locator(EDITOR_SELECTOR).first();
      await expect(editor).toBeVisible();
      await expect(editor).toHaveText("Before");
      await expect(host.locator("[data-collab-unavailable]")).toBeVisible();

      // Saves through the single-user path: the words survive a reload.
      await typeAtEnd(page, editor, " and after");
      await save(page);
      await page.reload();
      await expect(page.locator(EDITOR_SELECTOR).first()).toHaveText("Before and after");

      expect(errors).toEqual([]);
    } finally {
      await page.unrouteAll({behavior: "ignoreErrors"});
      await setCollab(page, collabWas);
      if (id) await deleteContentById(page, "page", id);
    }
  });
});
