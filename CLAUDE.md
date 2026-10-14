# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

iOS app **FlickPic** (Xcode scheme `PhotoSifter`, bundle id `com.flickpic.app`). Tinder-style swipe UI for culling near-duplicate photos. iOS 17+, SwiftUI, `@Observable` macro, no external dependencies.

## Build / Run / Test

Three pre-wired devices live in [.vscode/tasks.json](.vscode/tasks.json). Use these IDs (don't invent destinations):

- Orr's iPhone: `00008120-001261E402A0C01E`
- Ofir's iPhone: `00008120-0004598E0132201E` (needs `-allowProvisioningUpdates`)
- Simulator: `4902F1E6-4F1C-40A8-8C57-F1D91073F8F1`

Typical commands:

```sh
# Build + install + launch on a physical device
xcodebuild -scheme PhotoSifter -destination 'id=<DEVICE_UDID>' -derivedDataPath build build
xcrun devicectl device install app --device <DEVICE_UDID> build/Build/Products/Debug-iphoneos/PhotoSifter.app
xcrun devicectl device process launch --device <DEVICE_UDID> com.flickpic.app

# Run unit tests on simulator
xcodebuild test -scheme PhotoSifter \
  -destination 'id=4902F1E6-4F1C-40A8-8C57-F1D91073F8F1' \
  -only-testing:PhotoSifterTests -derivedDataPath build

# Run a single test class or method
xcodebuild test -scheme PhotoSifter \
  -destination 'id=4902F1E6-4F1C-40A8-8C57-F1D91073F8F1' \
  -only-testing:PhotoSifterTests/SifterViewModelTests \
  -only-testing:PhotoSifterTests/SifterViewModelTests/testSwipeLeftQueuesDelete \
  -derivedDataPath build
```

Build output goes to `build/` (gitignored). Tests use `TEST_HOST` of the host app, so they have full access to `PHPhotoLibrary` — see [PhotoSifterTests/Mocks/TestAssetHelpers.swift](PhotoSifterTests/Mocks/TestAssetHelpers.swift) for `requirePhotoAssets`/`requirePhotoGroup` which `XCTSkipIf` when no photos are present.

## Testing constraints

- **Simulator cannot run real Vision similarity.** `VNGenerateImageFeaturePrintRequest` fails to load its CoreML model on the simulator. `GroupingService.shared` swaps in `DebugTimeProximitySimilarity` (treats photos within 30s as duplicates) under `#if DEBUG && targetEnvironment(simulator)` so the UI is still exercisable. Tests that depend on real similarity must run on device or use `MockSimilarityService`.
- Most behaviour-level tests use the helpers in [PhotoSifterTests/Mocks/](PhotoSifterTests/Mocks/): `MockDeletionService` (records deletes without hitting Photos), `MockSimilarityService`, and `TestAssetHelpers`.
- UI tests pass process-arg flags read by [PhotoSifter/PhotoSifterApp.swift](PhotoSifter/PhotoSifterApp.swift) and [PhotoSifter/ContentView.swift](PhotoSifter/ContentView.swift) — `UI_TESTING`, `FORCE_EMPTY_LIBRARY`, `FORCE_DENIED`.

## Architecture (the parts that span files)

MVVM with `@Observable` + `@MainActor` view models and `actor` services. No Combine, no SPM dependencies.

### Three-layer load pipeline ([LibraryViewModel.load()](PhotoSifter/ViewModels/LibraryViewModel.swift#L65))

1. **Stats** — `CompletedBatchStore.shared.loadAll()` so history counters render non-zero on first frame.
2. **Layer 1 (cached)** — `GroupingService.loadCachedGroups()` reads `grouped_identifiers.json` and renders the grid instantly. Cached groups are hydrated with saved decisions and filtered against the `flicked_identifiers.json` set.
3. **Layer 2 (streaming)** — `GroupingService.streamGroups(from:excluding:)` emits new `PhotoGroup`s via `AsyncStream`. Assets already in cached groups or in `flickedIDs` are excluded. Groups are buffered into batches of 8 (or 0.4s) and flushed with a spring animation into `groups`.
4. **Quick wins** — `QuickWinsService.fetchAll()` runs at `.utility` priority after the scan finishes, so it never blocks the grid.

### Grouping pipeline ([GroupingService](PhotoSifter/Services/GroupingService.swift))

Two phases per `streamGroups` call:

1. **Burst groups** — `PHAsset.fetchAssets(withBurstIdentifier:)`. Fast, no ML.
2. **Vision clustering** — assets split into time-proximity buckets (`timeBucketGap = 5 min`). Within a bucket, pairwise `VNFeaturePrintObservation` distances, union-find merge when `distance < 0.5` (`similarityThreshold`). Groups are sorted chronologically.

iCloud handling: when `AppSettings.cloudDownloadEnabled == false`, both burst and Vision phases pre-filter via `PhotoLibraryService.isLocallyAvailable` (which uses `PHAssetResourceManager` with network disabled and cancels after the first byte).

### Persistence (Application Support, all JSON)

`GroupingService` writes these files. The directory is created in its `init` because iOS won't auto-create it — without that, `try?` writes silently fail and mid-batch progress doesn't survive.

| File | Shape | Purpose |
|---|---|---|
| `grouped_identifiers.json` | `[[String]]` | Cached group → localIdentifier arrays, served on cold launch. |
| `group_decisions.json` | `[String: [String: String]]` | Per-group decisions. **Outer key** = sorted localIdentifiers joined by `\|` (stable across launches because `PhotoGroup.id` UUID is regenerated each scan — see `persistenceKey(for:)`). |
| `flicked_identifiers.json` | `[String]` | LocalIdentifiers of photos in completed groups. Vision skips these on rescan. |
| `scan_cutoff.json` | `Date` | Last full-scan timestamp. |
| `file_sizes.json` | `[String: Int64]` | `PHAssetResource.fileSize` cache. |
| `completed_batches.json` | `[CompletedBatch]` | History tab data (owned by [CompletedBatchStore](PhotoSifter/Services/CompletedBatchStore.swift)). |
| `video_frame_rates.json` | `[String: Double]` | Shrink tab's `nominalFrameRate` cache, keyed by localIdentifier (owned by [VideoShrinkService](PhotoSifter/Services/VideoShrinkService.swift)). |

### Deletion flow

Deletes are **deferred and batched**. `SifterViewModel.swipeLeft` only appends to `pendingDeletes`. No `PHPhotoLibrary` call happens until `SifterView.onChange(of: vm.isComplete)` fires `commitDeletes()`. `commitDeletes` re-derives `toDelete` from `group.decisions` (not `pendingDeletes`) so a retry after iOS-prompt cancellation still works.

`DeletionOutcome` (Equatable): `.committed` / `.nothingToDelete` → `LibraryViewModel.markGroupComplete`; `.cancelledByUser` / `.failed` → `saveGroupProgress` so the user can retry. Both `PHPhotosError.userCancelled` and `NSUserCancelledError` map to `.cancelledByUser`.

`markGroupComplete`: removes from in-memory list, writes `flickedIDs`, clears that group's decisions, and **immediately re-persists** `grouped_identifiers.json` so a force-quit during a scan doesn't resurrect the completed group.

### Sifter view-model invariants ([SifterViewModel](PhotoSifter/ViewModels/SifterViewModel.swift))

- **Resume mid-batch.** Init scans `group.decisions` to set `currentIndex` to the first undecided asset and re-queues already-marked deletes. `applyHydratedGroup(_:)` is called again on `SifterView.task` as belt-and-suspenders.
- **Skip is one-shot per asset** (`skippedIdentifiers`), advances circularly via `nextUndecidedIndex`.
- **Strip-tap replaces undo.** `jumpTo(asset:)` clears that asset's decision, removes it from `pendingDeletes`, and moves the cursor there.
- **Last-photo guard.** `isLastUndecidedWithNoKept` triggers a confirm before allowing the user to delete the final photo when nothing's been kept.
- Bulk actions (`deleteAll`, `keepOnlyCurrentAndDeleteRest`, `keepOldestAndDeleteRest`) intentionally bypass the guard — callers confirm first.

### Quick Wins ([QuickWinsService](PhotoSifter/Services/QuickWinsService.swift))

Separate from the main grouping pipeline. Two categories:

- **Screenshots** — `PHAssetMediaSubtype.photoScreenshot` (also filtered out of the main scan in `PhotoLibraryService.fetchAllAssets`), chunked into batches of 20.
- **Exact duplicates** — size-prefilter (`sizePrefilterIdentifiers`) → SHA-256 of `PHAssetResource` data in batches of 4 (memory-bounded streaming hash via `CryptoKit`) → group by digest. Duplicates use a dedicated [DuplicateGroupSifterViewModel](PhotoSifter/ViewModels/DuplicateGroupSifterViewModel.swift) (merge-vs-keep-all, not per-photo decisions).

### Shrink tab ([VideoShrinkService](PhotoSifter/Services/VideoShrinkService.swift), [VideoShrinkViewModel](PhotoSifter/ViewModels/VideoShrinkViewModel.swift))

Lists videos above 1080p or 30 fps ([VideoShrinkPlan](PhotoSifter/Models/VideoCandidate.swift) holds the thresholds and size estimate) and re-encodes them to 1080p / 30 fps HEVC. Slo-mo, Cinematic and time-lapse videos are skipped. iOS can't shrink an asset in place: a content edit keeps the original. So every selected video is exported to `tmp/VideoShrink` first. Then one `performChanges` creates the new assets (date, location, favorite, hidden and albums copied) and deletes the originals. That is one iOS prompt, and cancelling it changes nothing; the view model keeps the files so "Replace" re-prompts without re-encoding. Originals land in Recently Deleted, so space is freed only once that is emptied.

### Concurrency model

- All view models are `@Observable @MainActor`. They never touch `PHPhotoLibrary` directly — they go through actors.
- `PhotoLibraryService`, `GroupingService`, `SimilarityService`, `CompletedBatchStore`, `QuickWinsService` are all `actor`s with `static let shared`.
- `DeletionService` protocol exists solely so `SifterViewModel` can be injected with `MockDeletionService` in tests; `PhotoLibraryService` conforms via extension.

## Conventions

- File references in commits/PRs use `path:line`. Keep the same convention in code comments when explaining cross-file behaviour.
- The user-facing app name is **FlickPic** (`CFBundleDisplayName`); the Xcode target / scheme / source folders are still `PhotoSifter`. Don't rename the target.
- The "Sift" tab was renamed to **"Flick"** — UI strings use "Flick"/"flicked", code still uses `Sifter*` for types.
- Color palette in [Color+App.swift](PhotoSifter/Utilities/Color+App.swift): `appBackground`, `appCard`, `appKeep`, `appDelete`, `appAccent`, `appTextSecondary`. Use these, not raw hex.
- Typography: SF Pro with `.fontDesign(.rounded)` throughout. No custom fonts.
