# 🌊 Wave-ASM

**Alpha Test 1.0** | Full-featured compiler in pure x86-64 assembly

> Complete Wave compiler - no libc, no runtime, just syscalls.

---

## Features (Full Parity with Wave-C)

- ✅ Variables with stack management
- ✅ Arithmetic: `+`, `-`, `*`, `/`
- ✅ Comparison: `==`, `!=`, `>`, `<`, `>=`, `<=`
- ✅ Conditions: `when { }`
- ✅ Loops: `loop { }`, `break`
- ✅ Functions: `fn name params { }`, `-> return`
- ✅ I/O: `out`, `byte`, `emit`, `getchar`, `putchar`
- ✅ System: `syscall.exit(n)`
- ✅ Unified Field: `unified { i: v, e: v, r: v }`
- ✅ Fate control: `fate on/off`
- ✅ ELF64 output

---

## Build

```bash
# Requires nasm
nasm -f elf64 src/wavec.asm -o wavec.o
ld wavec.o -o wavec

# Or use build script
chmod +x build.sh
./build.sh
```

---

## Usage

```bash
./wavec input.wave -o output
./output
```

---

## Example

```wave
# Full featured example
unified {
    i: 0.8
    e: 0.2
    r: 0.9
}

fn factorial n {
    when n <= 1 { -> 1 }
    prev = n - 1
    sub = factorial(prev)
    -> n * sub
}

out "Factorial test:\n"
result = factorial(5)
out "5! = 120\n"

i = 0
loop {
    i = i + 1
    byte(48 + i)
    byte(32)
    when i >= 5 { break }
}
out "\n"

syscall.exit(0)
```

---

## Size

Assembled compiler: **~15KB** (no external dependencies)

---

## Why Assembly?

- **Zero dependencies** - runs on any x86-64 Linux
- **Minimal surface** - nothing but syscalls
- **Educational** - see exactly how compilation works
- **Fast startup** - no runtime initialization

---

## License

MIT License

Copyright © 2026 Jouly Mars (ZHUOLI MA)  
Rogue Intelligence LNC.

---

[📦 wave-c](https://github.com/joulyman/wave-c) · [📦 wave-bin](https://github.com/joulyman/wave-bin) · [🌐 Website](https://joulyman.github.io/wave-c)
