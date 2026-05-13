# PhotoSifter — iOS App Implementation Plan

## Context

Users accumulate large numbers of near-duplicate photos from burst shooting, live photos, and rapid-fire sessions. Manually culling these is tedious. PhotoSifter gives the phone a Tinder-like swiping interface to rapidly decide which photos to keep and which to delete — making photo culling feel like a game rather than a chore.

**Key decisions locked in:**
- Swipe right = Keep, swipe left = Delete (move to Recently Deleted)
- Grouping via Apple Vision ML similarity (VNFeaturePrintObservation)
- Deletion is immediate (iOS moves to Recently Deleted) with a separate "Empty Trash" button
- iOS 17+ minimum target
- SwiftUI with @Observable macro

---

## Project Structure

```
PhotoSifter/
├── PhotoSifterApp.swift
├── ContentView.swift                   # Root router (permission → library)
├── Models/
│   ├── PhotoGroup.swift                # A cluster of near-duplicate PHAssets
│   └── SifterSession.swift             # Live state of a sifting session
├── Services/
│   ├── PhotoLibraryService.swift       # PHPhotoLibrary: fetch, delete
│   ├── SimilarityService.swift         # Vision ML feature print computation
│   └── GroupingService.swift           # Clusters assets into PhotoGroups
├── ViewModels/
│   ├── LibraryViewModel.swift          # @Observable — group list + processing state
│   └── SifterViewModel.swift           # @Observable — per-session swipe state
├── Views/
│   ├── Permission/
│   │   └── PermissionView.swift        # Full-access photo permission request
│   ├── Library/
│   │   └── LibraryView.swift           # Grid of groups, each showing # photos + preview
│   ├── Sifter/
│   │   ├── SifterView.swift            # Orchestrates card stack + strip + progress
│   │   ├── SwipeCardView.swift         # Draggable photo card with overlay
│   │   ├── BatchStripView.swift        # Horizontal thumbnail strip at top
│   │   └── DecisionBadgeView.swift     # "KEEP" / "DELETE" badge on drag
│   └── Summary/
│       └── SessionSummaryView.swift    # Post-session results + Empty Trash CTA
└── Utilities/
    ├── HapticManager.swift             # Core Haptics wrapper
    ├── SoundManager.swift              # AVFoundation SFX player
    └── Color+App.swift                 # App palette constants
```

---

## Phase 1 — Xcode Project Setup

1. Create new Xcode project: **PhotoSifter**, SwiftUI App, iOS 17, Swift.
2. Set `NSPhotoLibraryUsageDescription` in Info.plist.
3. Enable **PhotoKit** and link no external dependencies — use only Apple frameworks:
   - `Photos` (PhotoKit)
   - `Vision`
   - `CoreHaptics`
   - `AVFoundation`

---

## Phase 2 — Photo Library Service

**File:** `Services/PhotoLibraryService.swift`

```swift
actor PhotoLibraryService {
    func requestAuthorization() async -> PHAuthorizationStatus
    func fetchAllAssets() async -> [PHAsset]          // sorted by creationDate
    func loadThumbnail(for asset: PHAsset, size: CGSize) async -> UIImage?
    func loadFullImage(for asset: PHAsset) async -> UIImage?
    func deleteAssets(_ assets: [PHAsset]) async throws // moves to Recently Deleted
    func emptyRecentlyDeleted() async                  // PHAssetChangeRequest to delete permanently (note: not possible via API — show instructions)
}
```

> Note: iOS does not expose an API to permanently delete from Recently Deleted programmatically. "Empty Trash" CTA will deep-link to the Photos app's "Recently Deleted" album so the user can select all and delete.

---

## Phase 3 — Vision Similarity Service

**File:** `Services/SimilarityService.swift`

```swift
actor SimilarityService {
    // Returns a feature print for a single image — cached by localIdentifier
    func featurePrint(for asset: PHAsset) async throws -> VNFeaturePrintObservation
    
    // Returns distance [0, ∞) — near duplicates typically < 0.7
    func distance(from a: VNFeaturePrintObservation,
                  to b: VNFeaturePrintObservation) throws -> Float
}
```

Implementation:
- Use `VNGenerateImageFeaturePrintRequest` on a thumbnail (~512px) for speed.
- Cache feature prints keyed by `PHAsset.localIdentifier`.
- Run on a detached task with `.userInitiated` QoS.

---

## Phase 4 — Grouping Service (Streaming, Cache-first)

**File:** `Services/GroupingService.swift`

### Startup performance goal: < 3 seconds to first interactive group.

**Two-layer strategy:**

**Layer 1 — Cache (instant):** On every launch except the first, read persisted groups from disk (stored as `[String]` arrays of `PHAsset.localIdentifier`). Re-hydrate into `PHAsset` objects immediately. Library is interactive at this point. Meanwhile, Layer 2 runs to refresh.

**Layer 2 — Incremental stream:** Process photos in time-window buckets. As soon as a bucket yields a valid group (≥2 near-duplicates), push it to an `AsyncStream` — the UI appends it to the list in real time. No waiting for the full library to finish.

```swift
actor GroupingService {
    // Streams PhotoGroups as they are found — UI appends each one immediately.
    // Completes when all time-buckets are processed.
    func streamGroups(from assets: [PHAsset]) -> AsyncStream<PhotoGroup>

    // Reads previously cached group identifiers from disk (~instant).
    func loadCachedGroups() async -> [PhotoGroup]?

    // Persist group identifiers so next launch can serve cache immediately.
    func persistGroups(_ groups: [PhotoGroup]) async
}
```

**Clustering algorithm (per time-bucket):**
1. Fetch all assets sorted by `creationDate`.
2. Split into **time-proximity buckets** (gap > 5 minutes = new bucket).
3. Process buckets concurrently with `withTaskGroup` — each bucket is independent.
4. Within a bucket: compute pairwise Vision feature-print distances.
5. Union-find: `distance(a, b) < 0.65` → same group.
6. Filter singletons. Emit multi-photo groups immediately via `AsyncStream.Continuation.yield`.

**Cache invalidation:** Register a `PHPhotoLibraryChangeObserver`. On library change, mark cache stale and re-stream only affected buckets.

---

## Phase 5 — Models

**`Models/PhotoGroup.swift`**
```swift
struct PhotoGroup: Identifiable {
    let id: UUID
    let assets: [PHAsset]          // ordered by date; 2+ items guaranteed
    var decided: [PHAsset.LocalIdentifier: Decision]  // .keep / .delete
    
    var undecidedAssets: [PHAsset] // computed
    var isComplete: Bool           // all decided
    var deleteCount: Int
}

enum Decision { case keep, delete }
```

**`Models/SifterSession.swift`**
```swift
@Observable class SifterViewModel {
    var group: PhotoGroup
    var currentIndex: Int = 0
    var currentAsset: PHAsset? // computed
    var decisionHistory: [(PHAsset, Decision)] = []  // for undo
    
    func swipeRight()  // keep current
    func swipeLeft()   // delete current → move to Recently Deleted immediately
    func undo()        // reverse last decision (un-delete via PHAssetChangeRequest)
    var isComplete: Bool
}
```

---

## Phase 6 — Swipe Card View (Core UI)

**File:** `Views/Sifter/SwipeCardView.swift`

### Layout
```
┌─────────────────────────────┐
│  [BatchStripView]           │  ← 80pt thumbnail strip, blurred card beneath
├─────────────────────────────┤
│                             │
│      [Full photo card]      │  ← fills remaining screen height
│                             │  ← draggable, rotates ±12° with drag
│  ╔═══════╗  or  ╔════════╗  │
│  ║ KEEP  ║      ║ DELETE ║  │  ← badge appears at drag threshold
│  ╚═══════╝      ╚════════╝  │
└─────────────────────────────┘
        [progress dots]
        [undo button]
```

### Swipe Mechanics
- `DragGesture(minimumDistance: 10)` on card
- `offset.x` drives card translation + rotation: `rotation = offset.x / 20` degrees
- Background tint: green at right edge (opacity = `offset.x / 120`), red at left edge
- Decision badge: appears when `abs(offset.x) > 60`
- **Snap threshold**: `abs(offset.x) > 120` → animate card off screen → trigger decision
- On gesture end below threshold → spring back to center

### Animations
- Card throw: `.spring(duration: 0.4, bounce: 0.2)` slide off screen
- Next card: enters from slight scale 0.95 → 1.0 with `.spring(duration: 0.3)`
- Batch complete: confetti-style burst with `Canvas` drawing + `TimelineView`

---

## Phase 7 — Batch Strip View

**File:** `Views/Sifter/BatchStripView.swift`

- Horizontal `ScrollView` with `LazyHStack`
- Each thumbnail: 64×64pt, rounded corners
- Currently-evaluating photo: highlighted ring (white border, slight scale-up)
- "Kept" thumbnails: green checkmark overlay
- "Deleted" thumbnails: 50% opacity + red X
- Smooth scroll to current photo with `.scrollPosition(id:)`

---

## Phase 8 — Haptics + Sound

**File:** `Utilities/HapticManager.swift`

```swift
@MainActor class HapticManager {
    func prepareEngine()
    func playKeep()    // rigid impact + custom pattern (satisfying "chunk")
    func playDelete()  // heavy impact (definitive thud)
    func playUndo()    // soft impact
    func playBatchComplete()  // multi-tap celebration pattern via CHHapticPattern
}
```

**File:** `Utilities/SoundManager.swift`

```swift
class SoundManager {
    func playSwipeSound()   // soft "whoosh" (AVAudioPlayer, short .caf file)
    func playKeepSound()    // bright ding
    func playDeleteSound()  // low "thud" or paper-crumple
    func playCompleteSound() // ascending chime
}
```

Sounds: use system sounds via `AudioServicesPlaySystemSound` as a lightweight option, or bundle short `.caf` files. Start with system sounds, upgrade to custom audio files post-MVP.

---

## Phase 9 — Library View & Processing

**File:** `Views/Library/LibraryView.swift`

States:
1. **Loading from cache** — brief skeleton/shimmer (< 0.5s) while disk cache is read
2. **Live** — list populates immediately from cache, then new groups slide in at top as the background stream finds them. A subtle pill at the top: "Scanning… 143 / 3,420" fades away when complete.
3. **Empty** — "No near-duplicate groups found" state

**`LibraryViewModel` (streaming pattern):**
```swift
@Observable class LibraryViewModel {
    var groups: [PhotoGroup] = []
    var isScanning: Bool = false
    var scanProgress: (current: Int, total: Int) = (0, 0)

    func load() async {
        // 1. Instantly show cached groups
        if let cached = await groupingService.loadCachedGroups() {
            groups = cached
        }
        // 2. Stream fresh groups in background — new ones animate into list
        isScanning = true
        for await group in groupingService.streamGroups(from: assets) {
            withAnimation(.spring) { groups.append(group) }
        }
        isScanning = false
        await groupingService.persistGroups(groups)
    }
}
```

Each row: preview collage (4-up grid), "X photos", time range (e.g. "Yesterday 14:32"), CTA "Sift →".

---

## Phase 10 — Session Summary View

**File:** `Views/Summary/SessionSummaryView.swift`

Shows after a group is fully decided:
- Large number: "47 photos deleted" with animation (counter incrementing)
- Space freed estimate (`asset.pixelWidth * asset.pixelHeight` heuristic)
- Thumbnail grid of deleted photos
- Button: **"Open Recently Deleted"** → `UIApplication.shared.open(URL(string: "photos-redirect://")!)`  
  (or show instructions since deep-link is not supported on all configurations)
- Button: **"Next Group →"**

---

## Visual Design System

**Colors** (`Color+App.swift`):
```
background:    Color(hex: "0A0A0F")   // near-black
cardSurface:   Color(hex: "1C1C24")
keepGreen:     Color(hex: "34C759")   // iOS system green
deleteRed:     Color(hex: "FF3B30")   // iOS system red
accent:        Color(hex: "6C63FF")   // purple accent
textPrimary:   .white
textSecondary: Color(white: 0.6)
```

**Typography**: SF Pro Display for headings, SF Pro Text for body — no custom fonts needed; `.fontDesign(.rounded)` for a friendly modern feel.

**Card style**: Full-bleed photo, no border, subtle drop shadow. Corners rounded at 16pt.

**Transitions**: All navigation via `.navigationTransition(.zoom)` (iOS 18) or custom matched geometry effect.

---

## Implementation Order

| Step | Description | Output |
|------|-------------|--------|
| 1 | Xcode project + Info.plist | Builds & runs |
| 2 | `PhotoLibraryService` + permission flow | Can browse assets |
| 3 | `SimilarityService` + `GroupingService` | Groups computed |
| 4 | `LibraryView` with group list | End-to-end data flow |
| 5 | `SwipeCardView` + drag gesture | Core swipe mechanic |
| 6 | `BatchStripView` | Context strip |
| 7 | `SifterViewModel` + decision logic + delete | Full session flow |
| 8 | `HapticManager` + `SoundManager` | Game feel |
| 9 | `SessionSummaryView` | Post-session screen |
| 10 | Polish: animations, transitions, empty states | Shippable |

---

## Verification

- [ ] Run on physical device (simulator has no photo library)
- [ ] Grant full photo library access — verify groups appear
- [ ] Swipe right through all photos in a group → all marked kept → summary shown
- [ ] Swipe left → photo confirmed moved to "Recently Deleted" in Photos app
- [ ] Undo reverses last decision (checks photo is back)
- [ ] Haptic fires distinctly on keep vs delete
- [ ] Processing progress bar advances and completes
- [ ] Empty state shows when no groups found (use device with unique photos only)
- [ ] Memory: no leaks from holding `UIImage` objects — use `PHCachingImageManager`

---

## Key Apple APIs

| Need | API |
|------|-----|
| Photo access | `Photos.framework` — `PHFetchResult`, `PHAsset`, `PHImageManager` |
| Image similarity | `Vision.framework` — `VNGenerateImageFeaturePrintRequest`, `VNFeaturePrintObservation` |
| Delete to trash | `PHAssetChangeRequest.deleteAssets(_:)` inside `PHPhotoLibrary.shared().performChanges` |
| Haptics | `CoreHaptics` — `CHHapticEngine`, `CHHapticPattern` |
| Image caching | `PHCachingImageManager` |
| SwiftUI state | `@Observable` macro (iOS 17) |
| Scroll position | `.scrollPosition(id:)` modifier (iOS 17) |
