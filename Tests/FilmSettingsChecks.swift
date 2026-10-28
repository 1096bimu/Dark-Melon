import Foundation
@testable import Dark_Melon

@main struct FilmSettingsChecks {
    static func main() throws {
        var film = ToneMapping()
        film.concentration = 0.6
        film.channelContrast = [0.1, -0.1, 0]
        film.color.saturationMid = 0.7
        film.color.monochrome = true
        film.vertexWarp[0].chroma = 0.4
        film.grain.strength = 1.2
        film.halation.inputCurve = 0.6
        film.lutID = UUID()
        let lock = FilmSettings(film)
        var photo = ToneMapping()
        photo.white = 0.7
        photo.tonePosition = 0.1
        photo.hdrGain = 3
        photo.hdrRolloff = 0.5
        photo.whiteBalance.red = 1.7
        photo.color.splitTone.shadowAmount = 0.2
        photo.clarity = 0.9
        photo.clarityRadius = 60
        photo.hdf = 0.12
        photo.hdfRadius = 130
        photo.vignette.amount = 2
        photo.offset = 0.01
        let result = lock.applying(to: photo)
        assert(result.white == photo.white && result.tonePosition == photo.tonePosition)
        assert(result.concentration == film.concentration)
        assert(result.channelContrast == film.channelContrast)
        assert(result.vertexWarp == film.vertexWarp)
        assert(result.grain == film.grain && result.halation == film.halation)
        assert(result.lutID == film.lutID)
        var expectedColor = film.color
        expectedColor.splitTone = photo.color.splitTone
        assert(result.color == expectedColor)
        // Restore the transferred fields to verify every other field is untouched,
        // except the derived HDR target which must follow the new contrast.
        var retained = result
        retained.white = photo.white
        retained.tonePosition = photo.tonePosition
        retained.concentration = photo.concentration
        retained.channelContrast = photo.channelContrast
        retained.color = photo.color
        retained.vertexWarp = photo.vertexWarp
        retained.blackAndWhite = photo.blackAndWhite
        retained.hls = photo.hls
        retained.grain = photo.grain
        retained.halation = photo.halation
        retained.lutID = photo.lutID
        retained.hdrTarget = photo.hdrTarget
        assert(retained == photo)
        assert(lock.applying(to: result) == result)
        assert(FilmSettings.film.contains(.contrastDistribution))
        assert(FilmSettings.digital.contains(.contrastDistribution))
        assert(!FilmSettings.film.contains(.whitePoint) && !FilmSettings.film.contains(.tone))
        assert(!FilmSettings.digital.contains(.whitePoint) && !FilmSettings.digital.contains(.tone))
        let isoEdit = ToneISOProxy.applying(exposure: 2, to: result)
        assert(isoEdit.white == 0.25 && isoEdit.tonePosition == result.tonePosition * 0.25 / result.white)
        assert(isoEdit.concentration == result.concentration)
        let nextPhoto = lock.applying(to: photo)
        assert(nextPhoto.white == result.white && nextPhoto.tonePosition == result.tonePosition)
        for preset in [FilmSettings.film, FilmSettings.digital] {
            let old = SettingsPasteSelection(items: preset.selectedItems.union([.whitePoint, .tone]))
            assert(FilmSettings.restoredSelection(old) == preset)
        }
        let custom = SettingsPasteSelection(items: [.whitePoint, .tone])
        assert(FilmSettings.restoredSelection(custom) == custom)
        let customLock = FilmSettings(film, selection: custom).applying(to: photo)
        assert(customLock.white == film.white && customLock.tonePosition == film.tonePosition)
        let recipe = DevelopmentRecipe(colorSpace: .displayP3, mapping: result)
        let decoded = try DevelopmentRecipe.decode(recipe.encoded())
        assert(decoded.mapping == result)
        assert(FilmSettings.digital.selectedItems == FilmSettings.film.selectedItems.subtracting([.rawWhiteBalance, .chromaCurve]).union([.rgbWhiteBalance, .clarity]))
        let digital = FilmSettings(film, selection: FilmSettings.digital).applying(to: photo)
        assert(digital.color.saturationMid == photo.color.saturationMid)
        assert(digital.whiteBalance == film.whiteBalance)
        assert(digital.concentration == film.concentration)
        assert(FilmSettings.digital.contains(.rgbWhiteBalance))
        assert(!FilmSettings.digital.contains(.rawWhiteBalance))
        assert(FilmSettings.film.contains(.rawWhiteBalance))
        assert(!FilmSettings.film.contains(.clarity) && FilmSettings.digital.contains(.clarity))
        var rawFilm = film
        rawFilm.rawWhiteBalance = try JSONDecoder().decode(RAWWhiteBalance.self, from: Data(#"{"temperature":5000,"tint":10}"#.utf8))
        var rawPhoto = photo
        rawPhoto.rawWhiteBalance = try JSONDecoder().decode(RAWWhiteBalance.self, from: Data(#"{"temperature":6500,"tint":-5}"#.utf8))
        let rawResult = FilmSettings(rawFilm).applying(to: rawPhoto)
        assert(rawResult.rawWhiteBalance == rawFilm.rawWhiteBalance)
        let rawDigital = FilmSettings(rawFilm, selection: FilmSettings.digital).applying(to: rawPhoto)
        assert(rawDigital.rawWhiteBalance == rawPhoto.rawWhiteBalance)
        assert(rawDigital.whiteBalance == rawFilm.whiteBalance)
        assert(FilmSettings(rawFilm).applying(to: photo).rawWhiteBalance == nil)
        assert(FilmSettings(film, selection: FilmSettings.digital).applying(to: photo).clarity == film.clarity)
        // Individual leaves can be locked independently of their panel.
        let splitOnly = FilmSettings(film, selection: SettingsPasteSelection(items: [.splitTone])).applying(to: photo)
        assert(splitOnly.color.splitTone == film.color.splitTone)
        assert(splitOnly.concentration == photo.concentration && splitOnly.grain == photo.grain)
        var raw = RAWSettings(); raw.values[.exposure] = -1.5; raw.values[.shadowBias] = 0
        var otherRAW = RAWSettings(); otherRAW.values[.exposure] = 1; otherRAW.values[.shadowBias] = 2
        let exposureOnly = FilmSettings(film, rawSettings: raw, selection: SettingsPasteSelection(items: [.exposure]))
        let updatedRAW = exposureOnly.applyingRAW(to: otherRAW)!
        assert(updatedRAW.values[.exposure] == -1.5 && updatedRAW.values[.shadowBias] == 2)
        print("PASS: film transfer, per-photo exclusions, idempotence, recipe round trip")
    }
}
