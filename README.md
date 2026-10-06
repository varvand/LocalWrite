# LocalWrite

A native macOS menu bar utility that fixes spelling where you are already typing, using an on-device LLM. Built with Swift, AppKit, SwiftUI, Accessibility, and Apple Foundation Models. No third-party package dependencies.

## Use

1. Open `/Applications/LocalWrite.app`.
2. In **General**, click **Allow Accessibility…**, then enable **LocalWrite** in macOS System Settings → Privacy & Security → Accessibility.
3. Put your cursor in a text field and press **Control–Option–Space**. You don't need to select anything. The shortcut runs when you release the keys.
4. Change the shortcut by clicking its recorder in Settings. Include Control, Option, or Command. Escape cancels recording. Conflicting registered shortcuts are rejected.

By default, **Current line before cursor** corrects exactly the text from the editor's native line start to your insertion point. Text after the cursor stays untouched. You do not select anything yourself. LocalWrite briefly selects backward with Command–Shift–Left, copies that exact text, then returns the cursor before asking the model. It rechecks the same prefix before pasting and leaves the cursor after the corrected text. Wrapped-line behavior follows the editor's native Command–Left command.

Optional paragraph and entire-field modes use Accessibility offsets and support an explicit selection. These advanced modes depend more on the editor's Accessibility implementation; current-line mode is recommended for Obsidian and other Electron editors.

The menu bar icon opens Settings, cancellation, and **Undo last correction**. Undo works only while the original field still contains exactly the applied result. It stores a single correction in memory until quit; no text is saved to disk by LocalWrite.

## Local models

**Apple Intelligence** is the default. It uses `SystemLanguageModel.default` through Foundation Models, returning structured word-level spelling edits. Local macOS dictionary suggestions help the model find misspellings; the LLM chooses the correction in context. LocalWrite composes the final passage locally, preserving its formatting. Requires macOS 26+, a supported Mac, Apple Intelligence enabled, and its downloaded on-device model. The app shows actual model availability in Settings.

**Rescue** accuracy is enabled by default. The complete line or passage is always supplied as context rather than correcting words independently. Both accuracy modes use a single model request. Rescue ranks multilingual macOS dictionary candidates using edit, transposition, and nearby-key distance before the model chooses among them in context. It accepts bounded one-to-three-word edits for split or joined words and composes the final text locally. **Careful** uses fewer dictionary candidates and accepts only individual word edits. There is no second inference or dictionary scan after generation, so a name or technical term cannot trigger another model request.

**Ollama** is optional. Install and start [Ollama](https://docs.ollama.com/quickstart), download a text model, then choose **Local models → Ollama → Refresh**. Select one of your downloaded models. The default address is `http://127.0.0.1:11434`.

Only loopback hosts are accepted. Proxies and HTTP redirects are disabled for model requests. The model list is checked before sending your text, and remote/cloud model metadata is rejected. LocalWrite never switches to a cloud provider. You can additionally [disable cloud features in Ollama](https://docs.ollama.com/faq#how-do-i-disable-ollama-cloud-features) with `OLLAMA_NO_CLOUD=1`.

## How editing works

- Registers a global Carbon hotkey, without a keyboard event monitor or Input Monitoring permission. A temporary local key monitor is used only while recording a shortcut in Settings.
- Reads the focused field only on demand. Current-line mode obtains text with native Copy and avoids unreliable Accessibility cursor offsets. No continuous text or clipboard monitoring.
- Reads only editable text roles; skips secure input, password fields, and excluded applications. Terminal and iTerm are excluded by default.
- Current-line mode checks app/field focus and aggregate keyboard/mouse event counters after generation, then copies the line prefix again and compares it exactly before replacing. It does not record key values or monitor your keystroke content. Typing or clicking during generation discards the result.
- Requests the computed selection through Accessibility and waits for acknowledgement. With clipboard insertion enabled, falls back to keyboard selection if needed, verifies the actual selected text using Copy, then pastes. Preserves the clipboard unless another copy interrupts the transaction. This can be turned off for direct Accessibility-only insertion. Clipboard history apps can see temporary copied/corrected text.
- Accepts only bounded word-level spelling edits. Sentence rewrites, commentary, nonexistent words, and distant substitutions are ignored. Exact matching excludes URLs, emails, code, and hashtags; offsets are applied from the end, preserving Markdown, indentation, line breaks, and invisible editor characters. The passage limit is 4,000 UTF-16 code units. A paragraph containing only invisible placeholders is skipped.

Current-line mode works with editable Accessibility fields that support standard macOS selection, Copy, and Paste, including Electron/CodeMirror editors. It does not need a writable Accessibility selection. Some custom controls, terminals, PDFs, or editors with different keyboard bindings are not supported. They produce a message instead of guessing with Select All or overwriting an unknown field. LLM output can still miss errors or make an unwanted correction; use the menu's Undo action while the field is unchanged.

## Build and local signing

Requires Xcode 26 / Swift 6.2 or later with the macOS 26 SDK. Build for the current Mac architecture:

```sh
bash scripts/build.sh
bash scripts/install.sh
```

The first command creates `dist/LocalWrite.app` with its icon and Info.plist, signs it using a **persistent self-signed local certificate** with hardened runtime, and verifies the signature. The certificate and private key live in a dedicated keychain under `~/Library/Application Support/LocalWrite/Signing`. The build does not add a root certificate to system/login trust stores. The app's designated requirement pins that certificate, so its identity is stable across rebuilds. This is a local build, not notarized or suitable for distribution. No Apple developer account is needed. No app sandbox entitlement is applied, because the utility needs cross-app Accessibility access.

The second command copies it into `/Applications`, verifies the installed signature, and opens Settings. Quit a running copy before installing a rebuild. Set `LOCALWRITE_INSTALL_DIR` if a different install folder is necessary, and keep that folder consistent. You can also open `Package.swift` in Xcode; use the scripts to produce the full app bundle. A signed `dist/LocalWrite.zip` is also generated to avoid file-provider metadata affecting the bundle in cloud-synced project folders.

If you have a local code-signing certificate, use it instead:

```sh
SIGN_IDENTITY='Your certificate name' bash scripts/build.sh
```

Always run the installed copy at `/Applications/LocalWrite.app`. Do not delete the signing keychain between builds or keep extra app copies in other Applications folders. If you used an earlier ad-hoc build, remove its stale LocalWrite entry from Accessibility and add the installed app once; an enabled switch for the old identity does not authorize the new one. If the stale entry cannot be removed in Settings, `tccutil reset Accessibility com.localwrite.mac` resets only LocalWrite's authorization; grant it again afterward. Subsequent builds retain the same certificate and designated requirement. On macOS 27, this permission may be labelled **Device Control & Data Access** (German: **Gerätesteuerung und Datenzugriff**). Login-item registration is optional and controlled in **Behavior**.

## Verification

```sh
swift test --disable-sandbox --cache-path "$PWD/.build/cache"
codesign --verify --deep --strict --verbose=2 dist/LocalWrite.app
dist/LocalWrite.app/Contents/MacOS/LocalWrite --diagnose
dist/LocalWrite.app/Contents/MacOS/LocalWrite --check-model
dist/LocalWrite.app/Contents/MacOS/LocalWrite --check-model --ollama-model qwen3.5:9b
```

Tests cover paragraph boundaries, selection priority, emoji/UTF-16 cursor handling, empty/oversized inputs, conservative output validation, single-request Rescue behavior, and local-only model routing. `--check-model` uses a fixed sample sentence to exercise the real Apple model and reports correction time. Add `--ollama-model` with a downloaded model name to test Ollama instead. It does not read any open editor. A development command sandbox may block Apple model services even if the model reports ready; run the signed app normally on the Mac.

Manual integration check after granting Accessibility:

1. In TextEdit plain-text mode, type `I definately recieved your mesage.` and leave the cursor at the end. Press the shortcut. Expect `I definitely received your message.` without selecting.
2. Type `thsi is a test AFTER CURSOR`, place the cursor immediately after `test`, and verify that only `thsi` becomes `this` and the suffix remains unchanged.
3. Start a correction and immediately type or switch fields. Verify it is discarded.
4. Trigger **Undo last correction** while the field is unchanged. Then repeat after editing it; the app should refuse to overwrite newer text.
5. Test a browser textarea and a password field. The former requires exposed Accessibility text; the latter must be skipped.
6. Re-record the shortcut, quit, and reopen. Confirm it persists.

## References

- [Apple: SystemLanguageModel and availability](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)
- [Apple: Generating content with Foundation Models](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)
- [Ollama API schema](https://github.com/ollama/ollama/blob/main/docs/openapi.yaml)
- [Ollama structured output](https://ollama.com/blog/structured-outputs)
