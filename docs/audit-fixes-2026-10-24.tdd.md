# Audit fixes — TDD evidence (2026-10-24)

## Source

User journeys were derived from the reviewed audit findings in this session. Only findings
that had a complete code path (or a reproducible build/test failure) were implemented; raw
subagent reports and speculative runtime hypotheses were not used as scope.

## User journeys

1. As a user, a single ⌘ tap must not toggle the panel; two complete taps must toggle it once.
2. As a user, pressing a real key during a candidate ⌘ tap must cancel the gesture.
3. As a user, switching apps must never show the previous app's commands under the new app name.
4. As a user, revoking Accessibility must not make cached menus look like live data.
5. As a user, disabled search results must not be executed.
6. As a user, a conflict scan that could not read every app must not claim "no conflicts".
7. As a user, resetting statistics must keep my pinned favourites.
8. As a user, running an older build must not rewrite a newer settings file.
9. As a user, restoring defaults must also unregister the login item and ask for confirmation.
10. As a user, light appearance must keep hotkey keycaps readable.
11. As a user, an empty or one-row panel must not reserve a full page of empty space.

## RED / GREEN evidence

| Guarantee | Test / command | Evidence |
| --- | --- | --- |
| Single ⌘ tap is not a double tap; two taps fire once | `CommandDoubleTapTests` | RED: 16 tests / 6 failures, commit `23cb4b0`; GREEN: 18 focused tests, commit `c83b059` |
| `/` and `-` keys round-trip through usage cache keys | `UsageBreakdownTests` | Same RED/GREEN cycle; legacy keys still decode |
| Future settings schema is read-only | `StorageSafetyTests` | Compile-time RED (missing policy API), commit `9824993`; GREEN 3 tests, commit `55fc9d0` |
| Empty/short panels do not reserve a page | `PanelBudgetTests` | GREEN 3 tests, commit `5427cf9` |
| Natural width fits requested column count | `OverlayMetricsContractTests` | GREEN, 1–4 columns asserted |
| Disabled rows are not actionable; scan outcomes are total | `EnginePolicyTests` | GREEN 2 tests |
| Full suite | `swift test --disable-sandbox` | **431 tests, 0 failures** |
| Full Xcode-beta source build | `scripts/build_swiftc.sh Debug` | **BUILD_EXIT=0**, signed app produced |
| Coverage | `llvm-cov` over `KagiPeekCore` | **82.73% lines**, above the 70% CI floor |
| Launch smoke | `KAGIPEEK_PREVIEW=overlay` on built app | **PREVIEW_ALIVE**, then terminated |

## What was implemented

- Two-complete-tap state machine plus cancellation on any real key press.
- Versioned, reversible usage-key encoding for keys containing `/`, `:` or `-`.
- Settings schema downgrade guard; statistics reset no longer clears favourites.
- Restoring defaults unregisters the login item and both destructive actions require confirmation.
- App-context changes now include PID; old catalog/derived caches are cleared on identity change.
- Catalog memory cache is keyed by app identity, PID, fallback permission, resolved language and Apple-menu setting.
- Accessibility revocation clears cached catalogs and forces a degraded reload; cache reads check the current grant.
- Panel loading uses explicit `isCatalogLoading`; search exposes loading/permission/fallback state.
- Search filters and guards disabled rows at every execution entry point.
- Config scans are generation-gated; cross-app conflicts retain complete/partial/failed coverage.
- Panel row budget uses actual row count up to the page cap; natural column width includes grid spacing.
- Light/dark semantic keycaps, resizable Settings, clearer conflict/favourite empty states, basic VoiceOver row actions.

## Known gaps / not covered by this change

- `UsageStore` and `SettingsStore` are outside the SwiftPM test target; favourites preservation and launch-item unregistering are verified by code review and full build, not an instance-level XCTest.
- Engine/AX composition still lacks an app-target integration test; app-switch and permission tests are static/build evidence only.
- No pixel-level visual comparison or real VoiceOver AX-tree inspection was run.
- `xcodebuild` under this local Xcode-beta installation fails inside the Swift macro plugin server ("malformed response"); the same full source compiles successfully through the project's supported `swiftc` fallback. This was not treated as a source failure.
- Remaining lower-priority audit items (result-count truncation UI, scroll pagination, excluded-app keyboard navigation, some localization polish) are intentionally outside this patch.
