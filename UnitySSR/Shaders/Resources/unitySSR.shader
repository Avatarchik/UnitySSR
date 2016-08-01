﻿//The MIT License(MIT)

//Copyright(c) 2016 Charles Greivelding Thomas

//Permission is hereby granted, free of charge, to any person obtaining a copy
//of this software and associated documentation files (the "Software"), to deal
//in the Software without restriction, including without limitation the rights
//to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//copies of the Software, and to permit persons to whom the Software is
//furnished to do so, subject to the following conditions:

//The above copyright notice and this permission notice shall be included in all
//copies or substantial portions of the Software.

//THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//SOFTWARE.

Shader "Hidden/Unity SSR" 
{
	Properties 
	{
		_MainTex ("Base (RGB)", 2D) = "black" {}
	}
	
	CGINCLUDE
	
	#include "UnityCG.cginc"
	#include "UnityPBSLighting.cginc"
    #include "UnityStandardBRDF.cginc"
    #include "UnityStandardUtils.cginc"

	#include "UnitySSRLib.cginc"
	#include "UnityRayTraceLib.cginc"
	#include "UnityNoiseLib.cginc"

	struct VertexInput 
	{
		float4 vertex : POSITION;
		float2 texcoord : TEXCOORD;
	};

	struct VertexOutput
	{
		float4 pos : POSITION;
		float2 uv : TEXCOORD0; 
	};

	VertexOutput vert( VertexInput v ) 
	{
		VertexOutput o;
		o.pos = mul(UNITY_MATRIX_MVP, v.vertex);
		o.uv = v.texcoord;
		return o;
	}

	float4 rayTrace(VertexOutput i) : SV_Target
	{	
		float2 uv = i.uv;
		int2 pos = uv * _RayCastSize.xy;

		float4 worldNormal = GetNormal (uv);
		float3 viewNormal = GetViewNormal (worldNormal);
		float4 specular = GetSpecular (uv);
		float roughness = GetRoughness (specular.a);

		float depth = GetDepth(_CameraDepthTexture, uv);
		float3 screenPos = GetScreenPos(uv, depth);
		float3 viewPos = GetViewPos(screenPos);

		float2 jitter = Step3T(pos, 0.0) * 0.25 + 0.5;
		jitter += 0.5f;

		float3 dir = reflect(normalize(viewPos), viewNormal.xyz);
		
		float4 rayTrace = RayMarch(_CameraDepthTexture, _ProjectionMatrix, dir, _NumSteps, viewPos, screenPos, uv, jitter.x + jitter.y);

		return rayTrace;
	}

	float4 previous( VertexOutput i ) : SV_Target
	{	 
		float2 uv = i.uv;

		float2 velocity = GetVelocity(uv);

		float2 prevUV = uv - velocity;

		float4 sceneColor = tex2D(_MainTex,  prevUV);

		return sceneColor;
	}

	float4 debug( VertexOutput i ) : SV_Target
	{	 
		float2 uv = i.uv;

		float4 specular = GetSpecular (uv);
		float roughness = GetRoughness (specular.a);

		float maxMipLevel = 5.0 - 1.0f;
		float mip = clamp(roughness * 10,0, maxMipLevel);

		float4 frag = tex2Dlod(_MipMapBuffer, float4(uv, 0.0, mip));

		return frag;
	}

	float4 mipMapBlur( VertexOutput i ) : SV_Target
	{	 
		float2 uv = i.uv;

		int NumSamples = 7;

		float4 result = 0.0;
		for(int i = 0; i < NumSamples; i++)
		{
			float2 offset = offsets[i] * _GaussianDir;

			float4 sampleColor = tex2Dlod(_MainTex, float4(uv + offset, 0, _MipMapCount));
			sampleColor.rgb /= 1 + Luminance(sampleColor.rgb);

			result += sampleColor * weights[i];
		}
		result.rgb /= 1 - Luminance(result.rgb);

		return result;
	}
	
	float4 resolve( VertexOutput i ) : SV_Target
	{	 
		float2 uv = i.uv;

		float4 hitPacked = tex2D(_RayCast, uv);
        float2 hitUv = hitPacked.xy;
		float hitZ = hitPacked.z;
		float hitMask = hitPacked.w;

		float4 specular = GetSpecular (uv);
		float roughness = GetRoughness(specular.a);

		float4 reflection = tex2D(_MainTex, hitUv.xy);

		return float4(reflection.rgb, hitMask * RayAttenBorder (hitUv.xy, _EdgeFactor));
	}

	float4 combine( VertexOutput i ) : SV_Target
	{	 
		float2 uv = i.uv;

		float depth = GetDepth(_CameraDepthTexture, uv);
		float3 screenPos = GetScreenPos(uv, depth);
		float3 worldPos = GetWorlPos(screenPos);

		float3 cubemap = GetCubeMap (uv);
		float4 worldNormal = GetNormal (uv);

		float4 diffuse =  GetAlbedo(uv);
		float occlusion = diffuse.a;
		float4 specular = GetSpecular (uv);
		float roughness = GetRoughness(specular.a);

		float3 viewDir = normalize(worldPos.rgb - _WorldSpaceCameraPos);
		float maxMipLevel = 5.0 - 1.0f;
		float mip = clamp(roughness * 10,0, maxMipLevel);

		float3 reflDir = normalize( reflect( -viewDir, worldNormal ) );
		float fade = saturate(dot(-viewDir, reflDir) * 2.0) * saturate(worldNormal.a);

		float4 reflection = tex2Dlod(_ReflectionBuffer, float4(uv.xy, 0, mip));

		float4 sceneColor = tex2D(_MainTex,  uv);
		sceneColor.rgb = max(1e-5, sceneColor.rgb - cubemap.rgb);

		float oneMinusReflectivity;
		diffuse.rgb = EnergyConservationBetweenDiffuseAndSpecular(diffuse, specular.rgb, oneMinusReflectivity);

        UnityLight light;
        light.color = 0;
        light.dir = 0;
        light.ndotl = 0;

        UnityIndirect ind;
        ind.diffuse = 0;
        ind.specular = reflection.rgb;
										
		reflection.rgb = UNITY_BRDF_PBS (0, specular.rgb, oneMinusReflectivity, 1-roughness, worldNormal, -viewDir, light, ind).rgb;

		sceneColor.rgb += lerp(cubemap, reflection.rgb, reflection.a * fade);

		return sceneColor;
	}
	ENDCG 
	
	Subshader 
	{			
		ZTest Always Cull Off ZWrite Off
		Fog { Mode off }

		//0
		Pass 
		{
			CGPROGRAM
			#pragma target 3.0

			#pragma fragmentoption ARB_precision_hint_fastest
			#pragma vertex vert
			#pragma fragment previous
			ENDCG
		}
		//1
		Pass 
		{
			CGPROGRAM
			#pragma target 3.0

			#pragma fragmentoption ARB_precision_hint_fastest
			#pragma vertex vert
			#pragma fragment rayTrace
			ENDCG
		}
		//2
		Pass 
		{
			CGPROGRAM
			#pragma target 3.0

			#pragma fragmentoption ARB_precision_hint_fastest
			#pragma vertex vert
			#pragma fragment mipMapBlur
			ENDCG
		}
		//3
		Pass 
		{
			CGPROGRAM
			#pragma target 3.0

			#pragma fragmentoption ARB_precision_hint_fastest
			#pragma vertex vert
			#pragma fragment resolve
			ENDCG
		}
		//4
		Pass 
		{
			CGPROGRAM
			#pragma target 3.0
			
			#pragma vertex vert
			#pragma fragment combine
			ENDCG
		}
		//5
		Pass 
		{
			CGPROGRAM
			#pragma target 3.0
			
			#pragma vertex vert
			#pragma fragment debug
			ENDCG
		}
	}
	Fallback Off
}
