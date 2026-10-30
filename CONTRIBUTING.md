# Contributing to Irekobox

Thanks for helping. Bug reports, fixes and translations are all welcome.

## Reporting a bug

Open an [issue](https://github.com/sirruf/irekobox/issues). In Irekobox,
**About Irekobox › Copy System Info** copies the app, macOS and `container`
versions and the engine status; paste it into the issue. Say what you did,
what you expected and what happened instead.

## Before a larger change

Open an issue first and describe the change, so we can agree on the approach
before you spend time on it.

## Building and testing

See [Building](README.md#building) and [Tests](README.md#tests) in the README.
Before sending a pull request, run:

```sh
scripts/test-all.sh
```

## Conventions

- **Dependencies.** The app has two (SwiftTerm and Yams). New ones need a good
  reason; prefer a small piece of our own code.
- **Interface.** Follow the macOS Human Interface Guidelines and use system
  controls. Toolbar actions are icons with a tooltip.
- **Text.** Write interface text in plain language, from the user’s side: what
  something does, not how it’s built. Errors say what happened and what to do.
- **Localization.** Irekobox ships in English, Russian, Simplified Chinese,
  Japanese and German. Keep interface text localizable (string literals in
  SwiftUI views, `String(localized:)` elsewhere). After changing interface text,
  run `scripts/sync-strings.sh`; new keys arrive untranslated in
  `Sources/Irekobox/Resources/Localizable.xcstrings`.
- **Commits.** One change per commit, with a message that says what changed
  for the user, in English.

## License

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE).
