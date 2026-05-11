# MaiaKoda Programming Language: Technical Overview

Document Information

Property Value
- Version 0.0.2
- Status Pre-alpha
- Date 2026-05-02
- Copyright © 2026 Purging Light Technologies
- License MIT

---

Part 1: What is MaiaKoda?

MaiaKoda is a dual-nature programming language ecosystem designed to unify systems programming and scripting under a single, coherent syntax.

```toml
# core_facts.toml
languages = ["Maia", "Koda"]
maia_type = "compiled_systems_language"
koda_type = "interpreted_scripting_language"
core_principle = "One syntax, two execution models"
```

Unlike traditional approaches that force developers to use C for kernels, Python for scripting, and Bash for shells — MaiaKoda replaces this fragmented toolchain with a single ecosystem.

---

Part 2: The Two Natures

2.1 Maia — The System Language

Maia is a compiled systems language for bare-metal and performance-critical code.

Key Characteristics:

Property Value
- Compilation Ahead-of-time (AOT) to native code
- Memory Management No GC — compile-time reference counting + ownership
- Concurrency Actors + channels + Pony-style reference capabilities
- Safety Borrow checker + reference capabilities + explicit allocators
- Backends x86_64, ARM64, RISC-V, WebAssembly

What you can build with Maia:

· Operating system kernels
· Device drivers
· Embedded firmware
· Game engines
· Real-time systems
· Performance-critical services

2.2 Koda — The Scripting Language

Koda is an interpreted scripting language that runs everywhere Maia runs.

Key Characteristics:

Property Value
- Execution Bytecode VM (implemented in Maia)
- Memory Management Reference counting
- Concurrency Async/await + task spawning
- Typing Dynamic with optional static (gradual typing)
- Primary Uses Embedded scripting, shell, build automation, web

What you can build with Koda:

· Embedded configuration scripts
· Interactive shells (pssh)
· Build systems
· Web applications (first-class web framework)
· Documentation readers (doobie)
· Modal editors (loki)

---

Part 3: Unified Syntax

Both Maia and Koda share the same Pascal-style syntax. If you know one, you know the other.

```pascal
/* This is valid Maia AND Koda */
module Example

function add(a: int32, b: int32): int32
begin
    return a + b
end

procedure main()
begin
    var sum := add(5, 3)
    writeln("Sum: ", sum)
end
```

Syntax Highlights:

Feature Syntax
- Blocks begin ... end
- Comments /* ... */ (regular), /// ... (documentation)
- Variables var name: type = value
- Constants const name: type = value
- Functions function name(params): return_type
- Procedures procedure name(params)
- If statement if condition then ... elsif ... else ... end
- Loops for i in 0..9 do ... end
- Match match value { pattern => block }

---

Part 4: Memory Management (Maia)

Maia provides three complementary memory management strategies — you choose what fits your use case.

4.1 Ownership System (Rust-style)

```pascal
var a: own string := "hello"   /* unique owner */
var b: ref string := &a         /* immutable borrow */
var c: mut string := &mut a     /* mutable borrow */
var d: own string := consume a   /* move — 'a' is now dead */
```

4.2 Compile-Time Reference Counting (Unique to Maia)

```pascal
var a: rc string := "shared"    /* refcount = 1 at compile time */
var b: rc string := a           /* refcount = 2 — static, no runtime op */
var c: rc string := a           /* refcount = 3 — static, no runtime op */
/* No runtime reference counting operations — eliminated at compile time */
```

4.3 Explicit Allocators (Zig-style)

```pascal
var arena := Arena.init(allocator)
var data := arena.alloc(u8, 4096)  /* all allocations from arena */
defer arena.deinit()                /* all memory freed at once */
```

4.4 Reference Capabilities (Pony-style)

Capability Mutable Shareable Sendable Use Case
iso ✅ ❌ ✅ Unique ownership across actors
val ❌ ✅ ✅ Immutable shared data
tag ❌ ✅ ✅ Actor reference (messages only)
ref ✅ ✅ ❌ Local mutable (single thread)
box ❌ ✅ ✅ Read-only view

---

Part 5: Concurrency

5.1 Maia Actors

```pascal
actor Counter {
    var _count: iso int32 := 0
    
    behavior increment()
    begin
        _count += 1
    end
    
    function get(): val int32
    begin
        return _count as val
    end
}

procedure main()
begin
    var counter: tag Counter := Counter.create()
    spawn counter.increment()
    spawn counter.increment()
    wait()
    writeln(counter.get())  /* 2 — no data races */
end
```

5.2 Koda Async/Await

```koda
async function fetch_data(url: string): string
begin
    var response := await http.get(url)
    return response.body
end

async procedure main()
begin
    var tasks := array(Task(string)).create()
    
    for i in 0..9 do
        tasks.append(spawn fetch_data("https://api.example.com/data"))
    end
    
    var results := await_all(tasks)
    
    for result in results do
        writeln(result)
    end
end
```

5.3 Channels

```pascal
var ch: channel(int32) := channel.create(10)  /* buffered */
ch.send(42)
var value := ch.recv()
```

---

Part 6: Safety Features

6.1 Safety Levels

Level Bounds Overflow Use-After-Free Leak Detection Overhead
full ✅ ✅ ✅ ✅ +20-30%
release ✅ ✅ ❌ ❌ +5-10%
os ✅ ❌ ❌ ❌ +2-5%
none ❌ ❌ ❌ ❌ 0%

6.2 Safe/Unsafe Blocks

```pascal
safe do
    arr[i] := 42   /* bounds checked, overflow checked */
end

unsafe do
    arr[i] := 42   /* no checks — maximum performance */
    asm { mov eax, 42 }  /* inline assembly allowed */
end
```

6.3 Option Type (Null Safety)

```pascal
var maybe: ?int32 := null

if maybe |value| then
    writeln("Value: ", value)   /* only runs if not null */
end

var val := maybe ?? 0   /* defaults to 0 if null */
```

---

Part 7: Cross-Language FFI

Maia provides built-in FFI to 7 languages with zero-copy where possible.

Language Keyword Overhead
- C extern "C" Zero
- C++ extern "C++" Minimal
- Rust extern "Rust" Minimal
- Zig extern "Zig" Zero
- Pony extern "Pony" Minimal
- Java extern "Java" Moderate (JNI)
- Python extern "Python" Moderate

```pascal
/* Example: Calling Python from Maia */
@link("python3")
extern "Python" function PyImport_ImportModule(name: *u8): *PyObject

var numpy := PyImport_ImportModule("numpy")
```

---

Part 8: Platform Support

8.1 Tier 1 Platforms

Platform Minimum Version Architectures
- Linux Kernel 6.12 x86_64, ARM64, RISC-V
- Windows Windows 10 (1607+) x86_64, ARM64
- macOS 11 (Big Sur) x86_64, ARM64
- FreeBSD 13.0 x86_64, ARM64, RISC-V
- OpenBSD 7.0 x86_64, ARM64
- NetBSD 10.0 x86_64, ARM64, RISC-V
- DragonFlyBSD 6.0 x86_64

8.2 Backends

Architecture Status Output Formats
- x86_64 ✅ Stable ELF, Mach-O, PE
- ARM64 ✅ Stable ELF, Mach-O, PE
- RISC-V ✅ Stable ELF
- WebAssembly ✅ Stable WASM

No LLVM dependency — Maia has its own native code generation.

---

Part 9: Tooling

9.1 Compiler Toolchain

```bash
maia build --release          # compile Maia code
maia test --verbose           # run tests
maia docs --output=docs/      # generate documentation
maia fmt --check              # format code
maia lint                     # lint code
```

9.2 Koda Tools

```bash
koda                          # REPL (interactive shell)
koda script.koda              # run script
koda run --web server.koda    # run web server
pssh                          # POSIX shell (written in Koda)
pkg install stdlib            # package manager
loki main.maia                # modal editor (Kakoune-style)
doobie ./docs                 # TUI documentation reader
```

9.3 Package Management

```toml
# maia.toml — project configuration (TOML only, no YAML)
[project]
name = "myproject"
version = "0.1.0"

[project.dependencies]
stdlib = { version = "^0.1.0" }
net = { git = "https://github.com/purginglighttech/net" }
```

```bash
pkg add stdlib@^0.1.0    # add dependency
pkg update               # update dependencies
pkg build                # build project
```

---

Part 10: Performance Targets

10.1 Compile Time

Codebase Target
- Hello World < 50ms
- Math Library (500 LOC) < 500ms
- TOML Config Loader < 100ms
- Full Compiler (50K LOC) < 30s

10.2 Runtime Performance

Operation Target (ns)
- Function call < 2ns
- Integer add < 1ns
- Float add < 2ns
- Memory alloc (arena) < 50ns
- Channel send < 100ns
- Actor message < 200ns

10.3 TOML Parsing (Default Format)

File Size Parse Time
- 1KB < 10µs
- 10KB < 50µs
- 100KB < 500µs
- 1MB < 5ms

10.4 Concurrency

Metric Target
- Actor throughput > 5M msg/s
- Parallel speedup (8 cores) > 6x
- Channel contention < 1µs

---

Part 11: Comparison with Other Languages

```toml
# comparison_summary.toml
[maia]
memory_safety = "Multi-layer (borrow + RC + capabilities)"
no_gc = true
concurrency = "Actors + channels"
embedded = false
shell = false

[koda]
memory_safety = "Reference counting"
no_gc = false
concurrency = "Async/await"
embedded = true
shell = true

[rust]
memory_safety = "Borrow checker"
no_gc = true
concurrency = "Threads + channels"
embedded = false
shell = false

[lua]
memory_safety = "GC"
no_gc = false
concurrency = "Coroutines"
embedded = true
shell = false

[bash]
memory_safety = "None"
no_gc = true
concurrency = "Processes"
embedded = false
shell = true
```

Language Embedded Shell No GC Memory Safety Concurrency
Maia ❌ ❌ ✅ Multi-layer Actors
Koda ✅ ✅ ❌ Reference counting Async/await
Rust ❌ ❌ ✅ Borrow checker Threads
Lua ✅ ❌ ❌ GC Coroutines
Bash ❌ ✅ ✅ None Processes
Python ❌ ❌ ❌ GC Async/threads

Koda occupies a unique position — it is the only language that is both a first-class embedded scripting language AND a first-class standalone shell language.

---

Part 12: Code Example — Complete Web Server

```koda
/* webserver.koda — complete HTTP/1.1 server in Koda */
import Koda.Web
import Koda.JSON
import Koda.Template

var app := Web.Server.create()

/* Serve static files */
app.static("/css", "./public/css")
app.static("/js", "./public/js")

/* JSON API */
app.get("/api/users", |req| {
    var users := db.query("SELECT * FROM users")
    return Response.json(users)
})

app.post("/api/users", |req| {
    var user := req.json()
    var id := db.insert("users", user)
    return Response.json({ id = id, status = "created" })
})

/* HTML template */
var tpl := Template.load("views/index.html")

app.get("/", |req| {
    var data := {
        title = "Welcome",
        users = db.query("SELECT * FROM users LIMIT 10"),
    }
    return Response.html(tpl.render(data))
})

/* WebSocket support */
app.websocket("/ws", |socket| {
    socket.on("message", |data| {
        var msg := JSON.parse(data)
        socket.send(JSON.stringify({ echo = msg }))
    })
})

app.listen(8080)
writeln("Server running on http://localhost:8080")
```

---

Part 13: Configuration (TOML Only)

MaiaKoda uses TOML exclusively for all configuration — no YAML, no JSON (except web APIs).

```toml
# maia.toml — project configuration
[project]
name = "myapp"
version = "0.1.0"
authors = ["Purging Light Technologies"]
license = "MIT"

[project.dependencies]
stdlib = { version = "^0.1.0" }
web = { git = "https://github.com/purginglighttech/web" }

[build]
optimization = "release"
safety = "full"
target = "x86_64-linux"

[build.targets.linux]
kernel_minimum = "6.12"
architectures = ["x86_64", "arm64", "riscv64"]
```

---

Part 14: Documentation (Markdown)

Documentation comments use /// syntax and generate GitHub Markdown.

```pascal
/// # Math Module
/// 
/// Provides basic mathematical operations.
/// 
/// @example
/// var sum := Math.add(5, 3)
function add(a: int32, b: int32): int32
begin
    return a + b
end
```

Generated output:

```markdown
# Math Module

Provides basic mathematical operations.

**Example:**
```pascal
var sum := Math.add(5, 3)
```

```

---

## Part 15: Getting Started

### 15.1 Installation

```bash
# Linux / macOS / BSD
curl -sSf https://get.maiakoda.com | sh

# Windows (PowerShell)
iwr https://get.maiakoda.com/install.ps1 | iex

# From source
git clone https://github.com/purginglighttech/maiakoda
cd maiakoda
koda bootstrap
```

15.2 First Project

```bash
maia new hello
cd hello
maia build
./target/release/hello
```

15.3 First Koda Script

```koda
# hello.koda
writeln("Hello, Koda!")
```

```bash
koda hello.koda
```

---

Part 16: Summary

```toml
# summary.toml
[languages]
maia = "Compiled systems language — no GC, ownership, actors, inline assembly"
koda = "Interpreted scripting language — embedded + shell, async/await, web"

[unique_features]
compile_time_rc = "Reference counting optimized at compile time (zero overhead)"
reference_capabilities = "Pony-style data-race freedom"
dual_nature = "Only language that is both embedded AND shell"
toml_default = "TOML exclusively for configuration (no YAML)"
no_llvm = "Self-hosted with native backends"
bidirectional_ffi = "Koda runs on Maia VM; Maia can embed Koda"

[platforms]
tier_1 = ["Linux", "Windows", "macOS", "FreeBSD", "OpenBSD", "NetBSD", "DragonFlyBSD"]
architectures = ["x86_64", "ARM64", "RISC-V", "WebAssembly"]

[performance]
compile_time = "2.5M LOC/sec"
binary_size = "8KB for hello world"
runtime = "Comparable to C (within 10%)"
```

---

End of MaiaKoda Technical Overview v0.0.2
