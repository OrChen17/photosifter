# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users

Everyday iPhone owners with a cluttered camera roll. Storage is full or the roll feels messy, and they clean up in short bursts: on the couch, while commuting, in a spare few minutes. They are not photographers and do not want to learn a tool.

## Product Purpose

FlickPic finds groups of near-duplicate photos and lets the user keep the best and delete the rest by swiping, one photo at a time. Success means the user clears a group in seconds, sees space freed, and comes back for the next batch because it felt good, not because it was a chore.

## Positioning

- **Better UI than other photo cleaners.** The user always sees the whole group of similar photos at a glance (the top strip of thumbnails in the Flick screen) while deciding on the current one, and can jump to any of them.
- **Fun swipe ritual.** Flicking left or right should feel quick and satisfying, closer to a game than to file management.
- **Smart grouping.** The app finds near-duplicates for the user (burst groups plus on-device Vision similarity), so the user only decides on photos that matter.

## Operating Context

- One-handed phone use, short sessions, often interrupted. Progress inside a group is saved and resumes mid-batch.
- Deletes are deferred until a group is finished, then go through the iOS system delete prompt. Deleted photos land in Recently Deleted for 30 days.
- Separate "Quick Wins" flows for screenshots and exact duplicates.
- History tab shows completed groups and space saved.
- iCloud-only photos are skipped unless the user turns on "Download from iCloud" in Settings.

## Capabilities and Constraints

- iOS 17+, SwiftUI, no third-party dependencies.
- Everything runs on the device. No account, no server, no analytics, no ads (see `docs/privacy-policy.html`).
- User-facing name is **FlickPic**; the main tab is **Flick** ("flicked" in copy). Code and Xcode target still use `PhotoSifter` / `Sifter`.
- **Open decision: pricing.** Current idea: free up to some amount of storage cleaned (X GB, undecided), then $5/month. Premium may add features such as video compression. Not built yet; nothing in the UI should promise a price or a premium feature until decided.

## Brand Commitments

- Name: FlickPic. App icon: `icon.svg` / `icon_1024.png`.
- Swipe gestures are the core interaction; tap buttons are the fallback, not the main path.

## Evidence on Hand

- No testimonials, reviews, user counts or benchmarks exist. Do not invent any.
- Privacy policy: `docs/privacy-policy.html`.

## Product Principles

1. Deciding is the product. Every screen should get the user to the next keep/delete decision faster.
2. Context beats memory. Show the whole similar group while deciding, so the user never has to remember what the other shots looked like.
3. Safe to be fast. Deletes are batched, confirmed by iOS and recoverable, so the UI can make swiping feel light.
4. Small wins, often. Short sessions with visible progress (space freed, groups cleared) beat one long cleanup.
5. Private by default. Nothing leaves the phone, and the product never needs to ask for trust it doesn't need.
