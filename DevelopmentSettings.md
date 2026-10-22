# Development settings

Save Edits (Command-S) writes `filename.ext.darkmelon.xmp` next to the source.
Reopening the source restores its recipe before automatic tone initialization.
Changes are saved explicitly; the toolbar changes to Edits Saved only when the
current persistent settings match the last successful save.

Switching images keeps changed recipes in a folder-scoped, in-memory pending list,
including images that already have sidecars. Selecting an entry restores its edits
and queues changes to the image being left. Save writes all pending recipes (and
any newer edits to the current image); successfully saved entries leave the list.
Ignore asks before discarding the list and reloads the current image from disk.
Changing folders, opening an individual file, and normal macOS close/quit require
Save All, Discard, or Cancel when edits are pending. There is no automatic save.
Untouched automatic import adjustments do not count as user edits. SDR imports
without a saved recipe start with HDR Gain off.

The queue is memory-only: force quit, crashes, and OS process termination cannot
be intercepted to show a confirmation.

Move/copy the sidecar with the source; rename both matching prefixes together.
No absolute source path is stored. Including the original extension avoids
collisions between, for example, photo.dng and photo.jpg. The application-specific
suffix avoids overwriting another editor's photo.xmp.

The XMP property `darkmelon:Recipe`, namespace
`urn:dark-melon:development:1.0/`, is a UTF-8 JSON string containing:

- `version`: schema/processing recipe version, currently 1
- `colorSpace`: sRGB, Display P3, or Rec.2020
- `mapping`: ToneMapping's stored values (tone, white balance, monochrome,
  color, HLS, effects and transform), including RGB gains and RAW temperature/tint
- `rawSettings`: optional RAW decoder adjustments, including exposure, shadow bias,
  noise reduction and supported corrections

Preview mode, zoom, compare state, export options, and histogram UI are excluded.
Older recipes without RAW settings use decoder defaults. The recipe applies to the original source, not to
an already rendered export. Other applications can carry/read the XMP, but
cannot reproduce Dark Melon's processing without implementing these controls.

Atomic writes replace only the small sidecar. Image bytes are never opened for
writing, scanned, or copied by the settings store. Existing unrelated XMP fields
are preserved. Invalid existing XMP is not overwritten. Import rejects unknown
recipe versions and invalid parameter ranges; missing additive fields inherit
defaults. Failure to read a recipe doesn't prevent opening the image.

Sandbox access to the containing directory is needed to create/read sidecars.
The folder browser grants that access. Opening an individual file alone may not
grant access to its siblings; the app offers a containing-folder access prompt
and remembers granted access. You can also open its folder in the browser. Read-only locations cannot save recipes.

Tests: work/DevelopmentRecipeCheck.swift and work/RecipeStoreCheck.swift in the
Codex task workspace cover round trips, validation, missing fields, metadata
preservation, portable rename, corrupt-sidecar protection, and untouched source
bytes. GUI interaction and sandbox permission flows require in-app testing.

Transform settings store four normalized source-image corners, the output aspect
ratio control, rotation, and perspective controls. Older recipes without a
transform remain uncropped. The same geometry applies to SDR and HDR before
export resizing and gain-map generation. The Transform panel shows conservative
(shortest aspect-normalized edge) and maximum (longest aspect-normalized edge)
resolution estimates. Dimensions are rounded down at the crop aspect ratio.
The maximum estimate defines 100% export size; it can interpolate less-detailed
parts of a perspective crop. Batch export applies one shared percentage to each
image's own maximum dimensions, rather than a shared pixel size. Original image
pixels remain untouched.

Processing order is RAW decoding (including decoder white balance), tone mapping,
Effects (Clarity, HDF, Halation, Film Grain), RGB white balance or monochrome
conversion, Color, HLS, then crop/geometry and export resizing. Grain distribution
uses source-linear luminance. HDF blurs the full linear source; Halation blurs its
full red and green channels without black/white-point thresholds or normalization.
Halation’s slider shapes these inputs before blur with exponent 1/value (zero is
off, one is linear); values above one retain their linear headroom. Its blend
strength is HDR output brightness divided by 5, capped at 1.0 and shared by both renditions.
Green uses red’s blur radius divided by sqrt(2), with Transmission controlling its
contribution. These source references remain independent of tone and later color
adjustments; the effects are blended into the tone-mapped rendition.

Undo/redo keeps up to 100 development recipe snapshots per file in memory, with
one step per pointer gesture (including Auto Tones adjustments). Keyboard changes
are coalesced briefly. A committed transform is one step. Undo restores the saved
values directly, reloading RAW decoding only when its settings or color space
changed. Saving preserves history; dirty state is still compared with the saved
recipe. Changing folders/discarding the session clears history. Browser paste
also records history for files that are not currently displayed. Regression checks:
`Tests/check-edit-history.sh` on Apple Silicon macOS with Xcode installed.

Preview resolution follows the available view size in physical display pixels.
The decoded linear CIImage graph is retained, together with one cached overview,
rather than materializing a full-resolution developed bitmap for interaction.
On macOS, a separate worker refines the visible zoomed region after 200 ms idle,
with cancellation checks and source/settings identity guards. Two overscanned
patches are retained for the active panel’s edited and comparison states, and
reused for nearby pans. Holding Compare does not pause detail rendering; its
counterpart is prefetched while idle. Resolution is capped at source/output 1:1.
Core Image evaluates the full logical effect/transform graph with a final crop,
so blur ROI expansion and image-relative effect sizes remain intact. Native
nearest-neighbor switching uses source/output pixels instead of overview pixels.
Transform editing and tone/clipping masks use the overview. RAW decoding itself
may still require full-source work; this optimization limits downstream renders.
Regression checks: `Tests/check-preview-detail.sh`.

Vignette is a pre-tone linear exposure adjustment in Effects. Amount is corner
loss in stops (0–4, default 0); Spread (0–1, default 0.5) sets exponent
`2 * 8^(1-spread)`. RGB is multiplied by `2^(-amount * radius^exponent)`;
alpha is preserved. Radius is circular distance divided by the crop half-diagonal.
The inverse committed crop homography maps full-source coordinates into this
geometry. Draft transforms leave the anchor unchanged until committed. Uncropped
overviews retain this anchor; viewport patches evaluate the same full-image graph.
The source histogram stays unchanged. Downstream tone mapping, effects, sampling,
and SDR histograms see the adjusted input. Amount zero bypasses the kernel.
Old recipes default to Off; Effects paste, compare, reset and undo include it.
`Tests/VignetteChecks.swift` exercises GPU falloff, transformed geometry and recipes;
preview detail and edit history checks include nonzero vignette settings.

Offset (RAW panel after Shadow Bias, -0.02…0.02, default zero) adds the same linear RGB value
before vignette and tone mapping. Negative RGB results are bounded to zero;
values above one and alpha are preserved. It bypasses processing at zero,
belongs to RAW copy/paste and Reset RAW, and is stored in recipes/undo.
The original-source histogram remains unchanged. Sampling and locator masks
use the adjusted input, as with vignette. Regression: `Tests/OffsetChecks.swift`.

The two Color multiplier graphs now operate in OKLCH (OKLab polar chroma),
using the post-white-balance pixel in the selected working gamut. Chroma → Chroma
uses C=0…the selected SDR gamut maximum; Lightness → Chroma uses L=0…1 (SDR white), with higher values
using the right endpoint. Both multipliers are evaluated on the input color and
multiplied together. Scaling a/b preserves L and hue; a bounded chroma search
fits out-of-gamut results without per-channel hue distortion. HDR values use
absolute lightness/chroma, not a normalization by HDR Gain. Split Tone uses absolute OKLab lightness and follows these controls. The existing recipe keys
are retained, so previously saved multipliers acquire the new OKLCH behavior.
Conversion reference: https://bottosson.github.io/posts/oklab/
Regression checks: `Tests/OKLCHChecks.swift`.

Both chroma graphs now use four independent multiplier nodes connected by linear
segments: zero, half the SDR endpoint, SDR endpoint, and HDR endpoint. SDR chroma
ends at the working-gamut maximum; SDR lightness ends at 1. HDR endpoints multiply
those by the cube root of the current HDR output ceiling. Beyond the endpoint,
the last multiplier is held constant. HDR Off disables the last handle and uses
the SDR endpoint. The UI reserves separate labeled SDR/HDR intervals for usable
handle spacing, with numeric input values beneath each node. Old quadratic
recipes migrate their midpoint value and repeat the SDR endpoint for HDR.

Split Tone now uses a lightness gradient and OKLCH wheel nodes. Nodes store
absolute OKLab lightness, hue, normalized gamut-relative chroma strength, and UUID.
Clicking the bar adds/selects nodes; handles and a Lightness slider reposition them.
The wheel selects a hue, then radial dragging changes strength along that ray.
Right-click/Delete Node removes a node. Its center is no tint. One node extends
across the entire range; multiple nodes linearly interpolate their a/b offsets
with lightness, holding the outer nodes beyond their positions. Tint is added to
existing a/b, retaining L; out-of-gamut results reduce chroma at the same L/hue.
The bar spans SDR white when HDR is disabled, otherwise the cube root of the HDR
output ceiling. The wheel rim is the selected gamut's maximum chroma at that node's
L and hue within that ceiling. Pure black/maximum white have no chroma capacity.
A 512-entry float lookup table feeds the GPU. Old hue/amount recipes are approximated
with three nodes at lightness 0.2, 0.5, 0.8. New nodes participate in Color reset,
Compare, clipboard, sidecars and undo via the existing Color settings container.
Regression checks: `Tests/SplitToneGradientChecks.swift`.


### Shared OKLab color deformation

Color graphs, gradient split toning, and the experimental six-vertex controls
share one GPU kernel: linear RGB → OKLab → chroma multipliers → vertex deformation →
additive tint → final gamut fit → linear RGB. There is no intermediate RGB
round trip or gamut clipping between those operations. Tone, spatial effects and
RGB white balance remain in their existing linear RGB stages.

The vertex field uses compact hue wedges in OKLab. Each vertex affects only the
sector between its two original neighboring hue faces, independent of its target
position. Smoothstep interpolation between adjacent controls gives zero influence
and zero influence slope at each outer face. Chroma multipliers and rotation
angles interpolate directly; lightness offsets fade smoothly to zero toward the
neutral axis. Uniform chroma edits scale the entire volume consistently, including
complete monochrome at zero. No global radial-basis solve or RGB weights remain.
Extreme edits can still fold the volume within the affected wedges.

HDR evaluates the same field in coordinates normalized by the cube root of its
output ceiling. The Color graphs and tint positions retain their absolute OKLab
coordinates. Final gamut fitting reduces chroma at fixed lightness and hue; it
does not force an out-of-range lightness into the output range.

Validation: `Tests/OKLabVolumeChecks.swift`, `Tests/VertexWarpChecks.swift`,
`Tests/OKLCHChecks.swift`, `Tests/SplitToneGradientChecks.swift`, and
`Tests/PreviewDetailChecks.swift`.

### Scene-linear effect order

Preview and export use this order: decoded source → Offset → HDF → Vignette →
Halation → Film Grain (including its linked blur) → SDR/HDR tone mapping → RGB
white balance → combined OKLab Color stage → Clarity → geometric transform.
Vignette uses the committed crop coordinates even though resampling happens last.
HDF blurs the offset-corrected input; halation reads the vignetted HDF result;
grain's tonal envelope reads the halation result before its own linked blur.
These pre-tone effects preserve values above 1 and do not depend on the selected
SDR/HDR preview. Halation retains its existing HDR enable/strength controls.
Tone/clipping visualization and white-balance sampling follow the adjusted input;
the original-source histogram remains unchanged. This orders the existing effects
by camera/film analogy; it does not turn the additive Offset into exposure gain or
make the artistic glow/grain models a calibrated optical simulation.
