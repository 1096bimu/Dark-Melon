import Foundation
@testable import Dark_Melon
@main struct Check {
 @MainActor static func main() async throws {
  let h=EditHistory()
  let a=URL(fileURLWithPath:"/tmp/a.dng"), b=URL(fileURLWithPath:"/tmp/b.dng")
  let initial=DevelopmentRecipe(colorSpace:.displayP3,mapping:ToneMapping())
  var restored:DevelopmentRecipe?
  h.restore={restored=$0}
  h.activate(a,recipe:initial)
  assert(!h.canUndo && !h.canRedo)
  h.interacting=true
  var edited=initial
  edited.mapping.tonePosition=0.2
  h.observe(edited)
  try await Task.sleep(for:.milliseconds(500))
  edited.mapping.white=0.7;edited.mapping.hdrTarget=7
  h.observe(edited)
  h.interacting=false;h.flush()
  h.undo();assert(restored==initial && !h.canUndo && h.canRedo)
  h.redo();assert(restored==edited && h.canUndo && !h.canRedo)
  // Reloading decoded pixels and saving must not clear history.
  h.activate(a,recipe:edited)
  h.undo();assert(restored==initial)
  var branch=initial;branch.mapping.concentration=0.8
  h.observe(branch);h.flush();assert(!h.canRedo)
  // Independent file stacks survive switching back and forth.
  h.activate(b,recipe:initial)
  var other=initial;other.mapping.halation.inputCurve=0.6
  h.observe(other);h.flush()
  h.activate(a,recipe:branch);h.undo();assert(restored==initial)
  h.activate(b,recipe:other);h.undo();assert(restored==initial)
  h.redo();assert(restored==other)
  // Non-current-file paste gets its own undo step.
  h.record(a,from:initial,to:edited,name:"Paste")
  h.activate(a,recipe:edited);h.undo();assert(restored==initial)
  h.redo();assert(restored==edited)
  // Returning exactly to a gesture's start creates no extra action.
  h.clear();h.activate(a,recipe:initial)
  h.observe(edited);h.observe(initial);h.flush();assert(!h.canUndo)
  // Complete recipes restore RAW, color space, and effects together.
  var all=initial;all.colorSpace = .sRGB;all.rawSettings=RAWSettings()
  all.mapping.whiteBalance=WhiteBalance(red:1.2,green:0.8,blue:1)
  all.mapping.halation.inputCurve=0.8
  all.mapping.vignette=VignetteSettings(amount:2,spread:0.7)
  h.observe(all);h.flush();h.undo();assert(restored==initial)
  h.redo();assert(restored==all)
  var pending=PendingEdits()
  pending.remember(url:a,recipe:initial,baseline:all,saved:all)
  assert(pending.entry(for:a) != nil)
  pending.remember(url:a,recipe:all,baseline:all,saved:all)
  assert(pending.entry(for:a) == nil)
  // Deferred gestures publish only their final state, with one undo step.
  h.clear();h.activate(a,recipe:initial)
  h.interacting=true
  let revision=h.revision
  var live=initial
  for step in 0..<100 { live.mapping.concentration=Double(step)/100 }
  assert(h.revision==revision && !h.canUndo)
  h.interacting=false;h.observe(live);h.flush()
  h.undo();assert(restored==initial && !h.canUndo)
  h.redo();assert(restored==live)
  h.clear();assert(!h.canUndo && !h.canRedo)
  print("PASS: grouped edits, reciprocal redo, branch invalidation, per-file histories, reload/save retention, offscreen paste, exact recipes, dirty-state comparison.")
 }
}
