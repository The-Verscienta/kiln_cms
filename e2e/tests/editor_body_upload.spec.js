// @ts-check
// Pictures into the body (texttile's "paste one into the body, drop one on
// it", adapted to the block editor): a real PNG dropped on a rich-text block
// uploads through the media library and lands as an image block right after
// it. Also the flush contract: a Save clicked straight after typing carries
// the last keystrokes, because the block settles its debounced push on the
// button's mousedown.
const {test, expect, signInAsAdmin, newDraftPage, addBlock} = require("./fixtures");

// A minimal valid 1x1 PNG (the same bytes the Elixir tests upload).
const PNG_BASE64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP6zwAAAAcAAQL+pTXmAAAAAElFTkSuQmCC";

test.describe("body image upload", () => {
  test.beforeEach(async ({page}) => {
    await signInAsAdmin(page);
  });

  test("an image dropped on a rich-text block becomes an image block after it", async ({page}) => {
    await newDraftPage(page);
    await addBlock(page, "rich_text");

    const editor = page.locator('[phx-hook="RichText"] .ProseMirror').first();
    await expect(editor).toBeVisible();
    await editor.click();
    await page.keyboard.type("Prose above the picture");

    // A drop with a real file. ProseMirror resolves the drop position from the
    // event's coordinates, so they have to land inside the editor.
    const box = await editor.boundingBox();
    if (!box) throw new Error("editor has no box");
    const dataTransfer = await page.evaluateHandle(b64 => {
      const bytes = Uint8Array.from(atob(b64), c => c.charCodeAt(0));
      const dt = new DataTransfer();
      dt.items.add(new File([bytes], "dropped.png", {type: "image/png"}));
      return dt;
    }, PNG_BASE64);
    await editor.dispatchEvent("drop", {
      dataTransfer,
      clientX: box.x + box.width / 2,
      clientY: box.y + box.height / 2,
    });

    // The image block lands right after the prose block, filled from the
    // library: a media id and a preview of the uploaded file.
    const cards = page.locator("#blocks-sortable > [id^='block-']");
    await expect(cards).toHaveCount(2);
    const imageCard = cards.nth(1);
    await expect(imageCard.locator('input[name$="[media_id]"]')).toHaveValue(/.+/);
    await expect(imageCard.locator("img")).toHaveAttribute("src", /\/uploads\//);
    // Nothing was written into the prose itself.
    await expect(editor).not.toContainText("dropped.png");
    await expect(editor.locator("img")).toHaveCount(0);

    // The draft autosaves the new block; the save line says a write landed.
    await expect(page.locator("#save-status")).toContainText(/Saved|Last saved/);
  });

  test("a Save clicked straight after typing carries the last keystrokes", async ({page}) => {
    await newDraftPage(page);
    await addBlock(page, "rich_text");

    const editor = page.locator('[phx-hook="RichText"] .ProseMirror').first();
    await editor.click();
    await page.keyboard.type("Typed and saved at once");
    // No wait for the 300 ms debounce: the mousedown on Save flushes it.
    await page.getByRole("button", {name: "Save", exact: true}).click();
    await expect(page.getByText("Saved.")).toBeVisible();

    await page.reload();
    await expect(page.locator('[phx-hook="RichText"] .ProseMirror').first()).toContainText(
      "Typed and saved at once"
    );
  });
});

test.describe("the save line and the line to the server", () => {
  test.beforeEach(async ({page}) => {
    await signInAsAdmin(page);
  });

  test("a write that lands flashes Saved, then settles to the stamp of that save", async ({page}) => {
    await newDraftPage(page);
    const status = page.locator("#save-status");
    // Fresh from the mount: the stamp of the record's last write, no flash.
    await expect(status).toHaveText(/Last saved/);
    await expect(status).not.toHaveClass(/fresh/);

    await page.fill('input[name$="[title]"]', "Save line spec");
    // Queued behind the debounce: still the stamp, never a "Saving…".
    await expect(status).toHaveAttribute("data-state", "pending");
    await expect(status).not.toHaveText(/Saving/);

    // The autosave lands: loud "Saved" for a moment, then the stamp again.
    await expect(status).toHaveClass(/fresh/, {timeout: 5000});
    await expect(status).toHaveText("Saved");
    await expect(status).not.toHaveClass(/fresh/, {timeout: 5000});
    await expect(status).toHaveText(/Last saved · just now/);
    await expect(status).toHaveAttribute("title", /The last save was at \d\d:\d\d:\d\d\./);
  });

  test("a rich-text block re-sends its words after a dropped line", async ({page}) => {
    await newDraftPage(page);
    await addBlock(page, "rich_text");
    const editor = page.locator('[phx-hook="RichText"] .ProseMirror').first();
    await editor.click();
    await page.keyboard.type("Before the line dropped. ");
    const status = page.locator("#save-status");
    await expect(status).toHaveClass(/fresh/, {timeout: 5000});
    const writtenAt = await status.getAttribute("data-at");

    // More words, then the line is cut without a goodbye — inside the 300 ms
    // debounce, so the push has not even left. An abnormal close handed to
    // Phoenix's own handler, because a `conn.close()` arrives back as code
    // 1000, which LiveView reads as a server goodbye and answers with a page
    // reload rather than a rejoin. The rejoin remounts the LiveView from the
    // database, which knows nothing of these words (and comes up saying
    // "saved", which is why the wait below is on the stamp moving, not on
    // the state).
    await page.keyboard.type("After it dropped.");
    await page.evaluate(() =>
      window.liveSocket.socket.conn.onclose({code: 1006, reason: "abnormal", wasClean: false})
    );
    await page.waitForFunction(() =>
      document.querySelector("[data-phx-main]")?.classList.contains("phx-connected")
    );

    // The host kept the words; reconnected() sent them up; autosave wrote them.
    await expect(status).not.toHaveAttribute("data-at", writtenAt || "", {timeout: 10000});
    await page.reload();
    await expect(page.locator('[phx-hook="RichText"] .ProseMirror').first()).toContainText(
      "Before the line dropped. After it dropped."
    );
  });

  test("a line that goes quiet is marked, and rebuilt", async ({page}) => {
    await newDraftPage(page);
    const status = page.locator("#save-status");
    await expect(status).toHaveText(/Last saved/);

    // A server that stops answering: the watch's own question gets no reply,
    // and with nothing else on the line the silence is counted from here.
    await page.evaluate(() => {
      window.liveSocket.socket.ping = () => false;
    });

    await expect(page.locator("html")).toHaveClass(/phx-late/, {timeout: 20000});
    await expect(status).toHaveText("Offline — not saving");

    // The revive goes through Phoenix's own reconnect on the same Socket
    // object, so the patch would keep the line quiet forever; put the answer
    // back, and the rebuilt line is heard again and the mark lifts.
    await page.evaluate(() => {
      delete window.liveSocket.socket.ping;
    });
    await expect(page.locator("html")).not.toHaveClass(/phx-late/, {timeout: 20000});
    await expect(page.locator("[data-phx-main]")).toHaveClass(/phx-connected/);
    await expect(status).toHaveText(/Last saved/);
  });
});
