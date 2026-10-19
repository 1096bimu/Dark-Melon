# Development settings

Save Edits (Command-S) writes `filename.ext.darkmelon.xmp` next to the source.
Reopening the source restores its recipe before automatic tone initialization.
Changes are saved explicitly; the toolbar changes to Edits Saved only when the
current persistent settings match the last successful save.

Move/copy the sidecar with the source; rename both matching prefixes together.
No absolute source path is stored. Including the original extension avoids
collisions between, for example, photo.dng and photo.jpg. The application-specific
suffix avoids overwriting another editor's photo.xmp.

The XMP property `darkmelon:Recipe`, namespace
`urn:dark-melon:development:1.0/`, is a UTF-8 JSON string containing:

- `version`: schema/processing recipe version, currently 1
- `colorSpace`: sRGB, Display P3, or Rec.2020
- `mapping`: ToneMapping's stored values (tone, white balance, monochrome,
  color, HLS and effects)

RAW decoder controls, preview mode, zoom, compare state, export options, and
histogram UI are excluded. The recipe applies to the original source, not to
an already rendered export. Other applications can carry/read the XMP, but
cannot reproduce Dark Melon's processing without implementing these controls.

Atomic writes replace only the small sidecar. Image bytes are never opened for
writing, scanned, or copied by the settings store. Existing unrelated XMP fields
are preserved. Invalid existing XMP is not overwritten. Import rejects unknown
recipe versions and invalid parameter ranges; missing additive fields inherit
defaults. Failure to read a recipe doesn't prevent opening the image.

Sandbox access to the containing directory is needed to create/read sidecars.
The folder browser grants that access. Opening an individual file alone may not
grant access to its siblings; if Save Edits reports permission denied, open its
folder in the browser. Read-only locations cannot save recipes.

Tests: work/DevelopmentRecipeCheck.swift and work/RecipeStoreCheck.swift in the
Codex task workspace cover round trips, validation, missing fields, metadata
preservation, portable rename, corrupt-sidecar protection, and untouched source
bytes. GUI interaction and sandbox permission flows require in-app testing.
