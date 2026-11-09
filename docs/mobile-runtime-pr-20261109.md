# PR Title

fix(app): sync video, incident recovery, reports and fixed road policy

# PR Body

## Summary

- Sync missing validated client runtime changes into the root Flutter app, preserving existing matching code, dependencies, assets and platform configuration.
- Use signed network video playback on web and local file playback on devices; show the actual received impact value and use the app's 1.5G threshold.
- Route MQTT-triggered incidents before upload completes, retry event-to-case/video lookup, and resume timed-out analysis jobs without creating another job.
- Batch road, movement and context edits behind explicit reanalysis; ordinary demos use parking (5), while server-locked reference roads keep their expert model and optional signal/roundabout actions remain editable.
- Restore report/home navigation, richer PDF evidence/map output, and separate report-only deletion from video/case deletion. Fence asynchronous PDF preparation to the original account and report.

## Verification

- Pinned offline image: `violet-app-verify:emergency-20261109`, Flutter 3.47.8 / Dart 3.13.7.
- Focused regression set: 102 passed, including the donor's 29 policy/input tests plus a new PDF account-change regression.
- Full suite: 309 passed / 16 failed; untouched main: 276 passed / 18 failed. Every remaining failure also occurred on the baseline. No unrelated test fixes bundled.
- Release web compilation passed using a generated disposable scaffold; analyzer has no errors, 2 existing unused-import warnings and 30 informational notices.
- No native release/signing, physical-device, live MQTT, deployed backend, Pi, emergency-call or SMS acceptance performed.

## Integration Notes

- Requires the backend metadata, hardware-event, report filtering/deletion and existing analysis/media contracts documented in [the handoff](mobile-runtime-handoff-20261109.md).
- No backend changes, deployment, container exports, videos, credentials or platform config changes. Existing tracked Firebase client keys remain unchanged and need separate owner review.
- Donor-only emergency contacts/SMS were intentionally excluded. The single 15-second countdown only advances to the first-response guide; it dispatches nothing.
- Intended target: `noobcoderbkr/dae-byeon-box-app:main`, not `pth888`. Parent reviews the final diff and creates the PR; this task only prepares and pushes the new branch.
