#!/usr/bin/env bash
# =============================================================================
# copilot-cli-image-paste
# macOS clipboard image paste support for GitHub Copilot CLI
#
# Author:  Idan Shimon <https://github.com/idanshimon>
# License: MIT
# Repo:    https://github.com/idanshimon/copilot-cli-image-paste
#
# Usage:
#   bash patch.sh          # patch all installed versions
#   bash patch.sh --check  # show patch status without modifying anything
#
# Re-run after every Copilot CLI update. Already-patched versions are skipped.
# =============================================================================

set -euo pipefail

PATCH_MARKER="macOS: Intercept Ctrl+V"
PKG_DIR="$HOME/.copilot/pkg/universal"
CHECK_ONLY=false

# ---- arg parsing ------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --check|-c) CHECK_ONLY=true ;;
    --help|-h)
      echo "Usage: bash patch.sh [--check]"
      echo ""
      echo "  (no args)  Patch all unpatched Copilot CLI versions"
      echo "  --check    Show patch status only, do not modify anything"
      exit 0
      ;;
  esac
done

# ---- sanity check -----------------------------------------------------------
if [[ ! -d "$PKG_DIR" ]]; then
  echo "❌ Copilot CLI package directory not found: $PKG_DIR"
  echo "   Is GitHub Copilot CLI installed? https://github.com/github/copilot-cli"
  exit 1
fi

if [[ "$(uname)" != "Darwin" ]]; then
  echo "ℹ️  This patch is macOS-only. Nothing to do on $(uname)."
  exit 0
fi

# ---- patch code -------------------------------------------------------------
# Injected at the end of @teddyzhu/clipboard's index.js.
# See README.md for a full explanation of why this location and how it works.
apply_patch() {
  local TARGET="$1"
  cat >> "$TARGET" << 'PATCH_EOF'

// =============================================================================
// copilot-cli-image-paste — macOS Ctrl+V image paste patch
// https://github.com/idanshimon/copilot-cli-image-paste
//
// ROOT CAUSE
// ----------
// On Windows, pressing Ctrl+V with an image on the clipboard causes Windows
// Terminal to emit an *empty* bracketed paste sequence (\x1B[200~\x1B[201~)
// which the Copilot CLI detects as a cue to read clipboard image data via
// ClipboardManager().getImageData().
//
// On macOS, Terminal.app and iTerm2 intercept Cmd+V at the OS level:
//   • If the clipboard has TEXT  → they emit a bracketed paste with that text.
//   • If the clipboard has only an IMAGE → they emit NOTHING at all.
// Ctrl+V (without Cmd) emits the raw byte \x16 (ASCII 26), which the CLI
// treats as a literal character — it never reaches the image-paste path.
//
// THE FIX — image paste
// ---------------------
// We wrap process.stdin.read() — the method the CLI's readline loop calls on
// every "readable" event — and intercept zero-argument reads (full-chunk mode).
// When we detect \x16 (Ctrl+V) in the chunk, we:
//   1. Check if clipboard has text (if yes, pass through — let the CLI handle it)
//   2. Check if clipboard has an image (via ClipboardManager().getImageData())
//   3. If image found: replace \x16 with \x1B[200~\x1B[201~ in the chunk
//      → This triggers the CLI's existing onEmptyPasteFallback path, which
//        calls ClipboardManager().getImageData() and attaches the image.
//   4. Otherwise: return chunk unchanged
//
// THE FIX — backspace whole-token deletion
// -----------------------------------------
// After the paste sequence is injected the CLI runs an async chain to:
//   getImageData() → write temp file → checkForAttachmentPath() → insertInput()
// This chain takes ~20–100 ms.  If the user presses Backspace before it
// completes the image token is not yet in the input, oNt() (the CLI's
// whole-token backspace handler) returns false, and the key falls through to
// char-by-char deletion mode.
//
// Fix: when a *solo* \x7f (Backspace) arrives within 500 ms of a paste, we
// intercept it, schedule its redelivery via process.stdin.push() after the
// remaining window (ensuring the async chain has finished), and return null
// to the readline loop so nothing happens in the meantime.  When the backspace
// is redelivered the token is already in the input and oNt() deletes the whole
// token in one keystroke — matching the Windows behavior.
//
// WHY HERE (this file)
// --------------------
// app.js (the 14 MB bundled CLI) loads this module via:
//   __clipboardRequire = createRequire('<pkg>/clipboard/index.js')
//   const { ClipboardManager } = __clipboardRequire('@teddyzhu/clipboard')
// This file is therefore evaluated in the same Node.js process as the CLI,
// giving us access to process.stdin before any readline setup. It is the
// earliest safe hook point that does not require modifying the minified bundle.
// =============================================================================
if (process.platform === 'darwin' && process.stdin && process.stdin.isTTY) {
  try {
    const _origRead = process.stdin.read.bind(process.stdin)
    // Timestamp of the last injected image paste; 0 = none in flight.
    let _pasteTs = 0

    process.stdin.read = function (...args) {
      const chunk = _origRead(...args)
      // Only intercept no-arg reads (full-chunk reads from the readline loop).
      // Sized reads (read(n)) are left untouched to preserve their contract.
      if (args.length === 0 && chunk !== null) {
        const isString = typeof chunk === 'string'
        const ctrlVIdx = isString ? chunk.indexOf('\x16') : chunk.indexOf(0x16)

        if (ctrlVIdx !== -1) {
          try {
            const mgr = new nativeBinding.ClipboardManager()
            let hasText = false
            try { hasText = !!mgr.getText() } catch (_) {}
            if (!hasText) {
              let hasImage = false
              try {
                const imgData = mgr.getImageData()
                hasImage = !!(imgData && imgData.data && imgData.data.length > 0)
              } catch (_) {}
              if (hasImage) {
                // Replace Ctrl+V byte with the empty bracketed paste sequence.
                // The CLI's existing paste handler detects this and calls
                // onEmptyPasteFallback() → ClipboardManager().getImageData().
                const PASTE_SEQ = '\x1B[200~\x1B[201~'
                _pasteTs = Date.now()
                if (isString) {
                  return chunk.slice(0, ctrlVIdx) + PASTE_SEQ + chunk.slice(ctrlVIdx + 1)
                } else {
                  return Buffer.concat([
                    chunk.slice(0, ctrlVIdx),
                    Buffer.from(PASTE_SEQ),
                    chunk.slice(ctrlVIdx + 1),
                  ])
                }
              }
            }
          } catch (_) { /* clipboard error — fall through, return chunk unchanged */ }
        }

        // Backspace timing fix: delay a solo \x7f that arrives within 500 ms
        // of an image paste so the async token-insert chain can complete first.
        if (_pasteTs > 0) {
          const elapsed = Date.now() - _pasteTs
          const isSoloBackspace = isString
            ? chunk === '\x7f'
            : (chunk.length === 1 && chunk[0] === 0x7f)

          if (isSoloBackspace && elapsed < 500) {
            _pasteTs = 0
            const delay = Math.max(50, 500 - elapsed + 50)
            try {
              setTimeout(() => {
                try { process.stdin.push(isString ? '\x7f' : Buffer.from([0x7f])) } catch (_) {}
              }, delay)
            } catch (_) {}
            return null
          }

          // Any non-backspace key clears paste state (cursor may have moved).
          _pasteTs = 0
        }
      }
      return chunk
    }
  } catch (_) { /* fail open — never break module load */ }
}
PATCH_EOF
}

# ---- main loop --------------------------------------------------------------
PATCHED=0
SKIPPED=0
MISSING=0

for VERSION_DIR in "$PKG_DIR"/*/; do
  TARGET="$VERSION_DIR/clipboard/node_modules/@teddyzhu/clipboard/index.js"

  if [[ ! -f "$TARGET" ]]; then
    MISSING=$((MISSING + 1))
    continue
  fi

  if grep -q "$PATCH_MARKER" "$TARGET" 2>/dev/null; then
    echo "⏭  Already patched: $(basename "$VERSION_DIR")"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if [[ "$CHECK_ONLY" == true ]]; then
    echo "🔲 Not patched:     $(basename "$VERSION_DIR")"
    PATCHED=$((PATCHED + 1))
  else
    apply_patch "$TARGET"
    echo "✅ Patched:         $(basename "$VERSION_DIR")"
    PATCHED=$((PATCHED + 1))
  fi
done

echo ""
if [[ "$CHECK_ONLY" == true ]]; then
  echo "Check complete — needs patching: $PATCHED, already patched: $SKIPPED, no clipboard file: $MISSING"
else
  echo "Done — patched: $PATCHED, already patched: $SKIPPED, no clipboard file: $MISSING"
  echo ""
  echo "▶  How to use: take a screenshot (Cmd+Shift+4 or Cmd+Shift+3),"
  echo "   then press Ctrl+V inside the Copilot CLI."
fi
