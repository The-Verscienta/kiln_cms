// The passkey step-up on /sign-in/verify (#2247, #2828) against a fake window
// and document: the block and its "you can also use a passkey" hint are
// shipped `hidden`, and only a browser with WebAuthn reveals them; a
// passkey-only account's note (#2887) is revealed where they are not.
// Run: `npm test` in assets/.
import {test, afterEach} from "node:test"
import assert from "node:assert/strict"

import {initPasskeyStepUp} from "../js/passkeys.js"

const navigatorDescriptor = Object.getOwnPropertyDescriptor(globalThis, "navigator")

function withWebAuthn(on) {
  globalThis.window = on ? {PublicKeyCredential: function () {}} : {}
  Object.defineProperty(globalThis, "navigator", {
    value: on ? {credentials: {}} : {},
    configurable: true,
    writable: true,
  })
}

afterEach(() => {
  delete globalThis.window
  if (navigatorDescriptor) Object.defineProperty(globalThis, "navigator", navigatorDescriptor)
  else delete globalThis.navigator
})

// Element stand-ins: just what `initPasskeyStepUp` touches.
function fakePage({button = true} = {}) {
  const parts = {
    "[data-role=passkey-step-up]": button ? {addEventListener: () => {}} : null,
    "[data-role=passkey-status]": {textContent: ""},
  }
  const block = {hidden: true, querySelector: (selector) => parts[selector]}
  const hint = {hidden: true}
  const unsupported = {hidden: true}
  const root = {
    querySelectorAll: (selector) =>
      ({
        "[data-passkey-step-up]": [block],
        "[data-passkey-step-up-hint]": [hint],
        "[data-passkey-step-up-unsupported]": [unsupported],
      })[selector] || [],
  }
  return {root, block, hint, unsupported}
}

test("with WebAuthn, reveals the passkey button and the hint beside the code", () => {
  withWebAuthn(true)
  const {root, block, hint} = fakePage()

  initPasskeyStepUp(root)

  assert.equal(block.hidden, false)
  assert.equal(hint.hidden, false)
})

test("without WebAuthn, the button and the hint stay hidden", () => {
  withWebAuthn(false)
  const {root, block, hint} = fakePage()

  initPasskeyStepUp(root)

  assert.equal(block.hidden, true)
  assert.equal(hint.hidden, true)
})

test("a block with no button reveals neither, so the hint never points at nothing", () => {
  withWebAuthn(true)
  const {root, block, hint} = fakePage({button: false})

  initPasskeyStepUp(root)

  assert.equal(block.hidden, true)
  assert.equal(hint.hidden, true)
})

// A passkey-only account (#2887): the note saying this browser can't use a
// passkey, and where else to go, is shown exactly when no button is.
test("with WebAuthn, the can't-use-a-passkey note stays hidden", () => {
  withWebAuthn(true)
  const {root, block, unsupported} = fakePage()

  initPasskeyStepUp(root)

  assert.equal(block.hidden, false)
  assert.equal(unsupported.hidden, true)
})

test("without WebAuthn, the can't-use-a-passkey note is revealed", () => {
  withWebAuthn(false)
  const {root, block, unsupported} = fakePage()

  initPasskeyStepUp(root)

  assert.equal(block.hidden, true)
  assert.equal(unsupported.hidden, false)
})

test("a block with no button reveals the note, since no passkey is offered", () => {
  withWebAuthn(true)
  const {root, unsupported} = fakePage({button: false})

  initPasskeyStepUp(root)

  assert.equal(unsupported.hidden, false)
})
