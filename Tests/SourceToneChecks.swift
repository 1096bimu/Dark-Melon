import Foundation
import CoreGraphics
@testable import Dark_Melon
@main struct Check {
 static func main() throws {
  var mapping=ToneMapping()
  assert(mapping.tonePosition==0.183 && mapping.white==1 && mapping.concentration==0.2)
  mapping.white=0.7
  assert(mapping.peakPosition==0.183)
  let recipe=DevelopmentRecipe(colorSpace:.sRGB,mapping:mapping)
  let saved = try JSONSerialization.jsonObject(with: recipe.encoded()) as! [String:Any]
  assert((saved["mapping"] as! [String:Any])["black"] == nil)
  let decoded=try DevelopmentRecipe.decode(recipe.encoded());assert(decoded==recipe)
  var doc=try JSONSerialization.jsonObject(with:recipe.encoded()) as! [String:Any]
  var old=doc["mapping"] as! [String:Any];old.removeValue(forKey:"toneUsesSourceLuminance");old["black"]=0.1;old["tonePosition"]=0.5;doc["mapping"]=old
  let migrated=try DevelopmentRecipe.decode(JSONSerialization.data(withJSONObject:doc))
  assert(abs(migrated.mapping.peakPosition-0.4)<1e-12)
  for tone in [0.0,0.183,1.0] {
   mapping.tonePosition=tone;mapping.setAutomaticHDRTarget()
   for hdr in [false,true] { assert(mapping.curve(hdr:hdr).values.allSatisfy{$0.isFinite}) }
  }
  let sdr = ToneMapping.fresh(isRAW: false, sourceHeadroom: 1)
  assert(sdr.concentration == 0 && sdr.hdrGain == 0)
  let raw = ToneMapping.fresh(isRAW: true, sourceHeadroom: 1)
  assert(raw.concentration == 0.2 && raw.hdrGain == 1.01)
  for headroom in [1.01, 4.0, 8.0, 30.0, 100.0] {
   let imported = ToneMapping.fresh(isRAW: false, sourceHeadroom: headroom)
   assert(imported.concentration == 0 && imported.white == 1)
   assert(abs(imported.hdrTarget - 1) < 1e-10 && imported.hdrGain == headroom)
   assert(abs(imported.hdrMax - headroom) < 1e-10)
   for step in 0...100 {
    let decoded = headroom * Double(step) / 100
    let normalized = decoded / headroom
    assert(abs(imported.curve(hdr: true).value(at: normalized) - decoded) < 1e-9)
   }
   let recipe = DevelopmentRecipe(colorSpace: .displayP3, mapping: imported)
   let restored = try DevelopmentRecipe.decode(recipe.encoded())
   assert(restored.mapping == imported)
  }
  print("PASS: source Tone, migration, linear SDR defaults, unchanged RAW defaults, HDR identity and recipe round trips through 100x")
 }
}
