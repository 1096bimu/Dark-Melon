import Foundation

nonisolated enum HLSPixelKernel {
    static let source = """
    vec3 hlsHueRGB(float hue) {
        return clamp(abs(mod(vec3(hue) + vec3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
    }
    kernel vec4 hlsAdjust(__sample pixel, __sample reference, float ceiling, vec3 weights,
                         vec4 red, vec4 yellow, vec4 green, vec4 cyan, vec4 blue, vec4 magenta,
                         vec3 lightnessA, vec3 lightnessB) {
        vec4 p = unpremultiply(pixel);
        vec3 rgb = clamp(p.rgb / ceiling, 0.0, 1.0);
        float hi = max(rgb.r, max(rgb.g, rgb.b));
        float lo = min(rgb.r, min(rgb.g, rgb.b));
        float delta = hi - lo;
        float lightness = (hi + lo) * 0.5;
        if (delta <= 0.000001 || lightness <= 0.000001 || lightness >= 0.999999) { return pixel; }
        float saturation = delta / max(0.000001, 1.0 - abs(2.0 * lightness - 1.0));
        float hue = 0.0;
        if (hi == rgb.r) { hue = mod((rgb.g - rgb.b) / delta, 6.0); }
        else if (hi == rgb.g) { hue = (rgb.b - rgb.r) / delta + 2.0; }
        else { hue = (rgb.r - rgb.g) / delta + 4.0; }
        vec4 first = red; vec4 last = yellow;
        float firstL = lightnessA.x; float lastL = lightnessA.y;
        if (hue >= 5.0) { first = magenta; last = red; firstL = lightnessB.z; lastL = lightnessA.x; }
        else if (hue >= 4.0) { first = blue; last = magenta; firstL = lightnessB.y; lastL = lightnessB.z; }
        else if (hue >= 3.0) { first = cyan; last = blue; firstL = lightnessB.x; lastL = lightnessB.y; }
        else if (hue >= 2.0) { first = green; last = cyan; firstL = lightnessA.z; lastL = lightnessB.x; }
        else if (hue >= 1.0) { first = yellow; last = green; firstL = lightnessA.y; lastL = lightnessA.z; }
        vec4 control = mix(first, last, fract(hue));
        float coefficient = mix(firstL, lastL, fract(hue));
        float y = clamp(dot(unpremultiply(reference).rgb, weights), 0.0, 1.0);
        float t = y / max(0.000001, y + (0.18 / 0.82) * (1.0 - y));
        float shift = t <= 0.5 ? mix(control.x, control.y, t * 2.0) : mix(control.y, control.z, (t - 0.5) * 2.0);
        // Hue-dependent lightness must fade as hue becomes undefined at neutral.
        // Hue and saturation edits already carry this fade through output chroma.
        float relativeChroma = delta / max(0.000001, hi);
        float mappedL = clamp(lightness + coefficient * relativeChroma * lightness * (1.0 - lightness), 0.0, 1.0);
        float mappedS = clamp(saturation * control.w, 0.0, 1.0);
        float chroma = (1.0 - abs(2.0 * mappedL - 1.0)) * mappedS;
        vec3 result = (hlsHueRGB(hue + shift / 60.0) - 0.5) * chroma + mappedL;
        return premultiply(vec4(clamp(result, 0.0, 1.0) * ceiling, p.a));
    }
    """
}
