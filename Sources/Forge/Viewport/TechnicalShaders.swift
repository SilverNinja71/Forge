/// Forge's Metal shaders, compiled when the app starts (like Paper's, so no offline Metal compiler is needed).
///
/// The look is deliberately plain: matte surfaces, crisp anti-aliased edges and analysis modes rather than
/// realistic materials. Silhouettes are found on the GPU: an edge inside a curved surface is drawn only where
/// one of its two facets faces the viewer and the other faces away.
enum TechnicalShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4x4 viewProj;
        float4 toViewer;
        float4 right;
        float4 up;
        float4 section;      // plane normal xyz, distance w
        float4 pull;         // draft-analysis pull direction xyz, threshold w
        float2 viewport;
        float lineBias;
        int mode;            // 0 shaded, 1 hidden-line paper, 2 zebra, 3 draft analysis
        int sectionOn;
        int pad0;
        int pad1;
        int pad2;
    };

    struct FaceVertex {
        packed_float3 pos;
        packed_float3 normal;
    };

    struct FaceOut {
        float4 position [[position]];
        float3 world;
        float3 normal;
    };

    vertex FaceOut faceVertex(uint vid [[vertex_id]], const device FaceVertex *v [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
        FaceOut o;
        float3 p = v[vid].pos;
        o.position = u.viewProj * float4(p, 1);
        o.world = p;
        o.normal = v[vid].normal;
        return o;
    }

    static inline void clipSection(float3 world, constant Uniforms &u) {
        if (u.sectionOn != 0 && dot(u.section.xyz, world) - u.section.w > 0) discard_fragment();
    }

    fragment float4 faceFragment(FaceOut in [[stage_in]], bool front [[front_facing]], constant Uniforms &u [[buffer(0)]]) {
        clipSection(in.world, u);
        float3 n = normalize(in.normal);
        if (!front) n = -n;
        float3 v = u.toViewer.xyz;
        if (u.mode == 1) return float4(0.975, 0.975, 0.97, 1);
        if (u.mode == 2) {
            // Zebra: striped walls reflected in the surface. Stripes kink where curvature jumps. The walls are fixed
            // to the view, slanted, so a surface curving in any direction shows stripes as you orbit.
            float3 r = reflect(-v, n);
            float bands = asin(clamp(dot(r, normalize(u.right.xyz * 0.85 + u.up.xyz * 0.5)), -1.0, 1.0)) * 5.0;
            float d = fwidth(bands) + 0.001;
            float s = smoothstep(0.5 - d, 0.5 + d, abs(fract(bands) - 0.5) * 2.0);
            float shade = mix(0.08, 0.96, s);
            return float4(shade, shade, shade, 1);
        }
        if (u.mode == 3) {
            // Draft analysis: can this face slide out of a mould pulled along `pull`?
            float d = dot(n, u.pull.xyz);
            float3 base = d > u.pull.w ? float3(0.25, 0.68, 0.36) : (d < -u.pull.w ? float3(0.82, 0.27, 0.24) : float3(0.95, 0.77, 0.23));
            float lit = 0.72 + 0.28 * max(dot(n, v), 0.0);
            return float4(base * lit, 1);
        }
        float3 base = float3(0.72, 0.745, 0.775);
        float head = max(dot(n, normalize(v + u.up.xyz * 0.5 + u.right.xyz * 0.3)), 0.0);
        float sky = 0.5 + 0.5 * dot(n, float3(0, 0, 1));
        float3 color = base * (0.34 + 0.16 * sky + 0.56 * head);
        if (!front) color = float3(0.42, 0.24, 0.22);
        return float4(color, 1);
    }

    fragment void stencilFragment(FaceOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        clipSection(in.world, u);
    }

    fragment float4 tintFragment(FaceOut in [[stage_in]], constant Uniforms &u [[buffer(0)]], constant float4 &tint [[buffer(1)]]) {
        clipSection(in.world, u);
        return tint;
    }

    // The cut surface of a section view, with engineering-drawing hatching.
    fragment float4 capFragment(FaceOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        float along = dot(in.world, normalize(u.right.xyz + u.up.xyz));
        float scale = max(fwidth(along) * 9.0, 0.01);
        float t = abs(fract(along / scale) - 0.5) * 2.0;
        float line = smoothstep(0.82, 0.92, t);
        float3 color = mix(float3(0.78, 0.53, 0.42), float3(0.32, 0.18, 0.14), line);
        return float4(color, 1);
    }

    struct LineInstance {
        packed_float3 a;
        float kind;          // 0 always drawn, 1 only as a silhouette
        packed_float3 b;
        float width;
        packed_float3 n0;
        float pad0;
        packed_float3 n1;
        float pad1;
        float4 color;
    };

    struct LineOut {
        float4 position [[position]];
        float3 world;
        float dist;
        float halfWidth;
        float4 color;
    };

    vertex LineOut lineVertex(uint vid [[vertex_id]], uint iid [[instance_id]], const device LineInstance *lines [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
        const float2 corners[6] = { float2(0, -1), float2(1, -1), float2(0, 1), float2(0, 1), float2(1, -1), float2(1, 1) };
        LineInstance l = lines[iid];
        float2 c = corners[vid];
        LineOut o;
        o.color = l.color;
        o.halfWidth = l.width * 0.5;
        float3 a = l.a, b = l.b;
        o.world = mix(a, b, c.x);
        if (l.kind > 0.5) {
            // Silhouette test: the facets either side must disagree about facing the viewer.
            float3 n0 = l.n0, n1 = l.n1;
            if (dot(n0, u.toViewer.xyz) * dot(n1, u.toViewer.xyz) > 0) {
                o.position = float4(0, 0, 2, 1);
                o.dist = 0;
                return o;
            }
        }
        float4 pa = u.viewProj * float4(a, 1), pb = u.viewProj * float4(b, 1);
        float2 sa = pa.xy * u.viewport * 0.5, sb = pb.xy * u.viewport * 0.5;
        float2 d = sb - sa;
        float len = length(d);
        float2 dir = len > 1e-4 ? d / len : float2(1, 0);
        float2 nrm = float2(-dir.y, dir.x);
        float feather = 0.75;
        float extent = o.halfWidth + feather;
        float along = o.halfWidth * (c.x * 2.0 - 1.0);
        float2 offset = nrm * c.y * extent + dir * along;
        float4 p = mix(pa, pb, c.x);
        p.xy += offset * 2.0 / u.viewport * p.w;
        p.z -= u.lineBias * p.w;
        o.position = p;
        o.dist = c.y * extent;
        return o;
    }

    fragment float4 lineFragment(LineOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        clipSection(in.world, u);
        float alpha = 1.0 - smoothstep(in.halfWidth - 0.25, in.halfWidth + 0.75, abs(in.dist));
        return float4(in.color.rgb, in.color.a * alpha);
    }

    struct BgOut {
        float4 position [[position]];
        float y;
    };

    vertex BgOut backgroundVertex(uint vid [[vertex_id]]) {
        const float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        BgOut o;
        o.position = float4(p[vid], 0, 1);
        o.y = p[vid].y * 0.5 + 0.5;
        return o;
    }

    fragment float4 backgroundFragment(BgOut in [[stage_in]]) {
        return float4(mix(float3(0.80, 0.82, 0.84), float3(0.955, 0.96, 0.965), saturate(in.y)), 1);
    }
    """
}
