import Foundation

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
