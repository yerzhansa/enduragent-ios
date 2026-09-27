# Language

The athlete chooses one language for the app text and the coach's replies. `/language` opens `Choose your language` with `Automatic` and the 17 languages, each in its own name, and a checkmark on the current choice. `Automatic` follows the iPhone language for the app, and the coach replies in the language the athlete writes in. A fixed language sets both. The choice is saved and survives a relaunch.

## Sub-features

- `language-picker` opens as a sheet from `/language`, titled `Choose your language`, with `Automatic`, `English`, `Español`, `Français`, `Italiano`, `Deutsch`, `Nederlands`, `Dansk`, `Svenska`, `Norsk bokmål`, `Suomi`, `Português (Portugal)`, `Português (Brasil)`, `Polski`, `한국어`, `日本語`, `简体中文`, and `繁體中文` in that order. The checkmark marks the current choice, and `/language` sends no message and starts no model call.
- `language-choose` saves the tapped language at once. The sheet stays open and re-renders in that language, so `Français` turns the title into `Choisis ta langue` and `Automatic` into `Automatique`. After `language.close`, the chat title reads `Conversation`, the composer reads `Écris à ton coach`, and the next reply's request carries `The athlete chose French (Français).`, read in Debug as `fixture.replyLanguage`.
- `language-automatic` is the default. The reply-language section reads `No language is saved.` and falls back to the language of the athlete's message, then the iPhone language.
- `language-same` writes nothing when the athlete taps the language that is already selected.
- `language-survives` reopens in the chosen language after a relaunch with the kept store, and Records lists `languagePreference 1`.
- `language-save-failed` keeps the checkmark on the current choice when the choice cannot be saved and shows `Couldn't save Deutsch. Replies stay in Français. Try again.` in `language.saveFailed`, or `Couldn't save Deutsch. Replies stay in the language of each message. Try again.` while `Automatic` is current.

## How to get to it (user POV)

- In the chat, send `/language`.
- Choose `Menu`, then `Debug`, then `Language`.

## Driving it with sim.mjs and XCUITest

Preconditions:

- `sim.mjs doctor <run id>` exits 0 and the app is installed.
- For interactive steps, the app is on the chat after onboarding.

- **Choose French.** Run `sim.mjs test <run id> LanguagePickerProof`. It sends `/language`, finds `language.choice.automatic` selected and the 18 rows in order, taps `language.choice.fr`, waits for `Choisis ta langue`, closes the sheet, and checks the French chat title and composer placeholder. It sends the week question and reads `fixture.replyLanguage`, then relaunches with the kept store and reads `languagePreference 1` in Records. Attachments `language-picker-auto`, `language-picker-fr`, `m1-12-language-fr`, and `m1-12-language-survives` show each state, and `language-switch-seconds` holds the time from the tap on `Français` to the French title beside the time of a second tap on `Français`, which is already selected and changes nothing. XCUITest's tap waits for the app to settle, so judge the switch against that second tap, not on its own.
- **Parity.** Run `sim.mjs parity <run id> language-picker-auto light --from <language-picker-auto attachment>` and `sim.mjs parity <run id> language-picker-fr light --from <language-picker-fr attachment>`. Compare the choices, their order, and the checkmark row.
- **Save failed.** The hosted test `aLanguageThatCannotBeSavedKeepsTheCurrentChoice` makes the next `languagePreference` write fail and checks the sentence. No directive reaches this state on the simulator.

## Gotchas

- Language rows are buttons named `language.choice.<id>`, where `<id>` is `automatic` or the language tag such as `fr`, `pt-BR`, or `zh-Hant`. The checkmark is hidden from accessibility; the current row carries the selected trait, so check `isSelected`.
- The sheet is a list, so the last rows exist for XCUITest only after scrolling. Scroll the sheet up, never down from the top, because a downward swipe at the top dismisses the sheet.
- Endonyms never translate. Only `Automatic` and the title change with the language.
- The menu, `Menu`, `Debug`, `Credits`, and `History` labels are not translated yet, so they stay English in French.
- `-AppleLanguages` sets the iPhone language that `Automatic` follows. A fixed choice overrides it.
