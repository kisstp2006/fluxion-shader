# Fluxion Shader

One shader, in the language of whichever backend asks. For Zig 0.16.

| Module | What it is |
| --- | --- |
| `lex` | Source text into tokens, over [Fluxion Text](https://github.com/kisstp2006/fluxion-text)'s cursor. |
| `parse` | Tokens into a tree. Recursive descent, one token of lookahead, and it stops at the first thing it cannot read. |
| `sema` | What the tree means: every name resolved, every expression typed, every call matched. Reports as many mistakes as it finds, not just the first. |
| `builtins` | The functions the language brings with it, as one table: name, arity, typing, and how each target spells or lowers it. |
| `target` | What the tree can be written out as, as a table: name, family, text or words, and the function that writes it. |
| `glsl` | The tree as GLSL 3.30 core, and as GLSL ES 3.00 for WebGL 2. |
| `hlsl` | The tree as HLSL for shader model 5.0. |
| `spirv` | The tree as SPIR-V 1.0 for Vulkan 1.0: one module per stage, as `[]const u32`. |
| `Module` | What comes out: what every target wrote, and the numbers a pipeline is described with. |
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
    .glsl_es = .{ .vertex = module.glsl_es.vertex, .fragment = module.glsl_es.fragment },
    .hlsl = .{ .vertex = module.hlsl.vertex, .fragment = module.hlsl.fragment },
    .spirv = .{ .vertex = module.spirv.vertex, .fragment = module.spirv.fragment },
});
```

The one shader, handed over whole: whichever backend the device is -
OpenGL, WebGL, Direct3D 11 or 12, Vulkan - it takes the language it draws
with, and nothing in the program asks which one it is on.

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

Five decisions run through it:

**It is a compiler, not a translator.** The source is lexed, parsed, checked
and emitted. A mistake is a message with a line and a column on it, in the
language the author actually wrote — not something a driver says later about
text nobody typed.

**One tree, as many backs as there are rows.** The same checked tree is
written out as GLSL, as GLSL ES, as HLSL and as SPIR-V, and the types on it
are what decide the difference: `a * b` on two floats is `*` in every one of
them, and on a matrix and a vector it is `*` in GLSL, `mul` in HLSL and
`OpMatrixTimesVector` in SPIR-V. Nothing is textually substituted. The two
GLSLs differ only in their first lines - `#version 300 es`, and the
precisions ES leaves undeclared - and a test holds the rest of the two to
being the same text, byte for byte.

**Everything that varies is a row in a table.** What an output is, is a row of
[`target`](#targets). What a builtin is called in each of them is a row of
[`builtins`](#the-functions-it-brings). Adding an output or a builtin is
adding a row, not finding the `switch` in five files that has to learn about
it.

**The bindings are written once.** A location, a slot, a block name, a
texture name and the byte offset of every uniform field are in the shader, and
`Module` hands them back. `uniformBlockNames` and `textureNames` are the two
lists a `PipelineDesc` wants, in slot order, so the pipeline is described out
of the shader rather than beside it. The SPIR-V descriptors are a function of
the same slots, and nothing else.

**What the targets do not agree on is left out.** No arrays, no structs,
no integer vectors, no matrix literals, no `frag_coord`. Each of those is a
place where the languages differ in a way this library cannot hide, and a
library that emitted all of them from one description would be promising
something it could not keep. [What is not here](#what-is-not-here) names each
one and why.

Nothing here allocates except through the allocator handed to `compile`,
and nothing here talks to a driver.

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
| `attribute vec2 corner : 0;` | A vertex input at location 0. `layout(location = 0)` there, `ATTR0` in HLSL, `Location 0` in SPIR-V. |
| `varying vec2 uv;` | Written by the vertex stage, read by the fragment stage. |
| `uniform Frame : 0 { mat4 projection; }` | A uniform block at slot 0. Its fields are in scope by name, as they are in every target. |
| `uniform Look : 1 { float strength = 0.5; }` | A field with a first value, written in numbers: a number, a negated one, or a vector made of them (`vec4(1.0)`). Not emitted - a block has nowhere to keep it - but handed back as `Field.default`, for the program filling the buffer to start from. |
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
once it is known to mean the same thing everywhere. It is one table,
`builtins.table`, with a row per function:

```zig
r(.atan, .{
    .args = .{ 1, 2 },                 // how many arguments, as a range
    .typing = .uniform_width,          // how their types decide the result
    .hlsl = .{ .call_by_arity = .{ .one = "atan", .two = "atan2" } },
    .spirv = .{ .lower = .{ .ext_by_arity = .{ .one = .atan, .two = .atan2 } } },
}),
```

`sema` reads the arity and the typing, each text emitter reads its own
column - a name, a name that depends on how many arguments there are, or a
template with `{0}` and `{1}` where the arguments go - and the SPIR-V emitter
reads an extended-instruction number or a core opcode, and whether scalar
operands are widened to the vector they sit among. Where every target spells
it the same, the row says nothing about it. A `comptime` check fails the build
when a builtin has no row, so adding one is adding a tag to `ast.Builtin` and
a line to the table.

Where the spelling differs the emitter deals with it, and where the *meaning*
differs it is written out:

| This language | GLSL | HLSL | SPIR-V |
| --- | --- | --- | --- |
| `sample(t, uv)` | `texture(t, uv)` | `t.Sample(t_sampler, uv)` | `OpImageSampleImplicitLod`, and level 0 in the vertex stage |
| `fract`, `mix`, `inversesqrt` | the same | `frac`, `lerp`, `rsqrt` | `Fract`, `FMix`, `InverseSqrt` |
| `saturate(x)` | `clamp(x, 0.0, 1.0)` | the same | `FClamp(x, 0, 1)` |
| `ddx`, `ddy` | `dFdx`, `dFdy` | the same | `OpDPdx`, `OpDPdy` |
| `atan2(y, x)` | `atan(y, x)` | the same | `Atan2` |
| `mod(a, b)` | the same | `a - b * floor(a / b)` | `a - b * floor(a / b)` |
| `m * v` | the same | `mul(m, v)` | `OpMatrixTimesVector` |
| `vec4(x)` for one scalar `x` | the same | `((float4)(x))` | `OpCompositeConstruct`, or one constant |

The `mod` and `*` rows are the ones that would be wrong rather than merely
misspelled. HLSL's `fmod` takes the sign of the numerator and GLSL's `mod`
does not (SPIR-V's `FRem` is HLSL's), so what comes out is GLSL's definition
written down, in every target that has a choice. HLSL has no `*` that means a matrix product. And `float4(x)` with one
scalar is `error X3014` in HLSL, where GLSL fills the vector — so a cast goes
out instead, which is the spelling that broadcasts.

## Targets

`compile` writes every target here - so a shader that one of them cannot
express is refused at once, rather than on the one machine that draws with
it. `compileWith` writes whichever you ask for, and `Module.output` hands
back what each wrote:

```zig
var module = try shader.compileWith(gpa, source, &log.writer, .{
    .targets = .of(&.{ .glsl_330, .spirv_vulkan }),
});
defer module.deinit();

const spv = module.output(.spirv_vulkan).words;   // .vertex, .fragment: []const u32
const bytes = spv.vertexBytes();                   // []align(4) const u8, for vkCreateShaderModule
```

| Target | Family | Output | Is |
| --- | --- | --- | --- |
| `glsl_330` | `glsl` | text | GLSL 3.30 core, for desktop OpenGL. `module.glsl`. |
| `glsl_es_300` | `glsl` | text | GLSL ES 3.00, for WebGL 2. `module.glsl_es`. |
| `hlsl_50` | `hlsl` | text | HLSL for shader model 5.0, for Direct3D 11 - and the text the Direct3D 12 toolchain compiles. `module.hlsl`. |
| `spirv_vulkan` | `spirv` | words | SPIR-V 1.0 for Vulkan 1.0. `module.spirv`. |

`module.glsl`, `module.glsl_es`, `module.hlsl` and `module.spirv` are four of
the rows of `module.output`, kept as fields because every caller wants them.
`target.Set.every` is all of them and the default; `text_targets` is the
three text ones. A target that was not asked for leaves its field empty and
its output `.none`.
The reflection - `attributes`, `blocks`, `textures` - is the same whichever
targets ran.

### Adding a target

A target is a row, `{ name, family, emit }`, where `emit` is either a text
function (`fn (*const ast.Program, sema.Where, *std.Io.Writer) !void`, one
stage to a writer) or a words function (`fn (Allocator, *target.Request)
![]u32`, one stage as binary). The table a program gives the compiler is
`builtin_targets` and anything it puts after them, built at compile time
without editing this library:

```zig
const table = shader.target.builtin_targets ++ [_]shader.Target{
    .{ .name = "glsl_450", .family = .glsl, .emit = .{ .text = emitGlsl450 } },
};
const glsl_450 = shader.target.idOf(&table, "glsl_450");

var module = try shader.compileWith(gpa, source, &log.writer, .{
    .table = &table,
    .targets = .of(&.{ .glsl_330, glsl_450 }),
});
const written = module.output(glsl_450).text;   // .vertex, .fragment
```

The `family` is what the new row shares with the rows around it, and it is
how the builtin table knows what to give it: a `glsl_450` row reads the `glsl`
column of every builtin. A target in a language none of the families is
needs one more column in `builtins.table` and one more `Family` - and that,
and its row, is all it needs. A words emitter that cannot express a shader
returns `error.Unsupported` and says why in `Request.reason`; the compile
fails with that line in the log, as a mistake in the source would.

## SPIR-V

One module per stage, from the same checked tree the text targets read.

**The environment is Vulkan 1.0.** SPIR-V 1.0, capability `Shader`,
addressing `Logical`, memory model `GLSL450`, one entry point named `main`,
execution model `Vertex` or `Fragment`, and `OriginUpperLeft` on a fragment
stage. Nothing that needs a later version, and no extension. The words are in
memory as `u32`s, which on every machine this runs on is little-endian and
four-aligned, so `words.vertexBytes()` goes straight to
`vkCreateShaderModule`.

### The interface

| This language | SPIR-V |
| --- | --- |
| `attribute t x : n` | an `Input` variable, `Location n` |
| `varying t x` | an `Output` in the vertex module and an `Input` in the fragment module, `Location` = its position in the declaration list, from 0 |
| `position` | an `Output` `vec4`, `BuiltIn Position` |
| `target` | an `Output` `vec4`, `Location 0` |
| `vertex_index`, `instance_index` | an `Input` `int`, `BuiltIn VertexIndex`, `InstanceIndex` |
| `discard` | `OpKill` |

Varyings are matched by position, and both modules declare every one whether
or not the stage reads it, so the interface is a property of the shader and not
of what a stage happens to touch. An `int` varying is `Flat`, which Vulkan
requires.

**`vertex_index` is Vulkan's.** `BuiltIn VertexIndex` includes the draw's first
vertex: it is the index into the vertex buffer, which is what the RHI's `draw`
gives it, and not the index of the vertex within the draw.

**Clip space is not touched.** `position` is written as it is. Vulkan's y
points down and its depth is `[0, 1]`; making an OpenGL projection into that
is the projection's job, or a negative-height viewport's.

### Resources

**A descriptor set per kind of resource, and binding = slot.**

| | Set | Binding | Storage class |
| --- | --- | --- | --- |
| `uniform Frame : n { … }` | 0 | `n` | `Uniform`, the struct decorated `Block` |
| `texture2d atlas : n;` | 1 | `n` | `UniformConstant`, a combined image sampler (`OpTypeSampledImage` over a 2D float image) |

That matches the RHI, which has two slot spaces (`setUniformBuffer(slot)` and
`setTexture(slot)`), needs no magic base numbers, and keeps the binding of a
resource a pure function of what it is and its slot. The two set numbers are
`Options.binding`, a `BindingLayout` with those defaults, and `Module.binding`
hands back the ones a module was written with. Every block and texture is in
both modules, used or not, so one pipeline layout serves both stages.

**A block's layout is the one `Module.Block` says.** Every member is `Offset`ed
at its `byte_offset`, a matrix is `ColMajor` with `MatrixStride 16`, and that is
`std140`. A test reads the decorations back out of the words and holds them to
the module's offsets for every block of every shader it compiles.

### What it lowers to

Locals are `Function` variables at the top of the entry block. `if` is
`OpSelectionMerge`, a loop is `OpLoopMerge`, a ternary is `OpSelect` (with its
condition spread over a vector, and a matrix taken a column at a time, because
SPIR-V 1.0 wants that), and a return or a discard ends its block with whatever
follows it dropped. Arithmetic on a matrix that SPIR-V has no instruction for
- `+`, `-`, `/`, negation, and a scalar against a matrix - is done a column at
a time. The one implicit conversion the language has, a whole number meeting a
float, is an `OpConvertSToF`, or a constant when it can be.

A function is written into a module only if that stage reaches it. SPIR-V has no
recursion, so a shader that has some is refused by this target, with a line in
the log saying so (GLSL and HLSL have none either, and `sema` does not check);
so is a derivative in the vertex stage, which does not exist there.

Types and constants are written once. Ids come from one counter and `Bound` is
one past the last. `Options.debug_names` adds `OpName` for every variable,
function and member, and is off by default.

## What is not here

Each of these is left out for the same reason, and each would come back the
moment there is one answer rather than several. **The language does not grow in
this step**; the ones that are next are marked.

| Missing | Because |
| --- | --- |
| Arrays and structs (next) | In a uniform block, `std140` gives an array a sixteen-byte stride and a Direct3D constant buffer starts every element on a register too but lets the member after it pack into the last one; a struct is rounded to sixteen in one and not in the other. The block layout is already where the two part ways - see [the block layout](#the-block-layout) - and `packoffset` is how they are made to agree. |
| Integer vectors (next) | Nothing needs them yet, and every one is another set of conversion rules to get right in four targets. |
| Cube and 3D samplers (next) | One `texture2d` is the one image type; each is another `OpTypeImage` and another method in HLSL. |
| A compute stage (next) | The RHI has no compute pass yet either. When it does. |
| `frag_coord` (next) | Its origin is the bottom left in OpenGL and the top left everywhere else, and correcting it needs the viewport height, which a shader cannot invent. |
| Matrix literals | `mat4(a, b, c, d)` builds from columns in GLSL and from rows in HLSL, and `mat4(x)` is a diagonal in one and a splat in the other. Matrices arrive in a uniform block, where they agree. |
| `==` on vectors | GLSL returns one `bool` and HLSL returns a vector of them. Compare the components you mean. |
| `%` on floats | `mod` is the one for those. `%` is whole numbers. |
| DXBC and DXIL as targets | They are a row of `target` when someone writes the emitter. Until then the HLSL is what `d3dcompiler` and `dxc` take. |

## What comes out

`Module` holds what every target wrote and what a program has to know to bind
it:

```zig
module.glsl.vertex     // and .fragment - OpenGL 3.3
module.glsl_es.vertex  // and .fragment - WebGL 2
module.hlsl.vertex     // and .fragment - Direct3D 11
module.output(.spirv_vulkan).words.vertex   // Vulkan, when asked for

module.attributes      // name, type, location
module.blocks          // name, slot, size, and every field's byte offset
module.textures        // name, slot
module.binding         // the descriptor sets SPIR-V was written with

try module.uniformBlockNames()   // the names in slot order, for PipelineDesc
try module.textureNames()
```

### The block layout

`block.offsetOf("time")` is the byte offset of a field under `std140`: a value
is aligned to its own size up to sixteen bytes (a `vec3` occupies twelve and
starts on sixteen), a `float` after a `vec3` packs into the four bytes that follow
it, a matrix is a register per column, and the block is rounded up to sixteen.
That is what OpenGL, WebGL and Vulkan use - the SPIR-V is decorated with exactly
these numbers - and a program can check it against the struct it uploads:

```zig
try testing.expectEqual(@as(?u32, @offsetOf(Frame, "time")), frame.offsetOf("time"));
```

**A Direct3D constant buffer is not `std140` on its own.** It puts a member at
the next four bytes where it does not cross a sixteen-byte register, and it
gives a matrix a register per column but leaves the rest of the last one free:
left to itself it would put `b` of `{ float a; vec3 b; }` at 4, where `std140`
says 16. So the HLSL this library writes says where every member is -
`float3 direction : packoffset(c0.x);` - with `std140`'s offset, and `offsetOf`
is the same number on every backend.

## What it refuses

Beyond the types not adding up, three checks exist because of what happens
without them:

- **A texture or a block nothing reads.** The driver removes it, and the
  binding a program then asks for by name is not there — a failure at pipeline
  creation, a long way from the line that caused it.
- **A varying the vertex stage never writes.** The fragment stage would read
  whatever was in the register.
- **A name the emitter uses, or one either language reserves.** `input`,
  `sample`, `linear`, `highp`, HLSL's primitive words - `line`, `point`,
  `triangle` - anything starting `gl_` or `fluxion`.

And two that SPIR-V needed the checker to say, because nothing else could
lower them: `<` and its kin are for numbers and not bools, and a whole number
against a float is a float, whichever side it is on (it used to be typed as the
left operand, so `lane * 0.5` was an `int`).

## Validation

There is no GPU work in what this library does, so what it writes is only as
trustworthy as what reads it. The tests ask the readers that exist, when they
are installed - the Vulkan SDK's `spirv-val`, `spirv-cross` and `dxc`, found on
`PATH`, in `%VULKAN_SDK%\Bin`, or in the SDK's default directory - and report
**skipped**, visibly, when they are not:

| Question | Asked of | About |
| --- | --- | --- |
| Is it valid for Vulkan 1.0? | `spirv-val --target-env vulkan1.0` | both modules of every shader |
| Can a second reader read it? | `spirv-cross` to Vulkan GLSL, HLSL and MSL | both modules of every shader |
| Is the text a valid input for the Direct3D 12 toolchain? | `dxc -T vs_6_0` / `ps_6_0`, and `-T vs_5_1` / `ps_5_1` | the HLSL of both stages of every shader; entry point `main` |

Every shader the library's own tests compile is asked all three, once, and so are
the ones in `src/corpus.zig`, which exist to be validated: every type and every
builtin, five varyings of every width, loops and an early `discard` in every
position, `mat2` and `mat3` in a block, both index builtins, whole numbers
meeting floats, swizzled assignment, and the ternary on every type. Without the
tools the structural checks still run - the header, that every instruction's
length lands on the end of the stream, that every id is under `Bound`, defined
once and never used undefined, that the sections are in the specification's
order, that each block of each function ends in one terminator - and so do the
decorations read back out of the words and held to `Module.Block`.

Two things `dxc` says that are worth knowing. `-T vs_5_1` is accepted with a
warning that dxc *promoted* it to 6.0, so it is the same compile again and not a
shader model 5.1 one; and HLSL is stricter than the language in two places (a
texture sampled in the vertex stage, and a loop that only leaves by
discarding), which `corpus.zig` marks and holds to SPIR-V instead.

## Known gaps

Found by asking the readers above rather than by reading the code, and not
changed here, because the text the existing emitters write is pinned:

- An `int` varying is not `flat` in GLSL, and GLSL says it must be. (SPIR-V's
  is.)
- GLSL ES 3.00 has no implicit conversion from `int`, and the text emitters leave
  one in wherever a whole number is used against a float in arithmetic:
  `x * 2`, `x * lane` and `t -= 1` are written as they are, which GLSL 3.30 takes
  and WebGL 2 does not.
- `const` in GLSL has to be a constant expression, and the language lets one read
  a uniform.
- `ddx` and `ddy` are accepted in the vertex stage, and in a function that is
  emitted into both.
- A function may take a `texture2d`, and HLSL has nowhere to put its sampler.
  SPIR-V refuses it.

## Examples

| Example | What it shows |
| --- | --- |
| `zig build example` | One source, all three text languages, and the reflection printed underneath. No window, no driver, no graphics card. `-- --stage fragment` prints the other stage; `-- --refuse` shows what three mistakes look like on the way out. |
| `zig build example-spirv` | The same shader as SPIR-V, written to `zig-out/demo.vert.spv` and `zig-out/demo.frag.spv`, with the descriptor each resource became. `-- --stage fragment` writes one stage. Read it with `spirv-dis zig-out/demo.frag.spv`. |
| `zig build example-quad` | The compiled shader given to a real driver, through Fluxion RHI, with the pipeline described out of the module's own reflection. `-- --backend gl` or `d3d11`; `-- --capture out.png` draws one frame to a file. |

The last one carries the test that matters for the text targets. Everything the
library's own suite checks is what the emitted *text* says; whether a driver will
take it is a question only a driver answers. So `examples/quad.zig` asks both —
the HLSL through `d3dcompiler_47` and the GLSL through a real OpenGL context —
draws the same shader on each, and compares the two pictures. On a machine with
no display or no graphics card those skip rather than fail, and the rest of the
suite still runs.

That test found two real bugs on its first run, which is the argument for
having it: `float4(1.0)` does not compile in HLSL, and a projection matrix
that looks right is not.

## Build

```bash
zig build test                  # run the test suite (and the validators, if installed)
zig build example               # one source, three languages, printed
zig build example-spirv         # the same shader as SPIR-V, in zig-out/
zig build example-quad          # the same shader, drawn on a real driver
zig build example-quad -- --backend gl
zig build examples              # every example in turn
zig build docs                  # generate API docs into zig-out/docs
```

## Licence

`BSL-1.0`. See [LICENSE](LICENSE).
