#pragma once
#include HLSLSupport.glsl

#define HISTOGRAM_THREAD_COUNT 16
#define NUM_HISTOGRAM_BINS 256
#define EPSILON 0.0001

// @TODO refactor this to be just shared post fx params
PK_DECLARE_CBUFFER(pk_TonemappingParams)
{
    float pk_MinLogLuminance;
    float pk_InvLogLuminanceRange;
    float pk_LogLuminanceRange;
    float pk_TargetExposure;
    float pk_AutoExposureSpeed;
    float pk_BloomIntensity;
    float pk_BloomDirtIntensity;
    float pk_Vibrance;
    float4 pk_VignetteGrain;
    float4 pk_WhiteBalance;
	float4 pk_Lift;
	float4 pk_Gamma;
	float4 pk_Gain;
	float4 pk_ContrastGainGammaContribution;
	float4 pk_HSV;
	float4 pk_ChannelMixerRed;
	float4 pk_ChannelMixerGreen;
	float4 pk_ChannelMixerBlue;
    sampler2D pk_BloomLensDirtTex;
    sampler2DArray pk_HDRScreenTex;
    sampler2D pk_FilmGrainTex;
};

PK_DECLARE_BUFFER(uint, pk_Histogram);

#define LOG_LUMINANCE_MIN pk_MinLogLuminance
#define LOG_LUMINANCE_INV_RANGE pk_InvLogLuminanceRange
#define LOG_LUMINANCE_RANGE pk_LogLuminanceRange
#define TARGET_EXPOSURE pk_TargetExposure
#define EXPOSURE_ADJUST_SPEED pk_AutoExposureSpeed

const float3x3 LIN_2_LMS_MAT = float3x3(
    3.90405e-1, 5.49941e-1, 8.92632e-3,
    7.08416e-2, 9.63172e-1, 1.35775e-3,
    2.31082e-2, 1.28021e-1, 9.36245e-1);

const float3x3 LMS_2_LIN_MAT = float3x3(
     2.85847e+0, -1.62879e+0, -2.48910e-2,
    -2.10182e-1,  1.15820e+0,  3.24281e-4,
    -4.18120e-2, -1.18169e-1,  1.06867e+0);

float GetAutoExposure()
{
    return uintBitsToFloat(PK_BUFFER_DATA(pk_Histogram, 256));
}

void SetAutoExposure(float exposure)
{
    PK_BUFFER_DATA(pk_Histogram, 256) = floatBitsToUint(exposure);
}

// Source: https://media.contentapi.ea.com/content/dam/eacom/frostbite/files/course-notes-moving-frostbite-to-pbr-v2.pdf
float ComputeEV100( float aperture, float shutterTime, float ISO)
{
    // EV number is defined as:
    // 2^ EV_s = N^2 / t and EV_s = EV_100 + log2 (S /100)
    // This gives
    // EV_s = log2 (N^2 / t)
    // EV_100 + log2 (S /100) = log2 (N^2 / t)
    // EV_100 = log2 (N^2 / t) - log2 (S /100)
    // EV_100 = log2 (N^2 / t . 100 / S)
    return log2(pow2(aperture) / shutterTime * 100 / ISO);
}

float ComputeEV100FromAvgLuminance( float avgLuminance)
{
    // We later use the middle gray at 12.7% in order to have
    // a middle gray at 18% with a sqrt (2) room for specular highlights
    // But here we deal with the spot meter measuring the middle gray
    // which is fixed at 12.5 for matching standard camera
    // constructor settings (i.e. calibration constant K = 12.5)
    // Reference : http://en.wikipedia.org/wiki/Film_speed
    return log2(avgLuminance * 100.0f / 12.5f);
}

float ConvertEV100ToExposure( float EV100)
{
    // Compute the maximum luminance possible with H_sbs sensitivity
    // maxLum = 78 / ( S * q ) * N^2 / t
    // = 78 / ( S * q ) * 2^ EV_100
    // = 78 / (100 * 0.65) * 2^ EV_100
    // = 1.2 * 2^ EV
    // Reference : http://en.wikipedia.org/wiki/Film_speed
    float maxLuminance = 1.2f * pow(2.0f , EV100);
    return 1.0f / maxLuminance;
}

float3 TonemapHejlDawson(half3 color, float exposure)
{
	const half a = 6.2;
	const half b = 0.5;
	const half c = 1.7;
	const half d = 0.06;

	color *= exposure;
	color = max(float3(0.0), color - 0.004);
	color = (color * (a * color + b)) / (color * (a * color + c) + d);
	return color * color;
}

float3 Saturation(float3 color, float amount) 
{
	float grayscale = dot(color, float3(0.3, 0.59, 0.11));
	return lerp_true(grayscale.xxx, color, 0.8f);
}

float3 FilmGrain(float3 color, float2 uv, float2 size)
{
    uv *= size;
    uv /= textureSize(pk_FilmGrainTex, 0).xy * 2.0f;

    float3 grain = tex2D(pk_FilmGrainTex, uv).rgb;
    float lum = 1.0 - sqrt(dot(pk_Luminance.xyz, saturate(color)));
    lum = lerp(1.0, lum, pk_VignetteGrain.z);
    return color.rgb + color.rgb * grain * pk_VignetteGrain.w * lum;
}

float Vignette(float2 uv)
{
    uv *=  1.0 - uv.yx;   
    return pow(uv.x * uv.y * pk_VignetteGrain.x, pk_VignetteGrain.y); 
}

float3 LinearToGamma(float3 color)
{
	//Source: http://chilliant.blogspot.com.au/2012/08/srgb-approximations-for-hlsl.html?m=1
	float3 S1 = sqrt(color);
	float3 S2 = sqrt(S1);
	float3 S3 = sqrt(S2);
	return 0.662002687 * S1 + 0.684122060 * S2 - 0.323583601 * S3 - 0.0225411470 * color;
}

float3 RgbToHsv(float3 c)
{
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = lerp(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = lerp(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    half d = q.x - min(q.w, q.y);
    half e = 1.0e-4;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

float3 HsvToRgb(float3 c)
{
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * lerp(K.xxx, saturate(p - K.xxx), c.y);
}

float3 ApplyColorGrading(float3 color)
{
    float3 final = saturate(color);

    float contrast = pk_ContrastGainGammaContribution.x;
    float gain = pk_ContrastGainGammaContribution.y;
    float gamma = pk_ContrastGainGammaContribution.z;
    float contribution = pk_ContrastGainGammaContribution.w;

    // White balance
    float3 lms = mul(LIN_2_LMS_MAT, final);
    lms *= pk_WhiteBalance.xyz;
    final = mul(LMS_2_LIN_MAT, lms);

    // Lift/gamma/gain
    final = max(final, 0.0);
    final = pk_Gain.xyz * (pk_Lift.xyz * (1.0 - final) + pow(final, pk_Gamma.xyz));

    // Hue/saturation/value
    float3 hsv = RgbToHsv(final);
    hsv.x = mod(hsv.x + pk_HSV.x, 1.0);
    hsv.yz *= pk_HSV.yz;
    final = saturate(HsvToRgb(hsv));
    
    // Vibrance
    float sat = max(final.r, max(final.g, final.b)) - min(final.r, min(final.g, final.b));
    final = lerp(dot(final, pk_Luminance.xyz).xxx, final, (1.0 + (pk_Vibrance * (1.0 - (sign(pk_Vibrance) * sat)))));
    
    // Contrast
    final = saturate((final - 0.5) * contrast + 0.5);

    // Gain
    float f = pow(2.0, gain) * 0.5;
    final.r = final.r < 0.5f ? pow(final.r, gain) * f : 1.0f - pow(1.0f - final.r, gain) * f;
    final.g = final.g < 0.5f ? pow(final.g, gain) * f : 1.0f - pow(1.0f - final.g, gain) * f;
    final.b = final.b < 0.5f ? pow(final.b, gain) * f : 1.0f - pow(1.0f - final.b, gain) * f;

    // Gamma
    final = pow(final, gamma.xxx);

    // Color mixer
    final = float3(
        dot(final, pk_ChannelMixerRed.rgb),
        dot(final, pk_ChannelMixerGreen.rgb),
        dot(final, pk_ChannelMixerBlue.rgb)
    );

    return lerp(color, final, contribution);
}