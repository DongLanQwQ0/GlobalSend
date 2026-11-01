# Android / iPad completion audit

Scope: current source after `8896a68`, inspected on 2026-11-01. Android and iPad were not operated. Existing user acceptance is retained for unchanged paths; source implementation and actual device acceptance are distinguished below.

## Current gaps fixed during this audit

1. iPad media discovery used a once-per-process gate. After the first batch, new media and source deletion were never rescanned. `client/lib/recent_photos.dart` now listens to PhotoManager library changes and refreshes on foreground restoration. It validates active asset IDs, preserves current suggestions, filters handled IDs, and orders new batches first without reversing equal-time items.
2. iPad media expiry was a wall-clock timer from discovery, bypassing the existing viewport/interaction reports. Each item now has its own remaining 30-second visible-idle budget. Hidden/offscreen/interaction periods do not spend that budget. Pending IDs, timestamps and remaining time survive screen recreation; expired/dismissed IDs remain handled.
3. iPad media suggestion cards lacked a native drag source. `screen.dart` now wraps only iOS media suggestions in `IOSDragSource.media`. UIKit loads the original Photos resource lazily through a typed file provider, keeps or corrects its actual suffix, and uses the existing card-sized preview. Accepted native drops remove the suggestion; cancellation keeps it. The provider owns and removes its temporary export when its lifetime ends. Tap-to-stage uses PhotoManager `originFile`, not converted image bytes.

Android's native shared suggestion feed, native drag, and Windows drag visuals were not replaced. iOS Photos discovery reads the Photos library, not this app's received-file directory; received files are not inserted into Photos by this path.

## Requirement evidence map

| Requirement | Actual current evidence | Acceptance boundary |
| --- | --- | --- |
| Android suggestions: 30 seconds only while visible and idle | `TemporaryShelf.java` remaining-time accounting, visible surfaces and interaction set; `ReceiveOverlay.java` viewport/interactions; native feed shared with main screen | Existing Android implementation retained |
| iPad media recommendations: new/deleted media, ordering and visible-idle expiry | Fixed in `recent_photos.dart`; source/controller tests cover change events, deletion, new batches, hidden/interaction pause, per-item budget and restoration | Pure-source tests pass; new iPad behavior needs the next IPA/device pass |
| Clipboard and media suggestion dragging | Existing Android feed and accepted native device-highlight paths; iOS `IOSDragSource` registers real clipboard revision or Photos asset ID, not card-label text | iPad clipboard/card shadow in 103 and new media-provider physical behavior remain pending manual acceptance |
| Staging after successful drop: 3-second red removal, tap/drag cancels | `TemporaryShelf.exported`, `pendingRemoval`, `cancelRemoval`; suggestions disappear immediately only after accepted export | Existing source implementation and prior Android acceptance retained |
| Received images should not be recommended again | `RecentMediaSuggestions.java` excludes `ReceivedFilePublication.receivedPaths`; receive publication records before scanner events | Existing Android file visibility / receive behavior accepted by user |
| Handle, physical edge, damping, movement, resize, rotation and remembered position | `ReceiveOverlay.java`: physical X bounds, centered handle, `OverScroller` friction x8, mirrored geometry animation, raw touch offset, in-place resize and display reflow | `artifacts/screenshots/phone48-usb-resumed/acceptance.json`; user accepted window/drop and restart memory |
| Receive/staging separation, 2-second send-device mode and smooth edge scrolling | Separate receipt/shelf collections; `ReceiveOverlay` forwarding state and hover timer; Choreographer fractional edge scroll | Existing implementation retained; do not reopen accepted drop behavior |
| Native media picker and APK selection/opening | Existing Android picker/APK actions and `AndroidFileOpener`; no drag interception rewrite on Android | Prior user acceptance retained |
| File-picker visibility, external directory and migration | `ReceivedFilePublication.java` scans final files into system index; `ReceiveDirectory.java` handles granted document URIs; `SavedFilesStore.setReceiveDestination` streams migration, commits new references, then removes old owned bytes | User confirmed new received files visible in Recent and picker without moving |
| Background reception and fallback notifications | `BackgroundReceiveService` foreground runtime/START_STICKY; `ReceiveNotifications.show` attempts popup and only falls back to notification when unavailable | OEM background behavior remains subject to OS permission; no new accessibility service added |
| Shared editor remains quiet; undo survives remote synchronization | `ReceiveNotifications.show` returns for shared target; `shared_edit_history.dart` keeps undo on same-scope synchronization | Existing implementation retained |
| iPad per-card native lift, cancel and in-session preview | `FileSharing.swift` targeted per-card previews and real `didEndWith` delegate; `IOSDragSource` captures only its repaint boundary and excludes controls | 103 widget/IPA build evidence exists; manual shadow/lift check still pending |
| iPad original filenames, system share and unique-ID destinations | `SharedImportedFileName`, common shared inbox loader, AppGroup re-sign fallback, `SharedSendTarget.deviceId`; new media provider uses original resource UTI | Existing 103 suffix fixture + CI evidence; user manually signs/installs |
| iPad swipe back | `ios_back_swipe.dart` current-navigation edge gesture and `maybePop` | Existing implementation retained |

Root separately owns the discovered missing iPad clipboard suggestion timestamp fix; it must be integrated with these changes, not duplicated here.

## Checks and remaining handoff

- `flutter test --no-pub test/recent_photos_test.dart test/ios_drag_source_test.dart --reporter expanded`: **20 passed**. Log: `artifacts/tmp/ipad-media-audit-tests.log`.
- Focused `flutter analyze` for the two implementation files and two test files: **no issues**. Log: `artifacts/tmp/ipad-media-audit-focused-analyze.log`.
- Analysis including the large existing `screen.dart`: no errors/warnings; existing style-only infos recorded in `artifacts/tmp/ipad-media-audit-analyze.log`.
- `git diff --check` for this assignment's six modified source/test files passed.
- Final lifecycle correction: `SendScreen.dispose` calls `RecentPhotos.dispose` directly. The model now spends and saves its last visible interval on disposal; state writes are serialized across replacement models, and loading waits for the preceding write. The targeted test starts the replacement immediately (no preceding `setVisible(false)` or caller-side write wait) and passed: `artifacts/tmp/ipad-media-dispose-test.log`. The 20-test result above predates this final targeted correction; this focused test is its additional evidence.
- New Swift Photos provider requires macOS/iOS compilation in the final IPA build. It was not compiled on this Windows machine. Physical iPad checks should verify media suggestion long-press -> correct per-card shadow -> drop to another app and to an app device card; cancellation retains the suggestion, accepted drop removes it, and original image/video suffix survives.
- No phone/iPad/Windows UI, ADB, emulator, application data, Git state, or release operations were performed by this audit assignment.
