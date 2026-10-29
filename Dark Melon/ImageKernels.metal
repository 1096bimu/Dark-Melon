// Precompiled Core Image kernels. Keep float precision and premultiplied alpha
// semantics identical across SDR, HDR, preview patches, and export.
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
using namespace coreimage;
namespace coreimage {

// GLSL mod is floor-based, unlike fmod for negative inputs.
static float glslMod(float x, float y) { return x - y * floor(x / y); }


extern "C" float4 filmResponse(sample_t pixel, float3 a0, float3 a1, float3 a2,
                         float3 b0, float3 b1, float3 b2, float3 slopes, float reference, float3 purity) {
    float4 p = unpremultiply(pixel);
    float3 exposed = max(float3(dot(a0,p.rgb), dot(a1,p.rgb), dot(a2,p.rgb)), float3(0.0));
    float3 h = log2(max(exposed,float3(1e-20)) / reference);
    float3 base = float3(1.0) / (float3(1.0) + exp(-h * 0.5));
    float3 layer = float3(1.0) / (float3(1.0) + exp(-h * slopes * 0.5));
    // Three-band cross-absorption, compensated against the same dyes at
    // each channel's neutral exposure to preserve the existing gray response.
    float3 impurity = 1.0 - purity;
    float3 densityDelta = float3(0.0);
    for (int i = 0; i < 3; ++i) {
        float3 neutralLayer = 1.0 / (1.0 + exp(-h[i] * slopes * 0.5));
        float3 weights = i == 0 ? float3(0.0, 0.08, 0.03)
                       : i == 1 ? float3(0.16, 0.0, 0.10)
                                : float3(0.06, 0.20, 0.0);
        densityDelta[i] = 3.0 * dot(weights * impurity, neutralLayer - layer);
    }
    float3 response = exposed * exp2(8.0 * (layer - base - densityDelta));
    float3 returned = max(float3(dot(b0,response), dot(b1,response), dot(b2,response)), float3(0.0));
    return premultiply(float4(returned,p.a));
}


// A shared RGB curve endpoint: every channel below the floor is clipped.
extern "C" float4 shadowFloor(sample_t pixel, float floorValue) {
    float4 p = unpremultiply(pixel);
    p.rgb = max(p.rgb, float3(floorValue));
    return premultiply(p);
}

extern "C" float4 hdfAdd(sample_t pixel, sample_t blurred, float amount) {
    float4 p = unpremultiply(pixel);
    float3 glow = unpremultiply(blurred).rgb;
    return premultiply(float4(max(p.rgb + amount * glow, float3(0.0)), p.a));
}


extern "C" float4 clarityAdjust(sample_t pixel, sample_t blurred, float amount, float ceiling) {
    float4 p = unpremultiply(pixel);
    float3 base = clamp(p.rgb / ceiling, 0.0, 1.0);
    float3 low = unpremultiply(blurred).rgb / ceiling;
    float3 highPass = clamp(float3(0.5) + base - low, 0.0, 1.0);
    if (amount < 0.0) { highPass = 1.0 - highPass; }
    float3 d = mix(((16.0 * base - 12.0) * base + 4.0) * base,
                 sqrt(base), step(float3(0.25), base));
    float3 darken = base - (1.0 - 2.0 * highPass) * base * (1.0 - base);
    float3 lighten = base + (2.0 * highPass - 1.0) * (d - base);
    float3 blended = mix(darken, lighten, step(float3(0.5), highPass));
    float3 result = clamp(mix(base, blended, clamp(abs(amount), 0.0, 2.0)), 0.0, 1.0);
    return premultiply(float4(result * ceiling, p.a));
}


extern "C" float4 toneMap(coreimage::sampler source, coreimage::sampler table, float black, float span,
                    float lastIndex) {
    float4 pixel = unpremultiply(source.sample( source.coord()));
    float3 t = (pixel.rgb - float3(black)) / span;
    float3 u = clamp(t, 0.0, 1.0) * lastIndex + float3(0.5);
    float3 mapped = float3(
        table.sample( table.transform( float2(u.r, 0.5))).r,
        table.sample( table.transform( float2(u.g, 0.5))).g,
        table.sample( table.transform( float2(u.b, 0.5))).b);
    return premultiply(float4(mapped, pixel.a));
}


extern "C" float4 toneLocator(sample_t sourcePixel, sample_t preview, float3 weights,
                        float position, float width, float clipping) {
    float3 rgb = unpremultiply(sourcePixel).rgb;
    float distance = abs(dot(rgb, weights) - position);
    float mask = 1.0 - smoothstep(width * 0.35, width, distance);
    if (clipping > 0.5) { mask = step(position, max(rgb.r, max(rgb.g, rgb.b))); }
    float3 highlight = clipping > 0.5 ? float3(1.0, 0.0, 0.0) : float3(0.21404114);
    float4 base = unpremultiply(preview);
    return premultiply(float4(mix(base.rgb, highlight, mask * 0.9), base.a));
}


extern "C" float4 gain(sample_t base, sample_t alternate, float rgb, float3 weights) {
    float3 s = max(unpremultiply(base).rgb, float3(0.0));
    float3 h = max(unpremultiply(alternate).rgb, float3(0.0));
    if (rgb < 0.5) {
        s = float3(dot(s, weights));
        h = float3(dot(h, weights));
    }
    return float4(log2((h + float3(0.00001)) / (s + float3(0.00001))), 1.0);
}


extern "C" float4 monochrome(sample_t pixel, float3 weights, float3 first, float2 last) {
    float4 p = unpremultiply(pixel);
    float3 rgb = max(p.rgb, 0.0);
    rgb /= max(1.0, max(rgb.r, max(rgb.g, rgb.b)));
    float hi = max(rgb.r, max(rgb.g, rgb.b));
    float lo = min(rgb.r, min(rgb.g, rgb.b));
    float delta = hi - lo;
    float sensitivity = 1.0;
    if (delta > 0.000001) {
        float hue;
        if (hi == rgb.r) { hue = glslMod((rgb.g - rgb.b) / delta, 6.0); }
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
    return premultiply(float4(float3(gray),p.a));
}


extern "C" float4 vignetteExposure(sample_t pixel, float4 extent, float3 row0, float3 row1,
                             float3 row2, float aspect, float amount, float exponent, destination destination) {
    float2 source = (destination.coord() - extent.xy) / extent.zw;
    float3 position = float3(source.x, 1.0 - source.y, 1.0);
    float denominator = dot(row2, position);
    float radius = 1.0;
    // A projective horizon can lie outside the retained crop. Bound its loss
    // to the corner amount so neighboring blur samples stay finite.
    if (abs(denominator) > 0.000001) {
        float2 crop = float2(dot(row0, position), dot(row1, position)) / denominator;
        float2 centered = (2.0 * crop - 1.0) * float2(aspect, 1.0);
        radius = clamp(length(centered) / sqrt(aspect * aspect + 1.0), 0.0, 1.0);
    }
    float gain = exp2(-amount * pow(radius, exponent));
    return float4(pixel.rgb * gain, pixel.a);
}


float encodeLUT(float x, float profile) {
    if (profile < 0.5) {
        float v = abs(x);
        return sign(x) * (v <= 0.0031308 ? 12.92*v : 1.055*pow(v,1.0/2.4)-0.055);
    }
    if (profile < 1.5) {
        float v = abs(x);
        return sign(x) * (v < 0.018 ? 4.5*v : 1.099*pow(v,0.45)-0.099);
    }
    if (profile < 2.5) {
        return x >= 0.01125 ? (420.0+261.5*log((x+0.01)/0.19)/log(10.0))/1023.0
            : (x*(171.2102946929-95.0)/0.01125+95.0)/1023.0;
    }
    if (profile < 3.5) {
        return x < 0.01 ? 5.6*x+0.125 : 0.241514*log(x+0.00873)/log(10.0)+0.598206;
    }
    if (profile < 4.5) {
        float v = x/0.9;
        if (v < -0.014) return -0.36726845*log(1.0-14.98325*v)/log(10.0)+0.12783901;
        if (v <= 0.014) return 1.9754798*v+0.12512219;
        return 0.36726845*log(1.0+14.98325*v)/log(10.0)+0.12240537;
    }
    if (profile < 5.5) {
        return x >= 0.00089 ? 0.344676*log(0.555556*x+0.009468)/log(10.0)+0.790453
            : 8.735631*x+0.092864;
    }
    return x >= 0.000889 ? 0.245281*log(5.555556*x+0.064829)/log(10.0)+0.384316
        : 8.799461*x+0.092864;
}
float decodeLUT(float x, float profile) {
    if (profile < 0.5) {
        float v = abs(x);
        return sign(x) * (v <= 0.04045 ? v/12.92 : pow((v+0.055)/1.055,2.4));
    }
    if (profile < 1.5) {
        float v = abs(x);
        return sign(x) * (v < 0.081 ? v/4.5 : pow((v+0.099)/1.099,1.0/0.45));
    }
    if (profile < 2.5) {
        return x >= 171.2102946929/1023.0 ? pow(10.0,(x*1023.0-420.0)/261.5)*0.19-0.01
            : (x*1023.0-95.0)*0.01125/(171.2102946929-95.0);
    }
    if (profile < 3.5) {
        return x < 0.181 ? (x-0.125)/5.6 : pow(10.0,(x-0.598206)/0.241514)-0.00873;
    }
    if (profile < 4.5) {
        if (x < 0.097465473) return -0.9*(pow(10.0,(0.12783901-x)/0.36726845)-1.0)/14.98325;
        if (x <= 0.15277891) return 0.9*(x-0.12512219)/1.9754798;
        return 0.9*(pow(10.0,(x-0.12240537)/0.36726845)-1.0)/14.98325;
    }
    if (profile < 5.5) {
        return x >= 0.100537775223865 ? (pow(10.0,(x-0.790453)/0.344676)-0.009468)/0.555556
            : (x-0.092864)/8.735631;
    }
    return x >= 0.100686685370811 ? (pow(10.0,(x-0.384316)/0.245281)-0.064829)/5.555556
        : (x-0.092864)/8.799461;
}
extern "C" float4 lutProfile(sample_t source, float3 row0, float3 row1, float3 row2, float profile, float decodeMode) {
    float4 p = unpremultiply(source);
    float3 c = p.rgb;
    if (decodeMode > 0.5) c = float3(decodeLUT(c.r,profile),decodeLUT(c.g,profile),decodeLUT(c.b,profile));
    c = float3(dot(row0,c),dot(row1,c),dot(row2,c));
    if (decodeMode < 0.5) c = float3(encodeLUT(c.r,profile),encodeLUT(c.g,profile),encodeLUT(c.b,profile));
    return premultiply(float4(c,p.a));
}


extern "C" float4 halationInput(sample_t source, float exponent) {
    float4 p = unpremultiply(source);
    float3 positive = max(p.rgb, float3(0.0));
    // Shape the unit interval; preserve above-white headroom without power amplification.
    float3 shaped = pow(min(positive, float3(1.0)), float3(exponent))
        + max(positive - float3(1.0), float3(0.0));
    return premultiply(float4(shaped, p.a));
}


extern "C" float4 halationAdd(sample_t source, sample_t redHalo, sample_t greenHalo, float strength, float transmission, float ceiling, float monochrome) {
    float4 p = unpremultiply(source);
    if (monochrome > 0.5) {
        p.rgb = max(p.rgb + strength * unpremultiply(redHalo).rgb, float3(0.0));
        if (ceiling > 0.0) { p.rgb = min(p.rgb, float3(ceiling)); }
        return premultiply(p);
    }
    float red = unpremultiply(redHalo).r;
    float green = unpremultiply(greenHalo).g;
    p.r = max(p.r + strength * red, 0.0);
    p.g = max(p.g + strength * transmission * green, 0.0);
    if (ceiling > 0.0) { p.rg = min(p.rg, float2(ceiling)); }
    return premultiply(p);
}


extern "C" float4 profileLUT(coreimage::sampler source, coreimage::sampler cube, float3 low, float3 span, float dimension) {
    float4 p = unpremultiply(source.sample(source.coord()));
    float3 t = clamp((p.rgb-low)/span,0.0,1.0)*(dimension-1.0);
    float3 a = floor(t), b = min(a+1.0,float3(dimension-1.0)), f = t-a;
    float3 c000 = cube.sample(cube.transform(float2(a.x,a.y+a.z*dimension)+float2(0.5))).rgb;
    float3 c100 = cube.sample(cube.transform(float2(b.x,a.y+a.z*dimension)+float2(0.5))).rgb;
    float3 c010 = cube.sample(cube.transform(float2(a.x,b.y+a.z*dimension)+float2(0.5))).rgb;
    float3 c110 = cube.sample(cube.transform(float2(b.x,b.y+a.z*dimension)+float2(0.5))).rgb;
    float3 c001 = cube.sample(cube.transform(float2(a.x,a.y+b.z*dimension)+float2(0.5))).rgb;
    float3 c101 = cube.sample(cube.transform(float2(b.x,a.y+b.z*dimension)+float2(0.5))).rgb;
    float3 c011 = cube.sample(cube.transform(float2(a.x,b.y+b.z*dimension)+float2(0.5))).rgb;
    float3 c111 = cube.sample(cube.transform(float2(b.x,b.y+b.z*dimension)+float2(0.5))).rgb;
    float3 c = mix(mix(mix(c000,c100,f.x),mix(c010,c110,f.x),f.y),
                 mix(mix(c001,c101,f.x),mix(c011,c111,f.x),f.y),f.z);
    return premultiply(float4(c,p.a));
}


extern "C" float4 lutDomain(sample_t source, float3 low, float3 span) {
    float4 p = unpremultiply(source);
    // Clamp HDR to SDR white before applying the LUT's declared domain.
    p.rgb = (clamp(p.rgb, 0.0, 1.0) - low) / span;
    return premultiply(p);
}


extern "C" float4 lutHDRGain(sample_t originalHDR, sample_t originalSDR, sample_t gradedSDR) {
    float4 h = unpremultiply(originalHDR);
    float3 s = clamp(unpremultiply(originalSDR).rgb, 0.0, 1.0);
    float3 graded = max(unpremultiply(gradedSDR).rgb, float3(0.0));
    // Match the linear-light offsets used by ISO gain-map generation.
    // Offset reconstruction is identity when the grade is identity,
    // and remains defined for black or zero-valued color channels.
    float3 gain = (max(h.rgb, float3(0.0)) + float3(0.00001)) / (s + float3(0.00001));
    float3 result = max((graded + float3(0.00001)) * gain - float3(0.00001), float3(0.0));
    return premultiply(float4(result, h.a));
}


extern "C" float4 badHDR(sample_t original, sample_t blurred, float strength, float white, float3 weights) {
    float4 p = unpremultiply(original);
    // The SDR-range blurred copy becomes a multiplier from 1 to 0.5.
    // Clamp the mask so HDR highlights cannot invert or darken to black.
    float mask = clamp(dot(unpremultiply(blurred).rgb, weights) / white, 0.0, 1.0);
    // One exposure multiplier preserves RGB ratios. Negative strength
    // applies its reciprocal.
    float multiplier = pow(1.0 - 0.5 * mask, strength);
    return premultiply(float4(p.rgb * multiplier, p.a));
}


// Björn Ottosson's OKLab transform; RGB is linear sRGB, D65.
float3 toOKLab(float3 c) {
    float3 lms = float3(dot(c, float3(0.4122214708,0.5363325363,0.0514459929)),
                    dot(c, float3(0.2119034982,0.6806995451,0.1073969566)),
                    dot(c, float3(0.0883024619,0.2817188376,0.6299787005)));
    lms = sign(lms) * pow(abs(lms), float3(1.0/3.0));
    return float3(dot(lms,float3(0.2104542553,0.7936177850,-0.0040720468)),
                dot(lms,float3(1.9779984951,-2.4285922050,0.4505937099)),
                dot(lms,float3(0.0259040371,0.7827717662,-0.8086757660)));
}
float3 fromOKLab(float3 c) {
    float3 lms = float3(c.x+0.3963377774*c.y+0.2158037573*c.z,
                    c.x-0.1055613458*c.y-0.0638541728*c.z,
                    c.x-0.0894841775*c.y-1.2914855480*c.z);
    lms = lms*lms*lms;
    return float3(dot(lms,float3(4.0767416621,-3.3077115913,0.2309699292)),
                dot(lms,float3(-1.2684380046,2.6097574011,-0.3413193965)),
                dot(lms,float3(-0.0041960863,-0.7034186147,1.7076147010)));
}
float3 convertRGB(float3 c, float3 row0, float3 row1, float3 row2) {
    return float3(dot(row0,c),dot(row1,c),dot(row2,c));
}
float chromaMultiplier(float x, float4 points, float hdrEnd) {
    if (x <= 0.5) { return mix(points.x,points.y,clamp(x*2.0,0.0,1.0)); }
    if (x <= 1.0) { return mix(points.y,points.z,(x-0.5)*2.0); }
    if (hdrEnd <= 1.000001) { return points.z; }
    return mix(points.z,points.w,clamp((x-1.0)/(hdrEnd-1.0),0.0,1.0));
}

    float sliceBend(float L,float C,float4 bend,float apex) {
        float endpoint=L<apex ? bend.x:bend.y;
        float t=clamp(abs(L-apex)/max(0.000001,abs(endpoint-apex)),0.0,1.0);
        float c=clamp(C/0.1,0.0,1.0);
        return (L<apex ? bend.z:bend.w)*t*t*(3.0-2.0*t)*c*c*(3.0-2.0*c);
    }
    // Seven hue controls, matching OKLabVertexWarp.count and Swift argument packing.
    extern "C" float4 combinedOKLab(coreimage::sampler image,coreimage::sampler tintTable,
        float ceiling,float domain,float maximumChroma,float4 chroma,float4 lightness,
        float hasTint,float hasWarp,float colorChrome,
        float3 to0,float3 to1,float3 to2,float3 from0,float3 from1,float3 from2,
        float4 v0,float2 h0,float4 b0,float l0,float4 v1,float2 h1,float4 b1,float l1,float4 v2,float2 h2,float4 b2,float l2,float4 v3,float2 h3,float4 b3,float l3,float4 v4,float2 h4,float4 b4,float l4,float4 v5,float2 h5,float4 b5,float l5,float4 v6,float2 h6,float4 b6,float l6) {
        float4 pixel=unpremultiply(image.sample(image.coord()));
        float3 lab=toOKLab(convertRGB(pixel.rgb,to0,to1,to2));
        float multiplier=chromaMultiplier(length(lab.yz)/maximumChroma,chroma,domain)
            * chromaMultiplier(lab.x,lightness,domain);
        float originalChroma = length(lab.yz);
        lab.yz *= max(0.0,multiplier);
        if (colorChrome > 0.5) {
            lab.x = max(0.0, lab.x + originalChroma - length(lab.yz));
        }
        if (hasWarp > 0.5) {
            float vertexInputChroma = length(lab.yz);
            float scale=pow(ceiling,1.0/3.0);
            float3 q=lab/scale;
            float c=length(q.yz);
            float3 warped=q;
            if (c>0.0000000001) {
                float h=atan2(q.z,q.y);
                if (h<h0.x) { h+=6.28318530718; }
                float3 adjustment=float3(1.0,0.0,0.0);

        if (h>=h0.x && h<=h0.y) {
            float t=(h-h0.x)/(h0.y-h0.x);
            float w=t*t*(3.0-2.0*t);
            adjustment=mix(v0.xyz,v1.xyz,w);
            adjustment.z += mix(sliceBend(q.x,c,b0,l0),sliceBend(q.x,c,b1,l1),w);
            float r0=clamp(c/v0.w,0.0,1.0),r1=clamp(c/v1.w,0.0,1.0);
            adjustment.y=mix(v0.y*r0*r0*(3.0-2.0*r0),v1.y*r1*r1*(3.0-2.0*r1),w);
        }


        if (h>=h1.x && h<=h1.y) {
            float t=(h-h1.x)/(h1.y-h1.x);
            float w=t*t*(3.0-2.0*t);
            adjustment=mix(v1.xyz,v2.xyz,w);
            adjustment.z += mix(sliceBend(q.x,c,b1,l1),sliceBend(q.x,c,b2,l2),w);
            float r0=clamp(c/v1.w,0.0,1.0),r1=clamp(c/v2.w,0.0,1.0);
            adjustment.y=mix(v1.y*r0*r0*(3.0-2.0*r0),v2.y*r1*r1*(3.0-2.0*r1),w);
        }


        if (h>=h2.x && h<=h2.y) {
            float t=(h-h2.x)/(h2.y-h2.x);
            float w=t*t*(3.0-2.0*t);
            adjustment=mix(v2.xyz,v3.xyz,w);
            adjustment.z += mix(sliceBend(q.x,c,b2,l2),sliceBend(q.x,c,b3,l3),w);
            float r0=clamp(c/v2.w,0.0,1.0),r1=clamp(c/v3.w,0.0,1.0);
            adjustment.y=mix(v2.y*r0*r0*(3.0-2.0*r0),v3.y*r1*r1*(3.0-2.0*r1),w);
        }


        if (h>=h3.x && h<=h3.y) {
            float t=(h-h3.x)/(h3.y-h3.x);
            float w=t*t*(3.0-2.0*t);
            adjustment=mix(v3.xyz,v4.xyz,w);
            adjustment.z += mix(sliceBend(q.x,c,b3,l3),sliceBend(q.x,c,b4,l4),w);
            float r0=clamp(c/v3.w,0.0,1.0),r1=clamp(c/v4.w,0.0,1.0);
            adjustment.y=mix(v3.y*r0*r0*(3.0-2.0*r0),v4.y*r1*r1*(3.0-2.0*r1),w);
        }


        if (h>=h4.x && h<=h4.y) {
            float t=(h-h4.x)/(h4.y-h4.x);
            float w=t*t*(3.0-2.0*t);
            adjustment=mix(v4.xyz,v5.xyz,w);
            adjustment.z += mix(sliceBend(q.x,c,b4,l4),sliceBend(q.x,c,b5,l5),w);
            float r0=clamp(c/v4.w,0.0,1.0),r1=clamp(c/v5.w,0.0,1.0);
            adjustment.y=mix(v4.y*r0*r0*(3.0-2.0*r0),v5.y*r1*r1*(3.0-2.0*r1),w);
        }


        if (h>=h5.x && h<=h5.y) {
            float t=(h-h5.x)/(h5.y-h5.x);
            float w=t*t*(3.0-2.0*t);
            adjustment=mix(v5.xyz,v6.xyz,w);
            adjustment.z += mix(sliceBend(q.x,c,b5,l5),sliceBend(q.x,c,b6,l6),w);
            float r0=clamp(c/v5.w,0.0,1.0),r1=clamp(c/v6.w,0.0,1.0);
            adjustment.y=mix(v5.y*r0*r0*(3.0-2.0*r0),v6.y*r1*r1*(3.0-2.0*r1),w);
        }


        if (h>=h6.x && h<=h6.y) {
            float t=(h-h6.x)/(h6.y-h6.x);
            float w=t*t*(3.0-2.0*t);
            adjustment=mix(v6.xyz,v0.xyz,w);
            adjustment.z += mix(sliceBend(q.x,c,b6,l6),sliceBend(q.x,c,b0,l0),w);
            float r0=clamp(c/v6.w,0.0,1.0),r1=clamp(c/v0.w,0.0,1.0);
            adjustment.y=mix(v6.y*r0*r0*(3.0-2.0*r0),v0.y*r1*r1*(3.0-2.0*r1),w);
        }

                warped=float3(q.x+adjustment.y,c*adjustment.x*cos(h+adjustment.z),c*adjustment.x*sin(h+adjustment.z));
            }
            lab=warped*scale;
            if (colorChrome > 0.5) {
                lab.x = max(0.0, lab.x + vertexInputChroma - length(lab.yz));
            }
        }
        if (hasTint > 0.5) {
            lab.yz += tintTable.sample(float2(clamp(lab.x/domain,0.0,1.0)*511.0+0.5,0.5)).xy;
        }
        // Gamut handling is deferred until every OKLab operation is complete.
        // Fit along a straight line toward neutral in linear working RGB.
        // The RGB cube is convex, unlike fixed-L OKLab chroma slices near
        // deep blue: this intersection is unique and continuous, with no
        // branch-search jumps. In-gamut colors remain unchanged. Out-of-gamut
        // colors may change perceptual lightness/hue slightly while fitting.
        float3 rgb=convertRGB(fromOKLab(lab),from0,from1,from2);
        float gray=clamp(lab.x*lab.x*lab.x,0.0,ceiling);
        float3 delta=rgb-float3(gray);
        float fit=1.0;
        float lowest=min(rgb.r,min(rgb.g,rgb.b));
        float highest=max(rgb.r,max(rgb.g,rgb.b));
        if (lowest<0.0) { fit=min(fit,gray/(gray-lowest)); }
        if (highest>ceiling) { fit=min(fit,(ceiling-gray)/(highest-gray)); }
        rgb=clamp(float3(gray)+delta*fit,0.0,ceiling);
        return premultiply(float4(rgb,pixel.a));
    }

} // namespace coreimage
