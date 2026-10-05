# MosaicRestore v1.0.1 Beta Testing

## Beta release

Target prerelease:

`v1.0.1-beta.1`

Desktop version:

`1.0.1 (102)`

Beta is feature-frozen. During Beta, only bugs, compatibility problems,
installation problems, security issues, and release-blocking defects should
be changed.

Do not add new product features during Beta.

---

## Goal

Validate MosaicRestore as an installable end-user macOS product, not only as
a development build.

The primary Beta question is:

> Can a normal Apple Silicon Mac user install MosaicRestore from the DMG,
> launch it, process videos locally, configure Cloud, recover from common
> errors, and understand the UI without developer intervention?

---

## Supported Beta platform

- macOS
- Apple Silicon
- Local processing: Lada / Metal / MPS
- Cloud processing: provider-neutral Cloud configuration
- Ad-hoc signed build
- Developer ID signing and notarization are not part of this Beta

Because the Beta is ad-hoc signed, macOS may require Open Anyway on a new
machine.

---

## Recommended tester pool

Target: 3–5 Macs.

Prefer coverage across:

- Apple M1 / M2
- Apple M3
- Apple M4
- Different macOS installations where practical

At least one tester should be a person who did not participate in development.

---

# Test Checklist

## A. DMG and installation

- [ ] DMG opens successfully
- [ ] MosaicRestore.app is visible
- [ ] Applications shortcut is visible
- [ ] App can be copied to `/Applications`
- [ ] App icon displays correctly in Finder
- [ ] App icon displays correctly in the tester's launcher
- [ ] App launches
- [ ] macOS security flow is understandable if Open Anyway is required
- [ ] App relaunches after quitting

Expected version:

`1.0.1 (102)`

---

## B. First-run UI

- [ ] Main window opens correctly
- [ ] Window controls render correctly
- [ ] Product icon renders correctly
- [ ] Local and Cloud are the only normal processing choices
- [ ] Local is understandable without technical configuration
- [ ] Advanced can expand and collapse
- [ ] No developer/internal terminology is exposed unnecessarily

---

## C. Local — basic restore

Use a short real test video.

- [ ] Select video
- [ ] Select output folder
- [ ] Start Local restore
- [ ] Progress changes during processing
- [ ] Restore finishes successfully
- [ ] Output MP4 is created in selected folder
- [ ] Output video opens and plays
- [ ] Show Output opens the correct location
- [ ] No terminal or developer interaction is required

---

## D. Local — persistence

- [ ] Select a custom output folder
- [ ] Quit MosaicRestore
- [ ] Reopen MosaicRestore
- [ ] Previous output folder is remembered

---

## E. Local — multiple jobs

- [ ] Complete one restore
- [ ] Select a second video
- [ ] Complete another restore without restarting the Mac
- [ ] No stale progress/error state remains
- [ ] Output filenames are correct

---

## F. Batch processing

- [ ] Select multiple videos
- [ ] Queue runs in the expected order
- [ ] Each successful item produces an output
- [ ] Failure of one item is reported clearly
- [ ] App remains usable after batch completion

---

## G. Cancel

Use a video long enough to allow cancellation.

- [ ] Start Local processing
- [ ] Cancel while processing
- [ ] Processing actually stops
- [ ] UI returns to a usable state
- [ ] No false successful output is presented
- [ ] A new restore can start afterwards

---

## H. Error handling

Test at least:

- [ ] Unsupported/non-video input
- [ ] Missing/deleted input after selection
- [ ] Output location that cannot be written
- [ ] Invalid Cloud server address
- [ ] Incorrect Cloud token

Expected behavior:

- Error is understandable
- App does not crash
- User can recover without restarting the computer

---

## I. Cloud Setup

This does not require paid GPU processing.

- [ ] Switch to Cloud
- [ ] Open Advanced
- [ ] Open Configure
- [ ] Server Address field is visible
- [ ] Access Token field is visible
- [ ] No `.conf`, adapter path, Jasna, TensorRT, Python, or provider-specific
      implementation detail is exposed
- [ ] Save configuration
- [ ] Cloud shows Configured
- [ ] Quit and reopen MosaicRestore
- [ ] Cloud remains Configured
- [ ] Token is not displayed in plaintext after reopening setup

Cloud credentials must be stored in macOS Keychain, not plaintext config.

---

## J. Upgrade / replacement install

If an older MosaicRestore build is installed:

- [ ] Quit old version
- [ ] Replace it with Beta from DMG
- [ ] New version launches
- [ ] Output-folder preference behaves correctly
- [ ] No obsolete UI remains
- [ ] Version reports `1.0.1 (102)`

---

## K. Longer Local run

Only one or two testers need this.

- [ ] Process a video longer than 20 minutes
- [ ] No crash
- [ ] Final MP4 is readable
- [ ] Audio/video duration is sensible
- [ ] No obvious chunk boundary corruption

A previous internal release-quality run has already validated a ~70-minute
Local workflow. Beta does not require every tester to repeat that test.

---

# Bug report format

For every Beta defect, record:

**Title**

Short description of the problem.

**Mac**

Example:

`MacBook Air M2, 16 GB`

**macOS**

Exact version.

**MosaicRestore**

`1.0.1 (102) / v1.0.1-beta.1`

**Steps**

1.
2.
3.

**Expected**

What should have happened.

**Actual**

What happened.

**Reproducibility**

- Always
- Sometimes
- Once

**Attachments**

Screenshot, screen recording, or affected sample when appropriate.

---

# Severity

## Blocker

Cannot install, cannot launch, data loss, security failure, or core Local
processing unusable.

## High

Important workflow is broken with no reasonable workaround.

## Medium

Workflow works but has a meaningful defect or confusing behavior.

## Low

Cosmetic or minor UX issue.

---

# Beta exit criteria

`v1.0.1` final can be released when:

- No open Blocker bugs
- No open High bugs
- Installation passes on multiple Apple Silicon Macs
- Local basic restore passes on multiple Macs
- Cancel/error recovery passes
- Output-folder persistence passes
- Cloud Setup persistence and credential handling pass
- No regression in the previously accepted formal Cloud execution contract
- Final DMG is rebuilt from the final commit and its SHA-256 is recorded

Formal paid Cloud GPU execution does not need to be repeated solely for Beta
unless a Beta fix changes the Cloud execution protocol or adapter behavior.
