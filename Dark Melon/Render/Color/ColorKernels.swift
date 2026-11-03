import Foundation

// MARK: - ColorPixelKernel

/// Shared OKLab shader math.
nonisolated enum ColorPixelKernel {
    static let functions = """
    // Björn Ottosson's OKLab transform; RGB is linear sRGB, D65.
    vec3 toOKLab(vec3 c) {
        vec3 lms = vec3(dot(c, vec3(0.4122214708,0.5363325363,0.0514459929)),
                        dot(c, vec3(0.2119034982,0.6806995451,0.1073969566)),
                        dot(c, vec3(0.0883024619,0.2817188376,0.6299787005)));
        lms = sign(lms) * pow(abs(lms), vec3(1.0/3.0));
        return vec3(dot(lms,vec3(0.2104542553,0.7936177850,-0.0040720468)),
                    dot(lms,vec3(1.9779984951,-2.4285922050,0.4505937099)),
                    dot(lms,vec3(0.0259040371,0.7827717662,-0.8086757660)));
    }
    vec3 fromOKLab(vec3 c) {
        vec3 lms = vec3(c.x+0.3963377774*c.y+0.2158037573*c.z,
                        c.x-0.1055613458*c.y-0.0638541728*c.z,
                        c.x-0.0894841775*c.y-1.2914855480*c.z);
        lms = lms*lms*lms;
        return vec3(dot(lms,vec3(4.0767416621,-3.3077115913,0.2309699292)),
                    dot(lms,vec3(-1.2684380046,2.6097574011,-0.3413193965)),
                    dot(lms,vec3(-0.0041960863,-0.7034186147,1.7076147010)));
    }
    vec3 convertRGB(vec3 c, vec3 row0, vec3 row1, vec3 row2) {
        return vec3(dot(row0,c),dot(row1,c),dot(row2,c));
    }
    float chromaMultiplier(float x, vec4 points, float hdrEnd) {
        if (x <= 0.5) { return mix(points.x,points.y,clamp(x*2.0,0.0,1.0)); }
        if (x <= 1.0) { return mix(points.y,points.z,(x-0.5)*2.0); }
        if (hdrEnd <= 1.000001) { return points.z; }
        return mix(points.z,points.w,clamp((x-1.0)/(hdrEnd-1.0),0.0,1.0));
    }
    """
}

// MARK: - MonochromeKernel

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

// MARK: - HLSPixelKernel

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
