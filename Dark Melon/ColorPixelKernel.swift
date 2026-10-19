import Foundation

/// Direct per-pixel math, with RGB normalized to the output's SDR/HDR ceiling.
nonisolated enum ColorPixelKernel {
    static let source = """
    vec3 hueRGB(float hue) {
        vec3 p = abs(mod(vec3(hue) + vec3(0.0, 4.0, 2.0), 6.0) - 3.0);
        return clamp(p - 1.0, 0.0, 1.0);
    }
    kernel vec4 colorAdjust(__sample pixel, __sample toneReference, float ceiling, vec3 saturationCurve, vec3 luminanceSaturationCurve,
                           vec4 endpoints, vec2 midpoint, float rimWeight,
                           vec3 amounts, vec3 luminanceWeights) {
        vec4 un = unpremultiply(pixel);
        vec3 rgb = clamp(un.rgb / ceiling, 0.0, 1.0);
        float hi = max(rgb.r, max(rgb.g, rgb.b));
        float lo = min(rgb.r, min(rgb.g, rgb.b));
        float delta = hi - lo;
        float lightness = (hi + lo) * 0.5;
        if (delta > 0.000001) {
            float saturation = delta / max(0.000001, 1.0 - abs(2.0 * lightness - 1.0));
            float multiplier = mix(saturationCurve.x, saturationCurve.y, saturation)
                + saturationCurve.z * saturation * (1.0 - saturation);
            // Linear SDR luminance anchors this axis to the selected black/white range.
            float y = clamp(dot(unpremultiply(toneReference).rgb, luminanceWeights), 0.0, 1.0);
            float luminanceMultiplier = mix(luminanceSaturationCurve.x, luminanceSaturationCurve.y, y)
                + luminanceSaturationCurve.z * y * (1.0 - y);
            float mapped = clamp(saturation * multiplier * luminanceMultiplier, 0.0, 1.0);
            rgb = vec3(lightness) + (rgb - vec3(lightness)) * (mapped / max(saturation, 0.000001));
        }
        if (amounts.x != 0.0 || amounts.y != 0.0 || amounts.z != 0.0) {
            float luminance = dot(rgb, luminanceWeights);
            vec3 offset = rgb - vec3(luminance);
            vec3 limits = mix(vec3(luminance), vec3(1.0 - luminance), step(vec3(0.0), offset));
            vec3 radial = abs(offset) / max(limits, vec3(0.000001));
            float proximity = pow(clamp(1.0 - max(radial.r, max(radial.g, radial.b)), 0.0, 1.0), 2.0);
            // Classify with the SDR rendition, independent of HDR gain or contrast.
            // This is a tonal weight, not an RGB encoding: 18% SDR gray is the midpoint.
            float tone = clamp(dot(unpremultiply(toneReference).rgb, luminanceWeights), 0.0, 1.0);
            float t = tone / max(0.000001, tone + (0.18 / 0.82) * (1.0 - tone));
            vec2 first = t <= 0.5 ? endpoints.xy : midpoint;
            vec2 last = t <= 0.5 ? midpoint : endpoints.zw;
            float localT = t <= 0.5 ? t * 2.0 : (t - 0.5) * 2.0;
            vec2 tint = mix(first, last, localT);
            if (rimWeight > 0.0) {
                float angleA = atan(first.y, first.x);
                float angleB = atan(last.y, last.x);
                float difference = atan(sin(angleB - angleA), cos(angleB - angleA));
                float angle = angleA + difference * localT;
                tint = mix(tint, vec2(cos(angle), sin(angle)), rimWeight);
            }
            float chroma = min(1.0, length(tint));
            if (chroma > 0.000001 && proximity > 0.0) {
                float hue = atan(tint.y, tint.x) * 3.0 / 3.141592653589793;
                vec3 direction = hueRGB(hue);
                direction -= vec3(dot(direction, luminanceWeights));
                direction /= max(0.000001, max(abs(direction.r), max(abs(direction.g), abs(direction.b))));
                float amount = mix(amounts.x, amounts.y, t) + amounts.z * t * (1.0 - t);
                // Tint is relative to available linear light and fades at both endpoints.
                // The zero-luminance direction preserves brightness in the chosen gamut.
                direction *= amount * chroma * 2.0 * luminance * (1.0 - luminance);
                vec3 available = vec3(1000000.0);
                if (direction.r > 0.000001) { available.r = (1.0 - rgb.r) / direction.r; }
                else if (direction.r < -0.000001) { available.r = -rgb.r / direction.r; }
                if (direction.g > 0.000001) { available.g = (1.0 - rgb.g) / direction.g; }
                else if (direction.g < -0.000001) { available.g = -rgb.g / direction.g; }
                if (direction.b > 0.000001) { available.b = (1.0 - rgb.b) / direction.b; }
                else if (direction.b < -0.000001) { available.b = -rgb.b / direction.b; }
                float scale = min(1.0, min(available.r, min(available.g, available.b))) * proximity;
                rgb += direction * scale;
            }
        }
        return premultiply(vec4(clamp(rgb, 0.0, 1.0) * ceiling, un.a));
    }
    """
}
