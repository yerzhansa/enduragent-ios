# Language preference

One language preference controls both app text and coach replies. Automatic follows the iPhone language for app text and the athlete's latest message for the reply language. A fixed language controls both and survives a relaunch. Choosing a language does not create a turn.

## Sub-features

- `language-picker` opens Choose your language, marks the current row selected, and lists Automatic plus all 17 supported languages in the order below.
- `language-choose` saves a different choice immediately and keeps the picker open in the selected language. The next reply receives that preference.
- `language-automatic` has no saved fixed language. The reply follows the message language, then the iPhone language when the message gives no language evidence.
- `language-same` keeps the selection without adding another preference record when the current row is tapped again.
- `language-survives` uses the saved language on the first frame after relaunch, including the welcome and composer.
- `language-save-failed` preserves the current choice and shows `language.saveFailed` if the preference cannot be stored.
- `language-notices` renders notices and review outcomes through the chosen phrasebook. A notice without a translation uses its English catalog value.

| Order | Choice | Identifier |
| --- | --- | --- |
| 1 | Automatic | `language.choice.automatic` |
| 2 | English | `language.choice.en` |
| 3 | Español | `language.choice.es` |
| 4 | Français | `language.choice.fr` |
| 5 | Italiano | `language.choice.it` |
| 6 | Deutsch | `language.choice.de` |
| 7 | Nederlands | `language.choice.nl` |
| 8 | Dansk | `language.choice.da` |
| 9 | Svenska | `language.choice.sv` |
| 10 | Norsk bokmål | `language.choice.nb` |
| 11 | Suomi | `language.choice.fi` |
| 12 | Português (Portugal) | `language.choice.pt-PT` |
| 13 | Português (Brasil) | `language.choice.pt-BR` |
| 14 | Polski | `language.choice.pl` |
| 15 | 한국어 | `language.choice.ko` |
| 16 | 日本語 | `language.choice.ja` |
| 17 | 简体中文 | `language.choice.zh-Hans` |
| 18 | 繁體中文 | `language.choice.zh-Hant` |

## How to get to it (user POV)

- Type `/language` and send, or choose it from the slash list and send the filled command.
- Choose Menu, Debug, Language through `debug.language`.
- Select a row. Close the command sheet with `language.close`; use Back when the picker was pushed from Debug.

## Driving it with sim.mjs and XCUITest

Preconditions:

- Follow the [index](./README.md) setup. The proofs launch fresh unless they explicitly relaunch their saved state.

| Action and command | Observable result and attachment |
| --- | --- |
| `sim.mjs test <run id> LanguagePickerProof` | Checks all 18 rows in order, selects French, and checks `Choisis ta langue`, `Automatique`, the Conversation title, and `Écris à ton coach`. Attachments are `language-picker-auto`, `language-picker-fr`, `m1-12-language-fr`, and `m1-12-language-survives`. |
| The same `LanguagePickerProof` run sends the week question and taps French twice | `fixture.replyLanguage` begins `The athlete chose French (Français).`; after relaunch Records contains `languagePreference 1`. `language-switch-seconds` compares the first selection with the unchanged selection. |
| `sim.mjs test <run id> AutomaticFrenchPhoneProof` | A French phone with Automatic shows French app text. Its English week question produces a reply instruction ending `reply in English (English).`; `m1-12-automatic-fr-phone` shows the conversation. |
| `sim.mjs test <run id> SavedLanguageFirstFrameProof` | Spanish chosen on an English phone remains Spanish through relaunch. `saved-spanish-first-frame-strings` lists observed strings; `m1-12-saved-spanish-first-frame` shows the screen. |
| `sim.mjs test <run id> TutorialWaitProof` | The shared wait checks a satisfied condition immediately and samples a changing condition again within 0.5 seconds. This protects the snapshot sampling used by the saved-language first-frame proof. |
| `sim.mjs test <run id> FrenchNoticesProof` | The exhausted-credits notice, Buy Credits action, and Send message label use the French catalog values, `notices-french`. |
| `sim.mjs test <run id> ReviewLanguageProof` | French review title, controls, and saved Done line, before and after relaunch, `review-french`, `review-french-relaunch`. |

For the Debug entry point, open `chat.sidebar`, `sidebar.debug`, and `debug.language`, then select a row and go Back. Capture `sim.mjs shot <run id> language-debug-entry`. No dedicated XCUITest class proves this alternate entry. The hosted app test `aLanguageThatCannotBeSavedKeepsTheCurrentChoice` covers a failed save; there is no fixture directive for that write failure.

Run `sim.mjs parity <run id> language-picker-auto light --from <attachment>` and the corresponding `language-picker-fr` command when visual parity is in scope. Compare the ordered choices and selected row.

## Gotchas

- The row's selected accessibility trait identifies the choice. Its checkmark is hidden from accessibility.
- Scroll upward through the list to find the final rows. A downward swipe at the top can dismiss the sheet.
- Language names stay in their own languages. The title and Automatic translate.
- Product Menu, Credits, History, and other chrome now use catalog values. Debug-only labels can remain English.
- Fixture replies are scripted. `fixture.replyLanguage`, the instruction supplied to the model, proves reply-language selection more reliably than the fixture reply text.
- `-AppleLanguages` changes the phone language for Automatic. A saved fixed preference overrides it.
- The language switch timing includes XCUITest settling time. Compare it with the already-selected row tap from the same run.
- `TutorialHarness.wait` uses native existence and foreground waits. Custom conditions, including first-frame snapshots, run immediately and at 10 ms intervals. A matching reply label can appear while a turn is streaming. Wait for `chat.working` to be absent before asserting settlement, or use `exchange` for a completed turn.
