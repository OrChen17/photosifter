# PhotoSifter

iOS app for culling near-duplicate photos. Tinder-style swipe interface: right = keep, left = delete. Makes photo management feel like a game rather than a chore.

**Platform:** iOS 17+, SwiftUI, `@Observable` macro, no external dependencies.

---

## What It Does

1. Scans the photo library for near-duplicate groups (burst captures + Vision ML similarity).
2. Shows groups in a library grid. Each group is a cluster of 2+ near-identical photos taken close together in time.
3. User sifts through a group by swiping cards. Decisions are queued, then committed in one batch PHPhotoLibrary change when the group is complete.
4. Summary screen shows photos deleted, space saved, and a "Continue" card to the next group.

---

## Architecture

MVVM. All state in `@Observable` classes. No Combine. No external packages.

```
PhotoSifter/
├── ContentView.swift              — root router: permission → LibraryView
├── Models/
│   └── PhotoGroup.swift           — struct: [PHAsset] + decisions dict + computed helpers
├── Services/
│   ├── PhotoLibraryService.swift  — actor: PHPhotoLibrary fetch/delete/thumbnail
│   ├── SimilarityService.swift    — actor: Vision VNFeaturePrintObservation, cached by localIdentifier
│   ├── GroupingService.swift      — actor: burst groups + Vision clustering + disk persistence
│   └── DebugSimilarityService.swift — stub for simulator (Vision/CoreML broken there)
├── ViewModels/
│   ├── LibraryViewModel.swift     — @Observable @MainActor: groups list, scan state, group lifecycle
│   └── SifterViewModel.swift      — @Observable @MainActor: per-session swipe state, undo, commit
├── Views/
│   ├── Permission/PermissionView.swift
│   ├── Library/LibraryView.swift  — 2-col grid of MemoryCardView; ScanningBadge in toolbar
│   ├── Sifter/
│   │   ├── SifterView.swift       — orchestrates card + strip + progress bar + vignette
│   │   ├── SwipeCardView.swift    — draggable card with badges, metadata overlay, skip gesture
│   │   ├── BatchStripView.swift   — horizontal thumbnail strip at top showing decisions
│   │   └── DecisionBadgeView.swift — KEEP/DELETE badges
│   └── Summary/SessionSummaryView.swift — animated stats, next-batch card, retry path
└── Utilities/
    ├── Color+App.swift            — app palette (appBackground, appCard, appKeep, appDelete, appAccent)
    ├── HapticManager.swift        — CoreHaptics wrapper (keep/delete/undo/tick/batch-complete)
    └── SoundManager.swift         — AVFoundation SFX (keep/delete/complete)
```

---

## Grouping Pipeline

`GroupingService.streamGroups()` runs two phases in sequence:

1. **Burst groups** — `PHAsset.fetchAssets(withBurstIdentifier:)` for iOS burst captures. No Vision needed, fast.
2. **Vision clustering** — remaining photos split into time-proximity buckets (gap > 5 min = new bucket). Each bucket processed concurrently via `withTaskGroup`. Within a bucket: pairwise `VNFeaturePrintObservation` distances, union-find merge when `distance < 0.65`. Groups sorted chronologically before emitting.

Results stream into `LibraryViewModel` via `AsyncStream`, animating each new group into the grid as it arrives.

**Persistence (two files in Application Support):**
- `grouped_identifiers.json` — `[[String]]` of localIdentifier arrays. Loaded on cold launch to show groups instantly before the Vision scan completes.
- `group_decisions.json` — `[String: [String: String]]`. Key = sorted localIdentifiers joined by `|` (stable across launches since UUID is regenerated). Value = `{localIdentifier: "keep"|"delete"}`. Written on mid-batch exit; hydrated on re-enter.

**Simulator:** `GroupingService.shared` substitutes `DebugTimeProximitySimilarity` because `VNFeaturePrintObservation` can't load the model on the simulator.

---

## SifterViewModel — Key Invariants

- **Deletes are deferred.** `swipeLeft()` appends to `pendingDeletes`; no PHPhotoLibrary call until `commitDeletes()`.
- **Commit is called once** by `SifterView.onChange(of: vm.isComplete)`. It re-derives `toDelete` from `group.decisions` (not `pendingDeletes`) so a retry after user cancellation still works.
- **Skip** moves an asset to the end of `displayOrder` (once per asset only, tracked via `skippedIdentifiers`).
- **Strip tap = undo affordance.** `jumpTo(asset:)` clears that asset's decision and moves the cursor there. Replaces the old undo-only button.
- **Resume mid-batch.** On init, `currentIndex` is set to the first undecided asset index. `applyHydratedGroup(_:)` called on appear for belt-and-suspenders correctness.
- **Last photo guard.** `isLastUndecidedWithNoKept` triggers a warning alert before allowing deletion of the last photo when nothing has been kept.
- **`keepOnlyCurrentAndDeleteRest()`** — shortcut to mark current as keep and queue all others for deletion in one action.

---

## Deletion Flow

```
swipeLeft() → pendingDeletes.append(asset)
                ↓ (when all swiped)
isComplete = true
                ↓ onChange in SifterView
commitDeletes()  → PHAssetChangeRequest.deleteAssets(_:)
                ↓
DeletionOutcome:
  .committed      → libraryVM.markGroupComplete (removes from list, clears persisted decisions)
  .nothingToDelete → same
  .cancelledByUser → libraryVM.saveGroupProgress (decisions preserved for retry)
  .failed(msg)    → same as cancelled
```

iOS cannot permanently delete from Recently Deleted via API. The "View Recently Deleted" button deep-links to `photos-redirect://` (fallback: `photos-library://`).

---

## LibraryViewModel Responsibilities

- Owns `groups: [PhotoGroup]` and `selectedGroup: PhotoGroup?` (drives `NavigationStack` destination).
- `load()`: serve cache immediately, then stream fresh groups, sort by (group size desc, date desc), persist when done.
- `markGroupComplete(_:)`: removes group from list + clears its persisted decisions.
- `saveGroupProgress(_:)`: updates in-memory copy + writes decisions to disk.
- `nextIncompleteGroup(after:)`: pure lookup for the summary screen's "Continue" CTA.

---

## UI / Design

**Color palette** (`Color+App.swift`):
- `appBackground`: `#0A0A0F` near-black
- `appCard`: `#1C1C24`
- `appKeep`: `#34C759` (iOS system green)
- `appDelete`: `#FF3B30` (iOS system red)
- `appAccent`: `#6C63FF` purple

**Swipe mechanics** (`SwipeCardView`):
- Badge threshold: 60pt (haptic tick fires on first crossing, once per direction change)
- Snap threshold: 120pt (card thrown off-screen, action fires after 0.35s)
- Upward flick (`translation.height < -80`) = skip
- Screen-wide radial vignette in `SifterView` driven by `swipeProgress: Double` (reported by card via closure)

**Typography:** SF Pro with `.fontDesign(.rounded)` throughout. No custom fonts.

**Card preloading:** `SifterView` preloads the next 3 full-res images into `imageCache: [String: UIImage]` ahead of the current index.

---

## Testing

Must run on a **physical device** — simulator has no photo library and Vision ML can't load the feature-print model. Use the `DebugSimilarityService` path only for UI layout testing.

Key flows to verify after any change:
- Swipe through full group → summary appears → photos in Recently Deleted
- Mid-batch exit → re-enter → decisions restored at correct position
- Strip tap → clears decision → re-swipe works
- Skip → asset moves to end → can only skip once
- Deletion cancelled at system prompt → retry from summary succeeds
- `keepOnlyCurrentAndDeleteRest` → all others queued → summary shows correct count
