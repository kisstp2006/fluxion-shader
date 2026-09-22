// SPDX-License-Identifier: BSL-1.0

//! Shaders the tests compile, in one list.
//!
//! The library's own tests each compile a handful of small sources and read
//! what came out. These are the larger ones that exist to be *validated*:
//! handed to `spirv-val` as SPIR-V and to `dxc` as HLSL, which is the only
//! way to know that text or words an emitter wrote are something a real
//! consumer takes. Each one is aimed at something specific and says what.
//!
//! The first four are the shaders the existing suite and the examples
//! compile, copied here so that every shader that suite compiles is also in
//! the list the validators run over.

pub const Shader = struct {
    name: []const u8,
    source: []const u8,
    /// Whether the HLSL written for it is expected to compile. A shader that
    /// is fine in the language and that HLSL cannot say is listed with the
    /// reason, and is still held to SPIR-V and to the text emitters.
    hlsl_valid: bool = true,
};

pub const all = [_]Shader{
    .{ .name = "sprites", .source = sprites },
    .{ .name = "everything", .source = everything },
    .{ .name = "demo", .source = demo },
    .{ .name = "quad", .source = quad },
    .{ .name = "kitchen sink", .source = kitchen_sink },
    .{ .name = "many varyings", .source = many_varyings },
    .{ .name = "loops and discard", .source = loops_and_discard },
    .{ .name = "matrix block", .source = matrix_block },
    .{ .name = "index builtins", .source = index_builtins },
    .{ .name = "promotions", .source = promotions },
    .{ .name = "swizzle assignment", .source = swizzle_assignment },
    .{ .name = "selects and constants", .source = selects_and_constants },
    // The first twelve are pinned by `golden_test.zig`; what follows is not.
    .{ .name = "vertex texture", .source = vertex_texture, .hlsl_valid = false },
    .{ .name = "flat varying", .source = flat_varying },
    .{ .name = "derivative in a function", .source = derivative_in_a_function },
    .{ .name = "matrix attribute", .source = matrix_attribute },
    .{ .name = "loops without a condition", .source = loops_without_a_condition, .hlsl_valid = false },
};

/// How many of `all` the golden hashes cover.
pub const pinned = 12;

/// The sprite shader: an instanced quad, a texture, a matrix from a block.
pub const sprites =
    \\attribute vec2 corner : 0;
    \\attribute vec4 placement : 1;
    \\attribute vec4 tint : 2;
    \\
    \\varying vec2 uv;
    \\varying vec4 colour;
    \\
    \\uniform Frame : 0 {
    \\    mat4 projection;
    \\}
    \\
    \\texture2d atlas : 0;
    \\
    \\vertex {
    \\    vec2 world = placement.xy + corner * placement.zw;
    \\    uv = corner;
    \\    colour = tint;
    \\    position = projection * vec4(world, 0.0, 1.0);
    \\}
    \\
    \\fragment {
    \\    target = sample(atlas, uv) * colour;
    \\}
;

/// Everything the GLSL emitter writes, in one shader.
pub const everything =
    \\attribute vec2 corner : 0;
    \\varying vec2 uv;
    \\uniform Frame : 0 { mat4 projection; float time; }
    \\texture2d atlas : 0;
    \\const float wobble = 0.02;
    \\
    \\vec2 sway(vec2 at, float seconds) {
    \\    return at + vec2(sin(seconds) * wobble, 0.0);
    \\}
    \\
    \\vertex {
    \\    float lane = float(vertex_index) + float(instance_index);
    \\    uv = corner;
    \\    position = projection * vec4(sway(corner, time + lane), 0.0, 1.0);
    \\}
    \\
    \\fragment {
    \\    float total = 0.0;
    \\    for (int i = 0; i < 4; i += 1) { total += 0.25; }
    \\    if (total > 0.9) { total = 1.0; } else { discard; }
    \\    while (total < 0.0) { total += 1.0; }
    \\    float edge = saturate(mod(time, 1.0)) + atan2(uv.y, uv.x) + inversesqrt(2.0);
    \\    edge = edge + ddx(uv.x) + ddy(uv.y) + fract(total);
    \\    vec4 texel = sample(atlas, uv);
    \\    target = mix(texel, texel * vec4(edge), total > 0.5 ? 1.0 : 0.0);
    \\}
;

/// The shader `zig build example` prints.
pub const demo =
    \\attribute vec2 corner : 0;
    \\attribute vec4 placement : 1;
    \\attribute vec4 tint : 2;
    \\
    \\varying vec2 uv;
    \\varying vec4 colour;
    \\
    \\uniform Frame : 0 {
    \\    mat4 projection;
    \\    float time;
    \\}
    \\
    \\texture2d atlas : 0;
    \\
    \\const float wobble = 0.02;
    \\
    \\vec2 sway(vec2 at, float seconds) {
    \\    return at + vec2(sin(seconds) * wobble, 0.0);
    \\}
    \\
    \\vertex {
    \\    vec2 world = placement.xy + corner * placement.zw;
    \\    uv = corner;
    \\    colour = tint;
    \\    position = projection * vec4(sway(world, time), 0.0, 1.0);
    \\}
    \\
    \\fragment {
    \\    vec4 texel = sample(atlas, uv);
    \\    float edge = saturate(mod(time, 1.0));
    \\    target = mix(texel, texel * colour, edge);
    \\}
;

/// The shader `zig build example-quad` draws.
pub const quad =
    \\attribute vec2 corner : 0;
    \\
    \\varying vec2 uv;
    \\varying vec4 shade;
    \\
    \\uniform Frame : 0 {
    \\    mat4 projection;
    \\    vec4 rect;
    \\    vec4 tint;
    \\    float time;
    \\}
    \\
    \\texture2d atlas : 0;
    \\
    \\const float amplitude = 0.06;
    \\
    \\float wave(float at, float seconds) {
    \\    return sin(at * 6.2831 + seconds) * amplitude;
    \\}
    \\
    \\vertex {
    \\    uv = corner;
    \\    shade = mix(vec4(1.0), tint, corner.y);
    \\    vec2 world = rect.xy + corner * rect.zw;
    \\    world.y += wave(corner.x, time) * rect.w;
    \\    position = projection * vec4(world, 0.0, 1.0);
    \\}
    \\
    \\fragment {
    \\    vec4 texel = sample(atlas, uv);
    \\    float band = saturate(mod(uv.x * 4.0, 1.0));
    \\    target = texel * shade * (0.75 + 0.25 * band);
    \\}
;

/// Every type, every operator, and every builtin in the table - the
/// componentwise ones on a scalar, on a vector, and with a scalar standing in
/// among vectors. Two blocks, two textures, a function of each return type,
/// and a constant built from another. If a lowering is wrong anywhere, this
/// is where a validator finds it.
pub const kitchen_sink =
    \\attribute vec2 corner : 0;
    \\attribute vec3 normal : 1;
    \\attribute vec4 tint : 2;
    \\attribute float weight : 3;
    \\attribute int lane : 4;
    \\
    \\varying vec2 uv;
    \\varying vec3 facing;
    \\varying vec4 shade;
    \\varying float depth;
    \\
    \\uniform Frame : 0 {
    \\    mat4 projection;
    \\    mat3 basis;
    \\    mat2 twist;
    \\    vec4 rect;
    \\    vec3 sun;
    \\    vec2 scale;
    \\    float time;
    \\    int steps;
    \\}
    \\
    \\uniform Material : 1 {
    \\    vec4 base;
    \\    float rough;
    \\}
    \\
    \\texture2d atlas : 0;
    \\texture2d detail : 1;
    \\
    \\const float pi = 3.14159;
    \\const float half_pi = pi * 0.5;
    \\const vec3 luma = vec3(0.299, 0.587, 0.114);
    \\const vec2 corner_bias = vec2(1.0, -1.0);
    \\
    \\float lum(vec3 c) {
    \\    return dot(c, luma);
    \\}
    \\
    \\vec2 spin(vec2 p, float angle) {
    \\    float s = sin(angle);
    \\    float c = cos(angle);
    \\    return vec2(p.x * c - p.y * s, p.x * s + p.y * c);
    \\}
    \\
    \\vec3 lit(vec3 n, vec3 to_sun) {
    \\    float d = max(dot(normalize(n), normalize(to_sun)), 0.0);
    \\    return vec3(d);
    \\}
    \\
    \\int pick(int a, int b) {
    \\    if (a > b) {
    \\        return a;
    \\    }
    \\    return b;
    \\}
    \\
    \\bool inside(vec2 p) {
    \\    return p.x > 0.0 && p.y > 0.0 && p.x < 1.0 && p.y < 1.0;
    \\}
    \\
    \\void touch(float x) {
    \\    float y = x * 2.0;
    \\    return;
    \\}
    \\
    \\vertex {
    \\    vec2 p = spin(corner * scale + rect.xy, time * half_pi);
    \\    p = twist * p;
    \\    vec3 n = basis * normal;
    \\    vec3 back = n * basis;
    \\    mat4 pv = projection * projection;
    \\    mat4 half_pv = pv * 0.5;
    \\    mat4 sum = pv + half_pv - projection;
    \\    mat4 quarter = sum / 4.0;
    \\    mat3 t3 = transpose(basis);
    \\    mat2 flipped = -twist;
    \\    vec4 world = vec4(p, 0.0, 1.0);
    \\    world.z += float(lane) * 0.01;
    \\    world.xy *= 1.0 + weight;
    \\    world.w = 1;
    \\    int k = pick(lane, steps) + steps * 2 - 1;
    \\    int wrapped = k % 3;
    \\    bool flag = lane >= 1 || !(weight < 0.5);
    \\    if (wrapped == 2 && flag) {
    \\        world = -world;
    \\    }
    \\    touch(weight);
    \\    uv = corner + corner_bias;
    \\    facing = lit(n + back * t3, sun);
    \\    shade = tint * base;
    \\    depth = float(vertex_index) + float(instance_index) * 0.5;
    \\    position = pv * world + quarter * vec4(0.0);
    \\    position.z = position.z * 0.5 + position.w * 0.5;
    \\}
    \\
    \\fragment {
    \\    vec4 texel = sample(atlas, uv) * shade;
    \\    vec4 fine = sample(detail, uv * 4.0);
    \\    if (texel.a < 0.01) {
    \\        discard;
    \\    }
    \\    float a = abs(depth) + floor(depth) + ceil(depth) + fract(depth);
    \\    float b = sqrt(a) + inversesqrt(a + 1.0) + sin(a) + cos(a) + tan(a * 0.1);
    \\    float c = asin(0.5) + acos(0.5) + atan(a) + atan(a, 2.0) + atan2(a, 3.0);
    \\    float d = exp(a) + log(a + 1.0) + exp2(a) + log2(a + 1.0) + sign(a);
    \\    float e = saturate(a) + mod(a, 2.0) + step(0.5, a) + pow(a, 2.0) + min(a, 1.0) + max(a, 0.0);
    \\    float f = clamp(a, 0.0, 1.0) + mix(a, 1.0, 0.5) + smoothstep(0.0, 1.0, a);
    \\    float g = length(a) + distance(a, b) + dot(a, b) + ddx(a) + ddy(b);
    \\    vec3 n = normalize(facing);
    \\    vec3 v = vec3(a, b, c);
    \\    vec3 w = clamp(v, 0.0, 1.0) + mix(v, n, 0.5) + smoothstep(0.0, 1.0, v);
    \\    w = w + min(v, 1.0) + max(v, vec3(0.1)) + mod(v, 0.7) + step(0.3, v) + pow(v, n);
    \\    w = w + saturate(v) + sign(v) + abs(v) + floor(v) + ceil(v) + fract(v);
    \\    w = w + sqrt(abs(v)) + inversesqrt(v + 2.0) + exp(v) + log(v + 2.0) + exp2(v) + log2(v + 2.0);
    \\    w = w + sin(v) + cos(v) + tan(v * 0.1) + asin(v * 0.1) + acos(v * 0.1) + atan(v) + atan(v, n) + atan2(v, n);
    \\    w = w + reflect(n, v) + cross(v, n) + mix(v, n, v) + clamp(v, vec3(0.0), vec3(1.0));
    \\    float h = length(v) + distance(v, n) + dot(v, n);
    \\    vec2 dd = ddx(uv) + ddy(uv);
    \\    mat2 tw = transpose(twist);
    \\    vec2 rot = tw * dd;
    \\    float lit_amount = lum(w) + rough;
    \\    if (inside(uv)) {
    \\        lit_amount += h;
    \\    }
    \\    target = vec4(w * lit_amount, a + b + c + d + e + f + g) * fine + vec4(rot, uv) + texel;
    \\}
;

/// A vertex stage with five varyings of every width, at non-contiguous
/// attribute locations and block and texture slots with holes in them, and a
/// fragment stage that reads only two of the five. The interface has to come
/// out the same whether a stage reads a thing or not.
pub const many_varyings =
    \\attribute vec2 a_pos : 0;
    \\attribute vec3 a_col : 3;
    \\attribute vec4 a_extra : 5;
    \\
    \\varying float k_one;
    \\varying vec2 k_two;
    \\varying vec3 k_three;
    \\varying vec4 k_four;
    \\varying vec2 k_last;
    \\
    \\uniform Frame : 0 { mat4 projection; }
    \\uniform Tint : 2 { vec4 colour; }
    \\
    \\texture2d first : 0;
    \\texture2d second : 3;
    \\
    \\vertex {
    \\    k_one = a_extra.w;
    \\    k_two = a_pos * 0.5 + 0.5;
    \\    k_three = a_col;
    \\    k_four.xyz = a_col * a_extra.xyz;
    \\    k_four.w = 1.0;
    \\    k_last = k_two + k_four.xy;
    \\    position = projection * vec4(a_pos, k_one, 1.0);
    \\}
    \\
    \\fragment {
    \\    vec4 c = sample(first, k_last) * colour + sample(second, k_two);
    \\    target = c * k_four.a;
    \\}
;

/// Loops of both kinds, nested, an early `discard` in every position it can
/// be in, `else if` chains, and functions that return from inside a loop and
/// from both arms of an `if`. The structured control flow that SPIR-V is
/// strictest about.
pub const loops_and_discard =
    \\varying vec2 uv;
    \\
    \\float march(vec2 p) {
    \\    float acc = 0.0;
    \\    for (int i = 0; i < 8; i += 1) {
    \\        acc += sin(p.x * float(i));
    \\        if (acc > 4.0) {
    \\            return acc;
    \\        }
    \\    }
    \\    int guard = 0;
    \\    while (guard < 3) {
    \\        acc *= 0.5;
    \\        guard += 1;
    \\    }
    \\    return acc;
    \\}
    \\
    \\float sign_of(float x) {
    \\    if (x < 0.0) {
    \\        return -1.0;
    \\    } else {
    \\        return 1.0;
    \\    }
    \\}
    \\
    \\float after_return(float x) {
    \\    return x + 1.0;
    \\    x = 3.0;
    \\}
    \\
    \\vertex {
    \\    uv = vec2(0.5);
    \\    position = vec4(0.0, 0.0, 0.0, 1.0);
    \\}
    \\
    \\fragment {
    \\    float v = march(uv) * sign_of(uv.x) + after_return(uv.y);
    \\    if (v > 100.0) {
    \\        discard;
    \\    }
    \\    for (int i = 0; i < 4; i += 1) {
    \\        if (v < 0.0) {
    \\            discard;
    \\        } else if (v < 1.0) {
    \\            v += 1.0;
    \\        } else {
    \\            v -= 0.5;
    \\        }
    \\        for (int j = 0; j < 2; j += 1) {
    \\            v += 0.1;
    \\            if (v > 50.0) {
    \\                discard;
    \\            }
    \\        }
    \\    }
    \\    while (v > 10.0) {
    \\        v = v * 0.5;
    \\        if (v < 3.0) {
    \\            discard;
    \\        }
    \\    }
    \\    for (int m = 0; m < 3; m += 1) {
    \\        discard;
    \\    }
    \\    {
    \\        float scoped = v * 2.0;
    \\        v = scoped;
    \\    }
    \\    if (v > 2.0) {
    \\        discard;
    \\    }
    \\    target = vec4(v);
    \\}
;

/// Every matrix width in a uniform block with scalars packed between them,
/// which is where `std140` and the constant buffer have to agree with what
/// the emitter decorates: a `float` after a `vec3`, a `mat3` that starts a
/// register, a `vec2` after a matrix.
pub const matrix_block =
    \\attribute vec3 p : 0;
    \\varying vec3 q;
    \\
    \\uniform Frame : 0 {
    \\    float lead;
    \\    mat3 m3;
    \\    float between;
    \\    mat2 m2;
    \\    vec3 v;
    \\    float pinch;
    \\    vec2 w;
    \\    mat4 m4;
    \\    int count;
    \\}
    \\
    \\vertex {
    \\    q = m3 * p + v * pinch + vec3(w, lead + between);
    \\    vec2 r = m2 * w;
    \\    position = m4 * vec4(q, r.x + float(count));
    \\}
    \\
    \\fragment {
    \\    target = vec4(q, 1.0);
    \\}
;

/// `vertex_index` and `instance_index`, and neither: a stage reads them or it
/// does not, and only one of the two makes an input.
pub const index_builtins =
    \\varying float which;
    \\
    \\vertex {
    \\    which = float(vertex_index) * 0.25 + float(instance_index);
    \\    int both = vertex_index + instance_index;
    \\    position = vec4(float(both % 2), float(vertex_index / 2), 0.0, 1.0);
    \\}
    \\
    \\fragment {
    \\    target = vec4(which);
    \\}
;

/// A whole number meeting a float, on both sides of every operator that
/// allows it, and the casts between the scalars.
pub const promotions =
    \\attribute vec3 v3 : 0;
    \\attribute int lane : 1;
    \\varying vec4 out_colour;
    \\uniform Frame : 0 { mat2 twist; float gain; int count; }
    \\
    \\vertex {
    \\    float f = 2.0;
    \\    f = f * lane;
    \\    f = lane * f;
    \\    f += lane;
    \\    f = f - count;
    \\    f = count / f;
    \\    vec3 a = v3 * lane;
    \\    vec3 b = lane * v3;
    \\    vec3 c = v3 / count + v3 - 2;
    \\    vec3 d = 1 + v3;
    \\    mat2 m = twist * lane;
    \\    mat2 n = count * twist;
    \\    mat2 o = twist + 1;
    \\    mat2 p = 2 - twist;
    \\    mat2 q = twist / count;
    \\    float g = lane + 0.5;
    \\    float h = 0.5 - lane;
    \\    int i = lane * 3 - count;
    \\    int j = -i;
    \\    bool t = lane > count;
    \\    bool u = gain >= 0.5;
    \\    bool w = (f != g) && (u == t);
    \\    float k = float(i) + float(t) + float(u);
    \\    int l = int(f) + int(g) + int(t);
    \\    bool z = bool(l) || bool(gain);
    \\    out_colour = vec4(a + b + c + d, f + g + h + k + float(j) + float(l));
    \\    out_colour.xy = m * out_colour.xy + n * out_colour.zw + o * vec2(1.0) + p * vec2(1.0) + q * vec2(1.0);
    \\    if (z || w) {
    \\        out_colour = -out_colour;
    \\    }
    \\    position = out_colour;
    \\}
    \\
    \\fragment {
    \\    target = out_colour;
    \\}
;

/// Assignment to swizzles of every shape, on locals, on a varying, on
/// `position` and on `target`: one component, several, permuted, chained,
/// compound, and both letter sets.
pub const swizzle_assignment =
    \\attribute vec4 a : 0;
    \\varying vec4 v;
    \\varying vec3 v3;
    \\
    \\vertex {
    \\    vec4 t = a;
    \\    t.x = 1.0;
    \\    t.yz = a.zw;
    \\    t.wzyx = a;
    \\    t.zyx.x = 5.0;
    \\    t.rgb *= 2.0;
    \\    t.xy += vec2(0.5, 0.25);
    \\    t.w -= 1;
    \\    t.zw /= vec2(2.0, 4.0);
    \\    t.xyzw = t.wzyx;
    \\    v = t;
    \\    v.zx = t.xz;
    \\    v3.xy = t.xy;
    \\    v3.z = t.w;
    \\    v3 *= v.x;
    \\    position = vec4(1.0);
    \\    position.xyz = v3;
    \\    position.w *= 2.0;
    \\}
    \\
    \\fragment {
    \\    target = vec4(0.0);
    \\    target.rgb = v.xyz + v3;
    \\    target.a += v.w;
    \\    target.gb = target.rg;
    \\}
;

/// The ternary on every type, the logical operators, and constants that are
/// made of other constants, of literals and of a uniform.
pub const selects_and_constants =
    \\attribute vec2 p : 0;
    \\varying vec3 c;
    \\uniform Frame : 0 { mat2 twist; vec3 tint; float t; int n; }
    \\
    \\const float two = 2;
    \\const float minus = -0.5;
    \\const vec3 grey = vec3(0.5);
    \\const vec3 mixed = vec3(two, minus, 1);
    \\const vec4 both = vec4(mixed, 1.0);
    \\const float scaled = t * two;
    \\const int seven = 7;
    \\const bool yes = true;
    \\
    \\vertex {
    \\    bool a = t > 0.0;
    \\    bool b = n < seven;
    \\    bool s = a && b || !a && yes;
    \\    float f = s ? scaled : minus;
    \\    int i = b ? n : seven;
    \\    vec3 v = a ? tint : grey;
    \\    vec2 r = a ? p : -p;
    \\    mat2 m = b ? twist : -twist;
    \\    bool z = a ? b : s;
    \\    c = s ? v * f : mixed * float(i);
    \\    c = c + (z ? both.xyz : vec3(0.0));
    \\    position = vec4(m * r, f, 1.0);
    \\}
    \\
    \\fragment {
    \\    target = vec4(c, 1.0);
    \\}
;

/// A vertex stage that reads a texture. GLSL's `texture` is legal there and
/// means level zero, and so does SPIR-V's lowering (an explicit level); HLSL's
/// `Sample` is a pixel-stage instruction and fxc and dxc refuse it, so this
/// one is a language-level shader the Direct3D text cannot express.
pub const vertex_texture =
    \\attribute vec2 corner : 0;
    \\varying float height;
    \\texture2d heights : 0;
    \\
    \\vertex {
    \\    vec4 h = sample(heights, corner);
    \\    height = h.x;
    \\    position = vec4(corner, h.x, 1.0);
    \\}
    \\
    \\fragment {
    \\    target = vec4(height);
    \\}
;

/// An integer that crosses from one stage to the other. Vulkan wants it
/// `Flat`; the text targets say nothing, which GLSL accepts as an error.
pub const flat_varying =
    \\attribute int id : 0;
    \\varying int which;
    \\varying float shade;
    \\
    \\vertex {
    \\    which = id;
    \\    shade = float(id) * 0.5;
    \\    position = vec4(0.0, 0.0, 0.0, 1.0);
    \\}
    \\
    \\fragment {
    \\    target = vec4(shade, float(which), 0.0, 1.0);
    \\}
;

/// A function that only a fragment stage can run, called from one. The
/// vertex module must not contain it; the text targets put it in both.
pub const derivative_in_a_function =
    \\varying vec2 uv;
    \\
    \\float slope(float x) {
    \\    return ddx(x) + ddy(x);
    \\}
    \\
    \\vertex {
    \\    uv = vec2(0.5);
    \\    position = vec4(uv, 0.0, 1.0);
    \\}
    \\
    \\fragment {
    \\    target = vec4(slope(uv.x));
    \\}
;

/// An attribute that is a whole matrix, which takes four consecutive
/// locations.
pub const matrix_attribute =
    \\attribute vec3 p : 0;
    \\attribute mat4 model : 1;
    \\
    \\vertex {
    \\    position = model * vec4(p, 1.0);
    \\}
    \\
    \\fragment {
    \\    target = vec4(1.0);
    \\}
;

/// Loops that leave only by returning or by discarding: a `for` with no
/// condition, and a `while (true)`. The block after one is unreachable, and
/// what follows it is dropped. The `for` that returns is fine in HLSL; the
/// `while (true)` that only discards is not - `dxc` says "Loop must have
/// break", because a discard is not a way out of a loop in DXIL - so this
/// shader is held to SPIR-V and not to HLSL.
pub const loops_without_a_condition =
    \\varying vec2 uv;
    \\
    \\float first_over(float limit) {
    \\    for (int i = 0; ; i += 1) {
    \\        if (float(i) > limit) {
    \\            return float(i);
    \\        }
    \\    }
    \\    return 0.0;
    \\}
    \\
    \\vertex {
    \\    uv = vec2(0.5);
    \\    position = vec4(uv, 0.0, 1.0);
    \\}
    \\
    \\fragment {
    \\    float v = first_over(uv.x);
    \\    while (true) {
    \\        v += 1.0;
    \\        if (v > 10.0) {
    \\            discard;
    \\        }
    \\    }
    \\    target = vec4(v);
    \\}
;
