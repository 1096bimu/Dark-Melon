# Dark Melon

A SwiftUI image development app for RAW, SDR, and HDR images, with tone and color controls, GPU scopes, effects, and gain-map export.

## HDR in formats people actually use

Dark Melon prioritizes **JPEG and HEIF/HEIC with HDR gain maps**: familiar photo formats built around a usable SDR image, with extra HDR information for compatible viewers. JPEG provides the broadest everyday fallback, so people can open the photograph on most phones even when HDR rendering is unavailable. HEIC is a natural option for Apple photo workflows.

The goal is practical delivery, not merely a file that can technically encode HDR. We choose this approach over requiring recipients to use AVIF or JPEG XL, where support for opening the format does not necessarily mean their particular photo app, browser, or sharing service will preserve and display its HDR rendition. Those formats can deliver excellent HDR in supported workflows; they are simply not a prerequisite for viewing a Dark Melon export.

**A good SDR photograph everywhere the base format is supported; an HDR extension where the full viewing path supports it.** Actual HDR still depends on the display, OS, viewer, and preservation of the gain map. Dark Melon writes ISO 21496-1 gain maps; older viewers that only understand a different gain-map variant may show SDR. HEIC is less universally viewable than JPEG, and messaging or social platforms may strip HDR metadata during conversion.

For the platform mechanisms behind this approach, see [Apple's Adaptive HDR overview](https://developer.apple.com/videos/play/wwdc2024/10177/) and [Android's gain-map format documentation](https://developer.android.com/media/platform/hdr-image-format).

## Sample image

**[Try the interactive SDR / HDR comparison →](https://1096bimu.github.io/Dark-Melon/)** — choose from five sample photographs, drag the divider, or toggle between renditions.

[![Dark Melon JPEG export with an ISO HDR gain map](docs/samples/DSC00037.jpg)](https://raw.githubusercontent.com/1096bimu/Dark-Melon/main/docs/samples/DSC00037.jpg)

An original 2736 × 1824 JPEG export with an embedded ISO 21496-1 HDR gain map. Compatible viewers can show the HDR rendition; other viewers display the SDR base. Click the image to open the original file. HDR appearance depends on the browser, display, and system settings.

## Features

- **RAW, SDR, and HDR image development**, with paired SDR/HDR previews and JPEG, HEIF, and TIFF export.
- **Batch export on macOS**, using saved settings or automatic development for unedited files, concurrent processing with a memory budget, and automatic filename-conflict handling.
- **Portable XMP sidecar settings**, leaving original images untouched. Unsaved recipes stay in a pending-edits list when switching images. Save commits them to sidecars; folder changes and normal close/quit ask before discarding pending work.
- **Copy and paste settings**, with separate choices for Tone, White Balance, Color, HLS, Effects, and RAW controls.
- **Folder-based file browser** with thumbnails, RAW/All filtering, Command/Shift selection, and outlines identifying images with saved edits.
- **White balance**, including averaged circular sampling, RGB gains, and RAW temperature/tint controls. Convert to WB transfers RGB adjustments into the RAW decoder where possible, preserving residual gains when its limits are reached.
- **Split toning**, saturation-versus-saturation and luminance-versus-saturation controls.
- **HSL color adjustments and black-and-white conversion** with an adjustable color-sensitivity curve, designed for physically plausible tonal relationships and smooth near-white transitions.
- **Clarity** for local contrast, using a large-radius high-pass layer blended with Soft Light. Similar in purpose to Lightroom's Clarity, but a different implementation; negative strength softens contrast.
- **HDF filter** for soft glow, adding a blurred version of the image with adjustable strength and radius.
- **Film grain** based on cinegrain2, with adjustable size, strength, and tonal distribution—from a shadow-weighted response to a midtone peak—for convincing texture across different tones.
- **GPU histogram and vectorscope**, with both tone curves drawn over the source histogram.
- **sRGB, Display P3, and Rec.2020 processing**, plus RAW decoder controls where supported.

## Not yet included

Dark Melon is a focused image developer, not a full replacement for a commercial photo editor or library manager.

- No crop, rotation, perspective correction, or other geometric transforms.
- No catalog or database; images stay in ordinary folders with optional sidecars.
- No ratings, flags, reject/keep workflow, or other culling tools.
- No file-management operations such as deleting, moving, or renaming source images.
- No updated thumbnails of edits in the file browser. Original files and their embedded previews remain untouched; the browser shows source thumbnails, while the main preview shows the developed result.
- No masks, brushes, gradients, subject selections, or other spatially selective edits. Color and tonal-range controls are global.

## Development philosophy: one edit, two useful renditions

Dark Melon aims to make natural-looking SDR and HDR photographs together, using a small, coordinated set of tone controls. The SDR version should be a finished photograph with sensible exposure and contrast. The HDR version should use the display's extra headroom to reveal highlight separation and luminous detail that SDR cannot show, rather than simply turning up the brightness of the whole image.

### Fewer controls, one coherent curve

Instead of asking you to balance separate Exposure, Shadows, Highlights, Whites, and Blacks adjustments, the core tone model uses two endpoints and four sliders:

| Control | Role |
| --- | --- |
| White point | Chooses which input level reaches SDR white. This value alone dictates the clipping point without guess work.|
| Tone | Moves the region where the curve allocates contrast, relative to the black and SDR white points. |
| Contrast | Controls how concentrated that allocation is; negative values provide a complementary curve shape for reducing contrast. |
| HDR Gain | Multiplies the entire HDR rendition, or disables HDR. |
| HDR Rolloff | Gradually flattens the HDR highlight extension, lowering its endpoint. |

The SDR curve is constructed by integrating a nonnegative slope profile and normalizing its total area. Positive Contrast uses a beta-shaped profile; negative Contrast uses its broad, nonnegative complement. This creates a fixed **contrast budget**: allocating more slope to one tonal region necessarily leaves less elsewhere. The controls reshape a single continuous, monotonic mapping instead of stacking independently adjusted tonal regions. Within each RGB channel, a brighter input cannot become a darker output through this tone curve, although clipping can make different inputs equal.

This is a useful constraint for natural photographic rendering. It makes the tradeoff between shadow, midtone, and highlight separation explicit and reduces the number of interacting controls needed to find a balanced result.

### SDR and HDR share an input reference

Both renditions start from the same linear RGB image and black point. The SDR curve maps the interval between black and white into output 0–1, clipping above the selected white point. **The HDR extension grows out of that SDR curve at Tone**, using its brightness and local slope as the starting reference.

HDR Gain is a separate multiplier, not the endpoint: the default 1.01× prevents intersection which is not supported by HDR gain maps. This can be used to make the entire HDR image brighter if needed, but we advise against that approach as HDR should be used exclusively to enhance highlight detail, that was its intended purpose.

Rolloff bends the highlight extension downward smoothly. At zero it is straight; at maximum it finishes with zero slope. It retains the starting slope of the unrolled extension while reducing its final brightness. 

For example, the SDR white point can expose a room naturally while bright window detail reaches white. The HDR continuation retains separation in brighter source values and displays it above SDR white, using detail already present in the source. It cannot recover detail clipped during capture or beyond the implemented input endpoint.

**Auto Tones** when enabled, adjusting only the tone value by placing it over neutral skin tone, other settings are automatically adjusted to create a pleasant image in both HDR and SDR with a single input. 

### Reading the two curves

<img src="docs/images/tone-histogram.png" alt="Updated Dark Melon tone controls: cyan SDR curve levels off at the white point near 0.725; orange HDR extension reaches output 2.44 with Gain 1.01 and Rolloff zero." width="640">

The horizontal axis is linear source RGB intensity. The colored histogram fills show pixel counts on a **logarithmic** vertical scale; the overlaid curves use a separate **linear output** scale, reduced to fit HDR headroom. The dashed “1.0 · SDR white” line marks reference white on that curve scale. A curve crossing a histogram trace has no special meaning—the two heights represent different quantities.

### Designed for gain-map delivery

An SDR-base gain-map file contains a conventional SDR image plus information for reconstructing an HDR rendition. The SDR image is what a viewer sees when HDR is unavailable or the gain map is ignored, so a dark, flat fallback is still a failed delivery even if the HDR rendition looks good.

Dark Melon develops both images first, then derives the gain map from their relationship. In simplified form, the stored quantity is `log2((HDR + epsilon) / (SDR + epsilon))`, calculated per RGB channel or from luminance for a monochrome map. The small offset handles values near black. The map therefore describes where the HDR rendition differs from the SDR base, rather than applying one global brightness multiplier. Compatible viewers can adapt that enhancement to available display headroom. See Apple's [overview of adaptive HDR and gain maps](https://developer.apple.com/videos/play/wwdc2024/10177/).

The intended result is a convincing SDR photograph with an HDR extension that adds selective highlight detail and brightness. The mathematical structure supports that goal, but does not enforce it: aggressive settings can also brighten midtones substantially. The app warns when the HDR tone curve falls below the SDR curve; it does not automatically prevent crossings. Rolloff can cause such a crossing; a small increase in HDR Gain can resolve it. Direct PQ HEIF export is also available without a gain map.

### Why this approach instead of a traditional multi-slider workflow?

For this goal, we prefer a compact, constrained model over the many interacting tonal adjustments familiar from Lightroom-style workflows. Extensive local or tonal manipulation can produce relationships that no longer resemble the photographed lighting—for example, heavily lifted shadows alongside strongly compressed highlights. Independent adjustments also do not, by themselves, define how a finished SDR image should extend into HDR. Dark Melon's paired curves make that relationship part of the development model from the start.

This is a workflow advantage and a design preference, not a claim that Lightroom cannot produce natural HDR. [Current Lightroom supports HDR editing, SDR preview adjustments, and gain-map output](https://helpx.adobe.com/lightroom/desktop/edit-photos/hdr-output.html). Dark Melon's distinction is using fewer coupled controls to shape the two renditions together.

“Physically plausible” describes the rendering goal, not a guarantee of radiometric accuracy. Nonlinear tone mapping changes light ratios, per-channel curves can change color, and creative effects can deliberately depart from realism. The concrete guarantees here are nonnegative tone-curve slopes, defined endpoints, and a shared source reference—not a simulation of scene lighting.

## Open the project

Open `Dark Melon.xcodeproj` in Xcode, select the **Dark Melon** scheme and your destination, then run. This project currently targets macOS, iOS, and visionOS 27. Device builds may require selecting your own signing team.

Development edits are stored in XMP sidecars; see [DevelopmentSettings.md](DevelopmentSettings.md). Batch export is available on macOS.

## Third-party code

The film grain implementation is adapted from [cinegrain2](https://github.com/mr-berndt/cinegrain2). Its attribution is in `FilmGrain.swift`, and its GPL-3.0-or-later license is included in `Dark Melon/Cinegrain2-LICENSE.txt`.

## License

Dark Melon source code is licensed under the **GNU General Public License version 3 (GPL-3.0-only)**. Copyright © 2026 Dark Melon contributors. See [LICENSE](LICENSE) for the full terms. This software is distributed without warranty.

The film grain implementation is adapted from [cinegrain2](https://github.com/mr-berndt/cinegrain2), copyright © 2026 mr-berndt, licensed under **GPL-3.0-or-later**. Its original attribution and bundled license are retained. Dark Melon's adaptation adds image-processing integration and adjustable grain controls.
