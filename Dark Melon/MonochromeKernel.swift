import Foundation

nonisolated enum MonochromeKernel {
    static let source = """
    kernel vec4 monochrome(__sample pixel, vec3 weights, vec3 first, vec2 last) {
        vec4 p = unpremultiply(pixel);
        vec3 rgb = max(p.rgb, 0.0);
        rgb /= max(1.0, max(rgb.r, max(rgb.g, rgb.b)));
        float hi = max(rgb.r, max(rgb.g, rgb.b));
        float lo = min(rgb.r, min(rgb.g, rgb.b));
        float delta = hi - lo;
        float sensitivity = 1.0;
        if (delta > 0.000001) {
            float hue;
            if (hi == rgb.r) { hue = mod((rgb.g - rgb.b) / delta, 6.0); }
            else if (hi == rgb.g) { hue = (rgb.b - rgb.r) / delta + 2.0; }
            else { hue = (rgb.r - rgb.g) / delta + 4.0; }
            float magenta = (last.y + first.x) * 0.5;
            float a = first.x, b = first.y;
            if (hue >= 5.0) { a = magenta; b = first.x; }
            else if (hue >= 4.0) { a = last.y; b = magenta; }
            else if (hue >= 3.0) { a = last.x; b = last.y; }
            else if (hue >= 2.0) { a = first.z; b = last.x; }
            else if (hue >= 1.0) { a = first.y; b = first.z; }
            float t = fract(hue);
            // Relative chroma vanishes at neutral colors, including near-white RGB.
            // HSL saturation instead stays at one along an edge leading into white.
            float saturation = delta / max(0.000001, hi);
            sensitivity = mix(1.0, mix(a, b, t*t*(3.0-2.0*t)), clamp(saturation,0.0,1.0));
        }
        float gray = max(0.0, dot(p.rgb, weights) * sensitivity);
        return premultiply(vec4(vec3(gray),p.a));
    }
    """
}
