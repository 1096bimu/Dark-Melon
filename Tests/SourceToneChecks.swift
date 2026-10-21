import Foundation
@testable import Dark_Melon
@main struct Check {
 static func main() throws {
  var mapping=ToneMapping()
  assert(mapping.tonePosition==0.183 && mapping.white==1 && mapping.concentration==0.2)
  mapping.black=0.1;mapping.white=0.7
  assert(mapping.peakPosition==0.183)
  let recipe=DevelopmentRecipe(colorSpace:.sRGB,mapping:mapping)
  let decoded=try DevelopmentRecipe.decode(recipe.encoded());assert(decoded==recipe)
  var doc=try JSONSerialization.jsonObject(with:recipe.encoded()) as! [String:Any]
  var old=doc["mapping"] as! [String:Any];old.removeValue(forKey:"toneUsesSourceLuminance");old["tonePosition"]=0.5;doc["mapping"]=old
  let migrated=try DevelopmentRecipe.decode(JSONSerialization.data(withJSONObject:doc))
  assert(abs(migrated.mapping.peakPosition-0.4)<1e-12)
  let auto=ToneSampleWhitePoint.automaticTones(mapping:mapping,space:.sRGB)
  assert(auto.tonePosition==mapping.tonePosition)
  for tone in [0.0,0.183,1.0] {
   mapping.tonePosition=tone;mapping.setAutomaticHDRTarget()
   for hdr in [false,true] { assert(mapping.curve(hdr:hdr).values.allSatisfy{$0.isFinite}) }
  }
  print("PASS: source-relative Tone, defaults, old recipe migration, explicit Auto Tones shade retention, finite endpoint curves")
 }
}
