# Mobile Runtime Handoff

Target: `noobcoderbkr/dae-byeon-box-app:main`.
Base: `e09eb2e321e4939ef2dea3592eb647ecb8dcdc72`.
Branch: `fix/app-runtime-sync-20261109`.
Old `fix/mobile-app-client` head `a3fcf34bb7228f68912ba79a6ddbc5688400fcd4` was inspected: its completion exit is superseded by report/home navigation here.

## Scope

Root `lib/` and `test/` only, plus README/handoff documentation. No nested `app-client/`.
Matching dependencies/assets/platform code are unchanged. Donor source was read only.
Includes web/network versus native/file video handling, 1.5G app threshold, received-G display, hardware-event sequence and recovery, report/PDF/map navigation, explicit batched reanalysis, demo parking and fixed-road metadata.
PDF preparation stops old-case fetches after account/session/report changes.
The donor's separate emergency-contact/SMS feature is omitted; the single 15-second confirmation countdown only advances to the guide and sends no messages/calls.

## Backend Requirements

- Authenticated `GET /api/v1/cases/{id}` must return owned case metadata, including `demo_mode` and optional `road_policy: {locked: true, place: <0..7>, reason: ...}`. Invalid locked places are rejected before analysis.
- Ordinary demos default to parking (5). Only the exact four existing reference source IDs are mapped server-side to experts 1/3/6/4. The app never guesses a lock from editable titles or broad filename matching. A locked road chip does not lock the optional signal/roundabout action.
- `GET /api/v1/hardware-events?limit=20` returns `data.events` with event/device/source-device IDs, device name, UTC trigger, source, test flag, optional `impact_g` and owned `case_id`. Missing G is displayed as unavailable, never replaced by the detection threshold.
- `GET /api/v1/cases/latest-hardware` returns an owned case or null. `GET /api/v1/cases/by-event?device_id=...&event_id=...&trigger_utc=...` returns the matching owned case; 404 means upload/case registration is not ready yet. The guide retries without inventing a phone-sensor case.
- Existing analysis POST/job/report APIs must preserve exact case/job/report identity. Reanalysis accepts the batched road/action/facts/keywords/movement payload. The server must enforce fixed-road policy too; disabling chips is not authorization.
- Existing paginated files, signed video access and case-map APIs remain required. Web playback needs browser-reachable storage, suitable CORS and valid signed URL lifetimes. Web map fallback uses OpenStreetMap and exposes the shown GPS coordinate to that service; configure network/CSP policy accordingly.
- `GET /api/v1/cases?has_reports=true` filters report history. `DELETE /api/v1/cases/{id}/reports` must return 200 with matching `case_id`, `status: reports_deleted`, `media_preserved: true`; 409 rejects deletion while analysis runs. `DELETE /api/v1/cases/{id}` keeps the existing 202 `delete_requested` contract for explicit whole-case deletion.

## Verification

Offline disposable containers only, image `violet-app-verify:emergency-20261109` at `sha256:2a21a1af62b93335ed1e11843e5dbddf4439e4b86ab554639dc9512fc7b0a24c`.
SDK: Flutter 3.47.8 (`737ba8f885`), Dart 3.13.7.
After `flutter pub get --offline`, all test commands used `flutter test --no-pub --reporter expanded`.

- Focused 10-file regression set: 102 passed. Files: `demo_analysis_policy`, `fixed_road_metadata`, `analysis_screen_model_input`, `accident_countdown`, `pdf_report_privacy`, `final_app_regression`, `case_service`, `model_analysis_service`, `blackbox_video_service`, `delete_separation` (all `test/*_test.dart`).
- Three policy/input files: 30 passed (29 donor tests plus the new PDF owner-change regression). Missing-policy/batching behavior and the PDF account-change regression were observed failing before the corresponding fixes.
- Full suite: 309 passed, 16 failed; untouched base: 276 passed, 18 failed. Remaining failure names are a subset of baseline failures, not a claim of an entirely green suite.
- `flutter analyze --no-pub`: no errors; 2 unused-import warnings in untouched `timeline_dashboard_screen.dart` / `weather_safety_card.dart`, plus 30 informational notices, including donor style and `dart:html` deprecations. Exit remains nonzero.
- `flutter build web --release --no-pub --no-wasm-dry-run`: passed with a temporary SDK-generated web scaffold because this mobile repository has no tracked `web/`. No generated scaffold/build output was added. Existing optional macOS-plugin and Cupertino-font warnings remain.
- Native Android/iOS builds, signing, browser playback against real signed URLs, physical sensors/FCM, live MQTT/backend/collector, Pi and emergency-call/SMS behavior were not tested. No live deployment was performed.

Remaining baseline failures (exact test descriptions):

- `local_files_test.dart`: account cleanup propagates file deletion failures
- `task5_services_test.dart`: case-scoped chatbot state refuses to send accident advice without an active case
- `latest_hardware_video_test.dart`: main latest-video entry opens the exact returned hardware case
- `latest_hardware_video_test.dart`: main latest-video entry keeps the page on no file
- `latest_hardware_video_test.dart`: main latest-video entry disables overlapping loads
- `latest_hardware_video_test.dart`: main latest-video entry exposes auth errors without navigating
- `latest_hardware_video_test.dart`: waiting video offers explicit latest-case recovery without fallback
- `widget_test.dart`: BlackboxApp boots the real app shell at 320px
- `task4_async_races_test.dart`: delayed case load-more cannot append after refresh
- `task4_async_races_test.dart`: refresh clears report-loading locks and ignores old completion
- `task4_async_races_test.dart`: history report opens exact version read-only without analysis POST
- `task4_async_races_test.dart`: late PDF scan cannot expose a previous user after login
- `task4_async_races_test.dart`: 202 case deletion cleans media and preserves manual PDF delete
- `task4_async_races_test.dart`: local cleanup failure warns without restoring accepted case
- `task4_async_races_test.dart`: accepted 202 cancels matching video after reports screen disposal
- `task4_async_races_test.dart`: missing original video keeps final-step analysis disabled

## Credential And Review Boundary

Local Git credential manager and GitHub CLI identity were both verified as `noobcoderbkr` without displaying credentials. No connector writes are used.
Pre-push scan: 35 staged files passed the path allowlist and credential-pattern checks; 2 distinct actual donor credential values were compared in memory with zero matches in staged content. No credential values were printed or added to history.
Existing base already tracks Firebase client keys in `lib/firebase_options.dart` and `android/app/google-services.json`; both remain byte-for-byte unchanged. Owner should separately review restrictions/rotation. This PR does not add or sanitize them, and does not contain Firebase Admin credentials.
No `.env`, platform Firebase configuration, videos, APK/IPA, build/cache/signing files, backend code or container exports are added.
Author self-review only; parent must review the final base-to-head diff and decide PR readiness. No PR creation, merge or force push is authorized here.
Local verification evidence is retained under this clone's `.git/codex-*.log` and is not committed.
