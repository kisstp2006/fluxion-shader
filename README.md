# Fluxion Shader

One shader, in the language of whichever backend asks. For Zig 0.16.

| Module | What it is |
| --- | --- |
| `lex` | Source text into tokens, over [Fluxion Text](https://github.com/kisstp2006/fluxion-text)'s cursor. |
| `parse` | Tokens into a tree. Recursive descent, one token of lookahead, and it stops at the first thing it cannot read. |
| `sema` | What the tree means: every name resolved, every expression typed, every call matched. Reports as many mistakes as it finds, not just the first. |
| `glsl` | The tree as GLSL 3.30 core. |
| `hlsl` | The tree as HLSL for shader model 5.0. |
| `Module` | What comes out: four sources, and the numbers a pipeline is described with. |
| `diag` | Where a complaint goes, with the line under it and a caret at the column. |

```zig
const shader = @import("fluxion_shader");

var log: std.Io.Writer.Allocating = .init(gpa);
defer log.deinit();

var module = shader.compile(gpa, source, &log.writer) catch {
    std.debug.print("{s}\n", .{log.written()});
    return error.ShaderFailed;
};
defer module.deinit();

const handle = try device.createShader(.{
    .glsl = .{ .vertex = module.glsl.vertex, .fragment = module.glsl.fragment },
    .hlsl = .{ .vertex = module.hlsl.vertex, .fragment = module.hlsl.fragment },
});
```

And the source it read:

```
attribute vec2 corner : 0;

varying vec2 uv;

uniform Frame : 0 {
    mat4 projection;
}

texture2d atlas : 0;

vertex {
    uv = corner;
    position = projection * vec4(corner, 0.0, 1.0);
}

fragment {
    target = sample(atlas, uv);
}
```

Four decisions run through it:

**It is a compiler, not a translator.** The source is lexed, parsed, checked
and emitted. A mistake is a message with a line and a column on it, in the
language the author actually wrote — not something a driver says later about
text nobody typed.

**One tree, two backs.** The same checked tree is written out twice, and the
types on it are what decide the difference: `a * b` on two floats is `*` in
both languages, and on a matrix and a vector it is `*` in GLSL and `mul` in
HLSL. Nothing is textually substituted.

**The bindings are written once.** A location, a slot, a block name, a
texture name and the byte offset of every uniform field are in the shader, and
`Module` hands them back. `uniformBlockNames` and `textureNames` are the two
lists a `PipelineDesc` wants, in slot order, so the pipeline is described out
of the shader rather than beside it.

**What both languages do not agree on is left out.** No arrays, no structs,
no integer vectors, no matrix literals, no `frag_coord`. Each of those is a
place where GLSL and HLSL differ in a way this library cannot hide, and a
library that emitted both from one description would be promising something it
could not keep. [What is not here](#what-is-not-here) names each one and why.

Nothing here allocates except through the allocator handed to `compile`, and
nothing here talks to a driver.

## Install

```bash
zig fetch --save git+https://github.com/kisstp2006/fluxion-shader
```

Or, for a checkout next to your project, add to `build.zig.zon`:

```zig
.dependencies = .{
    .fluxion_shader = .{ .path = "../fluxion-shader" },
},
```

Either way, wire it up in `build.zig`:

```zig
const fluxion = b.dependency("fluxion_shader", .{
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("fluxion_shader", fluxion.module("fluxion_shader"));
```

One dependency comes with it, fetched the same way and needing nothing from
you: [Fluxion Text](https://github.com/kisstp2006/fluxion-text), whose
`Parser` the lexer reads with and whose `locationAt` puts a line and a column
on every message.

Three more are named in `build.zig.zon` and are *not* fetched for you:
[Fluxion RHI](https://github.com/kisstp2006/fluxion-rhi) is what the examples
draw the compiled shader with, and
[Fluxion Platform](https://github.com/kisstp2006/fluxion-platform) and
[Fluxion Image](https://github.com/kisstp2006/fluxion-image) are the window
and the PNG they need. All three are `lazy`, asked for only when this is the
package being built. Pass `-Dexamples=false` to skip them in a checkout of
this repository too.

## The language

Familiar on purpose. It is GLSL's syntax with the parts that do not survive
the crossing taken out, and the stage boundaries made explicit.

### Declarations

| Written | Means |
| --- | --- |
| `attribute vec2 corner : 0;` | A vertex input at location 0. `layout(location = 0)` there, `ATTR0` here. |
| `varying vec2 uv;` | Written by the vertex stage, read by the fragment stage. |
| `uniform Frame : 0 { mat4 projection; }` | A uniform block at slot 0. Its fields are in scope by name, as they are in both languages. |
| `texture2d atlas : 0;` | A texture at slot 0, and the sampler that goes with it. |
| `const float pi = 3.14159;` | A compile-time constant. |
| `vec2 scale(vec2 v, float s) { … }` | A function. |
| `vertex { … }` / `fragment { … }` | The two stages. One of each, and both are required. |

### Types

`float`, `int`, `bool`, `vec2`, `vec3`, `vec4`, `mat2`, `mat3`, `mat4`,
`texture2d`. Swizzles are `xyzw` or `rgba`, up to four components, and the two
sets may not be mixed.

`int` is there for loop counters. A whole number written where a float belongs
becomes one — `vec4(1, 0, 0, 1)` comes out as `vec4(1.0, 0.0, 0.0, 1.0)` —
and everything else needs `float(x)`.

### What each stage has

| | vertex | fragment |
| --- | --- | --- |
| attributes | read | — |
| varyings | write | read |
| uniforms, textures, constants | read | read |
| `position` | write, and it must | — |
| `target` | — | write, and it must |
| `vertex_index`, `instance_index` | read | — |
| `discard` | — | yes |

**A function may touch neither stage.** Parameters, locals, constants, uniform
fields and textures, and nothing else. That is not tidiness: every function is
emitted into both the vertex and the fragment source, and one that read an
attribute could not be.

### The functions it brings

`sample`, `abs`, `floor`, `ceil`, `fract`, `sqrt`, `inversesqrt`, `sin`,
`cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `exp`, `log`, `exp2`, `log2`,
`sign`, `normalize`, `saturate`, `ddx`, `ddy`, `min`, `max`, `pow`, `mod`,
`step`, `reflect`, `clamp`, `mix`, `smoothstep`, `length`, `distance`, `dot`,
`cross`, `transpose`.

A list rather than "whatever the driver has", because a name is only in it
once it is known to mean the same thing on both sides. Where the spelling
differs the emitter deals with it, and where the *meaning* differs it is
written out:

| This language | GLSL | HLSL |
| --- | --- | --- |
| `sample(t, uv)` | `texture(t, uv)` | `t.Sample(t_sampler, uv)` |
| `fract`, `mix`, `inversesqrt` | the same | `frac`, `lerp`, `rsqrt` |
| `saturate(x)` | `clamp(x, 0.0, 1.0)` | the same |
| `ddx`, `ddy` | `dFdx`, `dFdy` | the same |
| `atan2(y, x)` | `atan(y, x)` | the same |
| `mod(a, b)` | the same | `a - b * floor(a / b)` |
| `m * v` | the same | `mul(m, v)` |
| `vec4(x)` for one scalar `x` | the same | `((float4)(x))` |

The last three are the ones that would be wrong rather than merely
misspelled. HLSL's `fmod` takes the sign of the numerator and GLSL's `mod`
does not, so what comes out there is GLSL's definition written down. HLSL has
no `*` that means a matrix product. And `float4(x)` with one scalar is
`error X3014` in HLSL, where GLSL fills the vector — so a cast goes out
instead, which is the spelling that broadcasts.

## What is not here

Each of these is left out for the same reason, and each would come back the
moment there is one answer rather than two:

| Missing | Because |
| --- | --- |
| Matrix literals | `mat4(a, b, c, d)` builds from columns in GLSL and from rows in HLSL, and `mat4(x)` is a diagonal in one and a splat in the other. Matrices arrive in a uniform block, where both agree. |
| Arrays and structs | In a uniform block, `std140` gives an array a sixteen-byte stride and a constant buffer does something else. Outside one they would be fine, and they can be added when the block rules are dealt with. |
| `==` on vectors | GLSL returns one `bool` and HLSL returns a vector of them. Compare the components you mean. |
| `frag_coord` | Its origin is the bottom left in OpenGL and the top left everywhere else, and correcting it needs the viewport height, which a shader cannot invent. |
| Integer vectors | Nothing needs them yet, and every one is another set of conversion rules to get right in two languages. |
| A compute stage | The RHI has no compute pass yet either. When it does. |
| `%` on floats | `mod` is the one for those. `%` is whole numbers. |

## What comes out

`Module` holds four sources and what a program has to know to bind them:

```zig
module.glsl.vertex     // and .fragment
module.hlsl.vertex     // and .fragment

module.attributes      // name, type, location
module.blocks          // name, slot, size, and every field's byte offset
module.textures        // name, slot

try module.uniformBlockNames()   // the names in slot order, for PipelineDesc
try module.textureNames()
```

The block layout is worth a word. Everything this language can put in a
uniform block has the same offset under `std140` and in a Direct3D constant
buffer: a value is aligned to its own size up to sixteen bytes, a `vec3`
occupies twelve and starts on sixteen, a `float` after one packs into the four
bytes that follow it, and the block is rounded up to sixteen. They agree
because arrays and nested structs — the two places they do not — are not in
the language. So `block.offsetOf("time")` is one number, true on both
backends, and a program can check it against the struct it uploads:

```zig
try testing.expectEqual(@as(?u32, @offsetOf(Frame, "time")), frame.offsetOf("time"));
```

## What it refuses

Beyond the types not adding up, three checks exist because of what happens
without them:

- **A texture or a block nothing reads.** The driver removes it, and the
  binding a program then asks for by name is not there — a failure at pipeline
  creation, a long way from the line that caused it.
- **A varying the vertex stage never writes.** The fragment stage would read
  whatever was in the register.
- **A name the emitter uses, or one either language reserves.** `input`,
  `sample`, `linear`, anything starting `gl_` or `fluxion`.

## Examples

| Example | What it shows |
| --- | --- |
| `zig build example` | One source, both languages, and the reflection printed underneath. No window, no driver, no graphics card. `-- --stage fragment` prints the other stage; `-- --refuse` shows what three mistakes look like on the way out. |
| `zig build example-quad` | The compiled shader given to a real driver, through Fluxion RHI, with the pipeline described out of the module's own reflection. `-- --backend gl` or `d3d11`; `-- --capture out.png` draws one frame to a file. |

The second one carries the test that matters. Everything the library's own
suite checks is what the emitted *text* says; whether a driver will take it is
a question only a driver answers. So `examples/quad.zig` asks both — the HLSL
through `d3dcompiler_47` and the GLSL through a real OpenGL context — draws
the same shader on each, and compares the two pictures. On a machine with no
display or no graphics card those skip rather than fail, and the rest of the
suite still runs.

That test found two real bugs on its first run, which is the argument for
having it: `float4(1.0)` does not compile in HLSL, and a projection matrix
that looks right is not.

## Build

```bash
zig build test                  # run the test suite
zig build example               # one source, two languages, printed
zig build example-quad          # the same shader, drawn on a real driver
zig build example-quad -- --backend gl
zig build examples              # every example in turn
zig build docs                  # generate API docs into zig-out/docs
```

## Licence

`BSL-1.0`. See [LICENSE](LICENSE).
