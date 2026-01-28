#!/bin/bash
# Wave-ASM build script

set -e

echo "🌊 Building Wave-ASM..."

nasm -f elf64 src/wavec.asm -o wavec.o
ld wavec.o -o wavec
rm -f wavec.o

chmod +x wavec

echo "✓ Built: wavec ($(stat -c%s wavec) bytes)"
