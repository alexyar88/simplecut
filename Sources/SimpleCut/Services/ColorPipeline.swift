import CoreImage

enum ColorPipeline {
  static func filters(for settings: ColorSettings) -> [CIFilter] {
    guard !settings.isNeutral else { return [] }
    let controls = CIFilter(name: "CIColorControls")
    controls?.setValue(settings.brightness, forKey: kCIInputBrightnessKey)
    controls?.setValue(settings.contrast, forKey: kCIInputContrastKey)
    controls?.setValue(settings.saturation, forKey: kCIInputSaturationKey)

    let temperature = CIFilter(name: "CITemperatureAndTint")
    temperature?.setValue(CIVector(x: 6_500, y: 0), forKey: "inputNeutral")
    temperature?.setValue(
      CIVector(x: 6_500 + settings.warmth * 1_500, y: 0),
      forKey: "inputTargetNeutral"
    )
    return [controls, temperature].compactMap { $0 }
  }
}
