# Dark Melon

A SwiftUI image development app for RAW, SDR, and HDR images, with tone and color controls, GPU scopes, effects, and gain-map export.

## Open the project

Open `Dark Melon.xcodeproj` in Xcode, select the **Dark Melon** scheme and your destination, then run. This project currently targets macOS, iOS, and visionOS 27. Device builds may require selecting your own signing team.

Development edits are stored in XMP sidecars; see [DevelopmentSettings.md](DevelopmentSettings.md). Batch export is available on macOS.

## Third-party code

The film grain implementation is adapted from [cinegrain2](https://github.com/mr-berndt/cinegrain2). Its attribution is in `FilmGrain.swift`, and its GPL-3.0-or-later license is included in `Dark Melon/Cinegrain2-LICENSE.txt`.
