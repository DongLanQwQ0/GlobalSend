# 1.0.4 UI delivery checklist

> Historical record. Current requirements, release state and remaining device checks: [UI_ACCEPTANCE.md](UI_ACCEPTANCE.md).

Current scope includes the 1.0.3 workspace redesign and the subsequent interaction requests. The user's current running versions and public center are not switched by local candidate builds.

## Sending and layout

- Desktop: left sending / right receiving; mobile: two pages. At the default Windows 950 x 650 window, every left-pane section remains reachable without an outer scroll. Pending items and device targets scroll internally.
- Toolbar: Text and Clipboard, separator, Sent and File library. Text confirms into a queue; image thumbnails, text excerpts and filenames distinguish queued content. Full-window file/folder/text drop uses a grey mask and dashed rounded border with `松手`.
- Default device click sends immediately and consumes the confirmed batch after success. `多选` explicitly changes clicks to selection and adds a send confirmation. Failed recipients retain their progress; successful recipients are not resent. New input added during a send stays queued.
- Shared group editor remains distinct from staged messages and clipboard synchronization.

## Receiving and content

- Two-column rounded cards show thumbnails/text excerpts, size and receipt time. Route and save details stay in the details view. Sent originals remain external references, not copies.
- Whole cards drag out; desktop right-click opens the same actions as More. Windows mouse drag and touch/pen long press coexist with touch scrolling.
- One prominent new-content dialog shows the sender and preview, supports whole-content drag, copy and Escape/Close. It updates rather than stacking, preserves history, and waits while an unconfirmed editor is active.
- Text readers use one `复制` action with full-body semantics; outgoing messages can be edited, incoming messages viewed/copied. Text files and images preview in-app.
- Explicit Ctrl+V and Clipboard accept text, images, files and folders; text in an editor replaces the current selection instead of being staged unintentionally.

## Settings and lifecycle

- Clear connected text/icon badge, animated Settings transition, consistent rounded settings cards, concise text, device naming, receive directory, default one-day cleanup and category/size filters.
- Web defaults to its serving center plus deployment prefix. One password eye control, no redundant group explanation or Advanced/server expanders. Center serves API/relay and optional Web on one port, Web enabled by default.
- Device refresh button and immediate startup/resume/focus refresh; only online targets appear.
- Windows remembers normal bounds/position and maximized state, defaults to 950 x 650. Tray close preserves receiver core while unmounting UI/image cache; restore preserves unconfirmed drafts, explicit Exit terminates normally.
- Android keeps the cached receiver engine and foreground service across Activity detach; new/edited/shared text and received files use chat notifications with latest full-text copy and correct open destination. Floating dock/service/overlay permission are removed. Background popup has an explicit user/system permission path rather than a disguised call/alarm.

## Evidence already available

- `artifacts/logs/native-batch-send-1.0.4.log`: four send-batch contract checks.
- `artifacts/logs/native-batch-and-reader-1.0.4.log`: 11 batch/reader/real-center notification checks, including foreground/background-disabled lifecycle separation.
- `artifacts/reports/windows-tray-1.0.4.md`: component bounds/tray/persistence/channel evidence and corrected WinMain compile failure.
- `artifacts/reports/windows-clipboard-paste.md`: native format import and UI dispatch evidence; includes the irreversible clipboard-restoration incident. No further system clipboard writes are authorized for this run.
- `artifacts/reports/windows-file-reveal.md`: native exact PIDLs/Shell open and Dart bridge evidence. A subsequent read-only Explorer snapshot showed the correct fixture directory, three items and one selected 27-byte item; the only 27-byte file is `中文 空格,逗号.txt`. UI Automation did not expose a selected-item name.
- `artifacts/logs/windows-touch-runtime.log`: WinRT manager/data path and correct teardown; `windows-touch-widget-and-notification-route.log` covers gestures.
- `artifacts/screenshots/android-workspace/runtime-results/`: actual API 36 drag preview, import/SAF and notification shade/copy/open evidence for the production component consumer.
- `artifacts/reports/center-web-option.md`: 37 server tests and actual built HTTP/WS/relay evidence. Docker CLI is unavailable, so this does not prove container execution.

## Delivered candidate and remaining evidence

- Native UI implemented and rendered at 934x611 (the 950x650 outer-window client area) and 390x844; device mouse-wheel scrolling, direct/multi sending, receipt, context menus, settings and tray drafts have completed interaction checks. Report: `artifacts/reports/native-ui-1.0.4.md`.
- Matching Web implemented, final independent Edge/real-center 17 checks passed, latest candidate frozen at `artifacts/candidates/web-workspace-1.0.4-ui-final`. Report: `artifacts/reports/web-ui-1.0.4.md`.
- Android popup permission path implemented and consumed by Settings; six native notification checks passed. Report: `artifacts/reports/android-popup-1.0.4.md`.
- Windows ZIP 25,629,733 bytes and arm64 APK 18,778,916 bytes built as 1.0.4+5. Version/ABI/signature/permissions checked, only four arm64 SOs. Manifest: `artifacts/releases/GlobalSend-1.0.4-manifest.json`. The compiled Windows app received PNG/HTML using an isolated real center, then its own fixture was stopped. No automatic user-client replacement or deployment.
- Physical Windows touch cross-app drop and full Android Home/screen-off/Doze/process recovery are not established by component/widget checks. The earlier combined Android runtime command was denied before dispatch; do not split or reroute it. `artifacts/logs/android-background-refused-command.txt` records the actual restriction.

Cleanup is separate: `scripts/Clean-OldArtifacts.ps1` previews the reviewed 37 old build/candidate/release targets and deletes only with `-Delete`. The agent did not run deletion mode. The subsequent manual-run report records all 37 deleted, reclaiming 1,357,738,405 bytes; their paths were confirmed absent. Current releases, source, received content and backups remain outside that list.
