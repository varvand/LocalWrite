# LocalWrite

A native macOS menu bar utility that fixes spelling where you are already typing, using an on-device LLM. Built with Swift, AppKit, SwiftUI, Accessibility, and Apple Foundation Models. [Sparkle](https://sparkle-project.org/) provides signed app updates.

Settings use Apple's native Liquid Glass materials and controls, with [sidebar navigation](https://developer.apple.com/design/human-interface-guidelines/sidebars) and a blue-purple color scheme. One persistent glass highlight moves between every settings page. Text editors retain readable backgrounds, and the window respects the system's Reduce Transparency setting.

**[Download LocalWrite for macOS](https://github.com/varvand/LocalWrite/releases/latest/download/LocalWrite.zip)** · [All releases](https://github.com/varvand/LocalWrite/releases)

The download contains the built `LocalWrite.app`; no Xcode or source build is needed. Requires **macOS 26 or later and an Apple Silicon Mac (M1 or newer)**. Local models are supplied by Apple Intelligence or a separate Ollama installation.

## Download and install

1. Download **LocalWrite.zip** using the link above, then double-click it in Finder to extract the app.
2. Drag **LocalWrite.app** into **Applications**, then open that copy directly in Finder. If you already opened the downloaded copy, choose **Quit LocalWrite** from its menu-bar menu first. Closing Settings does not quit the app.
3. The app is signed with a persistent self-signed certificate and is **not notarized by Apple**. If macOS blocks the first launch, and you trust this release, open **System Settings → Privacy & Security → Open Anyway**, then confirm **Open**. See [Apple's instructions](https://support.apple.com/en-us/102445). Keep macOS security protections enabled.
4. In LocalWrite's **General** settings, enable **Accessibility** for the installed app so the shortcut can edit the focused text field.
5. Use Apple Intelligence with its on-device model enabled, or select **Ollama** in **Local models** after installing Ollama and downloading a text model. Future app updates are available through **Check for Updates…**.

Each successful release publishes the complete app as **LocalWrite.zip**, alongside the versioned archive used by automatic updates. Download the app ZIP rather than GitHub's **Source code** archives. Intel Macs are not supported by the prebuilt download.

## Use

1. Open `/Applications/LocalWrite.app`.
2. In **General**, click **Allow Accessibility…**, then enable **LocalWrite** in macOS System Settings → Privacy & Security → Accessibility.
3. Put your cursor in a text field and press **Control–Option–Space**. You don't need to select anything. The shortcut runs when you release the keys.
4. Change the shortcut by clicking its recorder in Settings. Include Control, Option, or Command. Escape cancels recording. Conflicting registered shortcuts are rejected.

By default, **Current line before cursor** corrects exactly the text from the editor's native line start to your insertion point. Text after the cursor stays untouched. You do not select anything yourself. LocalWrite briefly selects backward with Command–Shift–Left, copies that exact text, then returns the cursor before asking the model. It rechecks the same prefix before pasting and leaves the cursor after the corrected text. Wrapped-line behavior follows the editor's native Command–Left command.

Choose **General → Correct → Current list or sublist** to correct a group of points without selecting them. Put the cursor after a word in any point and press the same shortcut. All sibling points at that indentation level, their indented continuation lines, and their nested points are corrected together in one model request. A cursor inside a nested sublist targets that sublist; parent points and neighboring sublists remain untouched. Bulleted, numbered, task, and plain Unicode bullet lists are supported. Empty lines between list items are allowed; ordinary paragraphs, headings, and parent items bound the list. Lists are limited to 4,000 characters.

List mode reads native document selections to locate the cursor, verifies the exact selected list before pasting, and restores the cursor through the spelling changes. It selects from the nearest edge and uses native Select All when the list fills the editor, avoiding unnecessary character navigation. Input tracking ignores LocalWrite's tagged editing events and runs only during correction or undo; it counts input without retaining keys or text. It uses Copy and Paste and restores your clipboard, like current-line mode. Only the targeted list is sent to the local model. The model proposes spelling edits; LocalWrite applies them without regenerating markers, indentation, checkboxes, or line breaks. Cursor positions inside fenced code blocks are skipped.

Optional paragraph and entire-field modes use Accessibility offsets and support an explicit selection. These advanced modes depend more on the editor's Accessibility implementation; current-line and list modes use native keyboard selections for Obsidian and other Electron editors.

The menu bar icon opens Settings, cancellation, **Check for Updates…**, and **Undo last correction**. Undo works only while the original field still contains exactly the applied result. It stores a single correction in memory until quit; no text is saved to disk by LocalWrite.

## App updates

Development happens on `development`. Changes are bundled there, then merged into `main` when a release is ready. Development pushes run tests without publishing an app update; only `main` publishes releases and updates the signed feed.

LocalWrite checks for updates hourly. Choose **Check for Updates…** in the menu bar, or use **Behavior → App updates** to check manually and change automatic checking. Sparkle downloads the published app, verifies its Ed25519 signature before extracting it, and offers **Install & Relaunch**. The feed itself is also signed. Updates wait for an active correction to finish before restarting the app. No local compilation is needed; settings and downloaded Ollama models live outside the app bundle.

If updating says the app is running from its download location even after you moved it, macOS may still be running a temporary read-only copy (App Translocation). Choose **Quit LocalWrite** from the menu bar, then open **Finder → Applications → LocalWrite.app** and check again. If a different copy is already running, LocalWrite shows both locations and offers to use the running copy. If the problem persists after fully quitting, use Finder to move the app itself out of Applications and back in before reopening it; if that also fails, replace it with a fresh download. The `--diagnose` command prints the actual running bundle path, which helps distinguish an installed copy from an `AppTranslocation` path. See [Apple's App Translocation notes](https://developer.apple.com/forums/thread/724969).

Every successful `main` build runs on a standard `macos-26` GitHub runner, reuses the existing local code-signing certificate, and publishes a GitHub Release. The signed feed is on the separate `updates` branch. The workflow generates delta patches from the previous three published archives where worthwhile, with a full app archive as fallback. Pull requests run tests without signing secrets or write access. Sparkle is pinned to an exact version and checkout actions to a commit SHA. GitHub's automatic token publishes releases and the feed; no personal GitHub token is embedded in the app.

Before generating deltas or signing a release, the publisher verifies the existing feed with the app's pinned public key. It downloads only the exact historical archives authorized by that feed and verifies their original signatures and sizes before inspecting their contents. App identity, versions, and release URLs must match. A missing or altered feed/archive stops publication. The final feed retains historical signatures and original download links; unknown or changed historical entries are rejected before re-signing. This prevents a modified old download from receiving a fresh trusted signature during a later build.

Private signing keys are stored in macOS Keychain and encrypted secrets in the GitHub `updates` environment, whose deployment policy allows only `main`. Only the **public verification key** appears in `Info.plist`. Private keys, PKCS#12 exports, and passwords never belong in commits, logs, app bundles, release assets, or caches. The release step scans the archive and source for private-key material before publishing. Runner signing files and its temporary keychain are removed in an `always()` cleanup step.

To configure signing on the original signing Mac after signing in with GitHub CLI:

```sh
swift package resolve --cache-path "$PWD/.build/cache"
bash scripts/configure-updates.sh
```

The setup script exports the existing signing identity to a temporary encrypted file outside the checkout, uploads it and its export password directly to encrypted GitHub secrets through stdin, uploads the Sparkle update-signing seed the same way, and removes all temporary exports. It refuses to upload an update key whose public half differs from this app. This requires the original `com.localwrite.mac.updates` Sparkle key in Keychain. macOS may request the dedicated LocalWrite keychain password to export the identity; this password is stored in `~/Library/Application Support/LocalWrite/Signing/keychain-password`, and differs from your login password. Do not paste credentials into chats or source files.

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

The first command creates `dist/LocalWrite.app` with its icon, Info.plist, and pinned Sparkle framework, signs the framework/helpers and app inside-out using a **persistent self-signed local certificate** with hardened runtime, and verifies the signature. Self-signed builds disable library validation to load the bundled Sparkle framework without an Apple Team ID. The certificate and private key live in a dedicated keychain under `~/Library/Application Support/LocalWrite/Signing`. The build does not add a root certificate to system/login trust stores. The app's designated requirement pins that certificate, so its identity is stable across rebuilds. This is not an Apple-notarized build; downloaded releases may need explicit first-launch approval as described above. Standard Developer ID distribution requires an Apple-issued signing identity and notarization. No Apple developer account is needed for the current self-signed build. No app sandbox entitlement is applied, because the utility needs cross-app Accessibility access.

The second command stages and verifies the new app, replaces the whole bundle in `/Applications`, verifies the installed signature, and opens Settings. Replacement discards obsolete files and uses the new bundle's metadata. Quit a running copy before installing a rebuild. Set `LOCALWRITE_INSTALL_DIR` if a different install folder is necessary, and keep that folder consistent. You can also open `Package.swift` in Xcode; use the scripts to produce the full app bundle. A signed `dist/LocalWrite.zip` is also generated to avoid file-provider metadata affecting the bundle in cloud-synced project folders.

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

Tests cover list/sublist boundaries, numbered and task lists, indented continuations, fenced code, paragraph boundaries, selection priority, emoji/UTF-16 cursor handling, empty/oversized inputs, conservative output validation, single-request Rescue behavior, and local-only model routing. `--check-model` uses a fixed sample sentence to exercise the real Apple model and reports correction time. Add `--ollama-model` with a downloaded model name to test Ollama instead. It does not read any open editor. A development command sandbox may block Apple model services even if the model reports ready; run the signed app normally on the Mac.

Manual integration check after granting Accessibility:

1. In TextEdit plain-text mode, type `I definately recieved your mesage.` and leave the cursor at the end. Press the shortcut. Expect `I definitely received your message.` without selecting.
2. Type `thsi is a test AFTER CURSOR`, place the cursor immediately after `test`, and verify that only `thsi` becomes `this` and the suffix remains unchanged.
3. Start a correction and immediately type or switch fields. Verify it is discarded.
4. Trigger **Undo last correction** while the field is unchanged. Then repeat after editing it; the app should refuse to overwrite newer text.
5. Test a browser textarea and a password field. The former requires exposed Accessibility text; the latter must be skipped.
6. Re-record the shortcut, quit, and reopen. Confirm it persists.
7. Choose **Current list or sublist**. Put the cursor after a word in the middle of `- frist point`, `- secnod point`, and `- thidr point` on separate lines. Expect all three spellings to be corrected with markers unchanged. Repeat in an indented sublist and verify that parent points stay unchanged. Add prose before and after the list, and confirm it is not corrected. Test at the end of a list, undo, and input/focus changes during inference.

## References

- [Apple: SystemLanguageModel and availability](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)
- [Apple: Generating content with Foundation Models](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)
- [Ollama API schema](https://github.com/ollama/ollama/blob/main/docs/openapi.yaml)
- [Ollama structured output](https://ollama.com/blog/structured-outputs)
