# Source organization

The Xcode target uses the synchronized `Dark Melon` folder, so the folders on disk
also define the project navigator. Add new code beside the feature it belongs to.

| Folder | Responsibility |
| --- | --- |
| `App` | App entry point, menu commands, and focused command routing |
| `Loading` | RAW development, image loading, caching, and background preloading |
| `Model` | Color, tone, transform, and edit settings; recipes and editing history |
| `Render` | Color math, tone analysis, effect processors, GPU scopes, and Metal shaders |
| `UI/Editor` | Main editor coordination, shell layout, window chrome, and tutorial |
| `UI/Controls` | Tone, color, RAW, effects, and transform panel controls |
| `UI/Components` | Shared sliders, fields, buttons, graph controls, and styling |
| `UI/Scopes` | Histogram, vectorscope, chroma-range, and spectral views |
| `UI/Preview` | Image presentation, comparison, metadata pill, and HDR display handling |
| `UI/Browser` | File browser, edit library, snapshots, and preset confirmation |
| `UI/Export` | Batch-export and LUT configuration views |
| `UI/Settings` | Preferences and settings-selection views |
| `Export` | Export options, encoding, metadata, plans, scheduling, and output writing |
| `Support` | File access, persistence, metadata, LUT storage, language, and keyboard adapters |
| `Resources` | Icons, localization catalog, bundled LUTs, help, and third-party license |

Small helpers sharing a purpose are grouped in `ToneAdjustments.swift`,
`ImageStatistics.swift`, `ColorKernels.swift`, `ComparisonSettings.swift`, and
`KeyboardShortcuts.swift`. Keep substantial processors and views in named files
rather than growing general-purpose utility files.

`ContentView` owns editor state and coordinates operations. Reusable views belong
in their UI feature folders; for example, `LinearHistogram` is in `UI/Scopes` and
`EditorSettingsView` is in `UI/Settings`.

The entitlements path is configured in the Xcode project. Bundle resources are
looked up by resource name, independently of their source folder. Standalone
regression checks remain in the repository's `Tests` folder.
