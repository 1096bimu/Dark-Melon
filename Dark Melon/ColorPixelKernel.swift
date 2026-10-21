import Foundation

/// Direct per-pixel math, with RGB normalized to the output's SDR/HDR ceiling.
nonisolated enum ColorPixelKernel {
    static let source = """
    vec3 hueRGB(float hue) {
        vec3 p = abs(mod(vec3(hue) + vec3(0.0, 4.0, 2.0), 6.0) - 3.0);
        return clamp(p - 1.0, 0.0, 1.0);
    }
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
    kernel vec4 colorAdjust(__sample pixel, __sample toneReference, float ceiling, vec4 saturationCurve, vec4 luminanceSaturationCurve,
                           vec4 endpoints, vec2 midpoint, float rimWeight,
                           vec3 amounts, vec3 luminanceWeights, float maximumChroma, float hdrEnd,
                           vec3 to0, vec3 to1, vec3 to2, vec3 from0, vec3 from1, vec3 from2) {
        vec4 un = unpremultiply(pixel);
        vec3 rgb = clamp(un.rgb / ceiling, 0.0, 1.0);
        // Work in absolute OKLCH units: SDR white L=1, graph endpoint is the working gamut maximum.
        // Scaling a/b together changes chroma without computing or wrapping hue.
        if (saturationCurve.x != 1.0 || saturationCurve.y != 1.0 || saturationCurve.z != 1.0 || saturationCurve.w != 1.0 ||
            luminanceSaturationCurve.x != 1.0 || luminanceSaturationCurve.y != 1.0 || luminanceSaturationCurve.z != 1.0 || luminanceSaturationCurve.w != 1.0) {
            vec3 lab = toOKLab(convertRGB(rgb * ceiling, to0, to1, to2));
            float c = length(lab.yz) / maximumChroma;
            float l = lab.x;
            float multiplier = chromaMultiplier(c,saturationCurve,hdrEnd)
                * chromaMultiplier(l,luminanceSaturationCurve,hdrEnd);
            vec3 target = vec3(lab.x, lab.yz * max(0.0, multiplier));
            vec3 adjusted = convertRGB(fromOKLab(target), from0, from1, from2) / ceiling;
            // Fit chroma to the working gamut at fixed lightness and hue.
            if (min(adjusted.r,min(adjusted.g,adjusted.b)) < -0.000001 ||
                max(adjusted.r,max(adjusted.g,adjusted.b)) > 1.000001) {
                float low = 0.0; float high = 1.0;
                for (int i=0; i<12; i++) {
                    float t = (low+high)*0.5;
                    vec3 candidate = convertRGB(fromOKLab(vec3(target.x,target.yz*t)),from0,from1,from2)/ceiling;
                    if (min(candidate.r,min(candidate.g,candidate.b)) >= 0.0 &&
                        max(candidate.r,max(candidate.g,candidate.b)) <= 1.0) { low=t; }
                    else { high=t; }
                }
                adjusted = convertRGB(fromOKLab(vec3(target.x,target.yz*low)),from0,from1,from2)/ceiling;
            }
            rgb = adjusted;
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
