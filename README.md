# 🌊 Wave-ASM

**Alpha Test 1.0** | Rule-driven compiler in pure x86-64 assembly

> The Wave compiler, written entirely in assembly language.

---

## What is This?

Wave-ASM is the Wave compiler implemented in pure x86-64 assembly. No C runtime, no libraries - just syscalls.

```
Source → wavec.asm → ELF64 Binary
```

Same language, same features, minimal footprint.

---

## Build

```bash
# Assemble
nasm -f elf64 src/wavec.asm -o wavec.o

# Link (no libc)
ld wavec.o -o wavec

# Or use the build script
./build.sh
```

---

## Usage

```bash
./wavec hello.wave -o hello
./hello
```

---

## Example

```wave
out "Hello from Wave-ASM!\n"
syscall.exit(0)
```

---

## Features

- [x] Variables and arithmetic (`+`, `-`, `*`, `/`)
- [x] Comparisons (`==`, `!=`, `>`, `<`, `>=`, `<=`)
- [x] Conditions (`when`)
- [x] Loops (`loop`, `break`)
- [x] Functions (`fn`, `->`)
- [x] String output (`out`)
- [x] System calls (`syscall.exit`)
- [x] Unified field config (`unified`)
- [x] ELF64 output

---

## Size

The assembled compiler is under **8KB**.

---

## Why Assembly?

- **Zero dependencies** - runs on any x86-64 Linux
- **Minimal attack surface** - nothing but syscalls
- **Educational** - see exactly how compilation works
- **Fast** - no runtime overhead

---

## License

MIT License

Copyright © 2026 Jouly Mars (ZHUOLI MA)  
Rogue Intelligence LNC.

---

[📦 wave-c](https://github.com/joulyman/wave-c) · [📦 wave-bin](https://github.com/joulyman/wave-bin)
