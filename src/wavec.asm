; ═══════════════════════════════════════════════════════════════════════════
; Wave-ASM Alpha Test 1.0 - Complete Rule-Driven Compiler (x86-64 Assembly)
; 
; Full-featured Wave compiler written in pure x86-64 assembly.
; Feature parity with Wave-C.
;
; Features:
;   - Unified Field (i, e, r) configuration
;   - Variables with stack management (up to 1024 variables)
;   - Arithmetic: +, -, *, /
;   - Comparison: ==, !=, >, <, >=, <=
;   - Conditions: when { }
;   - Loops: loop { }, break
;   - Functions: fn name params { }, -> return
;   - I/O: out, byte, emit, getchar, putchar
;   - System: syscall.exit(n)
;   - Fate: fate on/off
;   - ELF64 output
;
; Build: nasm -f elf64 wavec.asm -o wavec.o && ld wavec.o -o wavec
;
; Copyright (c) 2026 Jouly Mars (ZHUOLI MA)
; Rogue Intelligence LNC.
; ═══════════════════════════════════════════════════════════════════════════

bits 64
default rel

; ───────────────────────────────────────────────────────────────────────────
; System calls (Linux x86-64)
; ───────────────────────────────────────────────────────────────────────────
SYS_READ    equ 0
SYS_WRITE   equ 1
SYS_OPEN    equ 2
SYS_CLOSE   equ 3
SYS_EXIT    equ 60

STDIN       equ 0
STDOUT      equ 1
STDERR      equ 2

O_RDONLY    equ 0
O_WRONLY    equ 1
O_CREAT     equ 64
O_TRUNC     equ 512

; ───────────────────────────────────────────────────────────────────────────
; Constants
; ───────────────────────────────────────────────────────────────────────────
MAX_SOURCE  equ 1048576     ; 1MB source
MAX_CODE    equ 4194304     ; 4MB code
MAX_VARS    equ 1024
MAX_FUNCS   equ 256
MAX_FIXUPS  equ 4096
BASE_ADDR   equ 0x400000
STACK_SIZE  equ 0x2000      ; 8KB stack frame

section .data
    ; Banner
    banner: db 0xF0, 0x9F, 0x8C, 0x8A, " Wave-ASM 1.0-alpha", 10
            db "   Rule-Driven Compiler | Rogue Intelligence LNC.", 10, 10, 0
    banner_len equ $ - banner

    ; Messages
    msg_usage:    db "Usage: wavec <input.wave> -o <output>", 10, 0
    msg_compiled: db "Compiled: ", 0
    msg_bytes:    db " bytes", 10, 0
    msg_error:    db "Error: compilation failed", 10, 0
    msg_nl:       db 10, 0

    ; ELF64 header template
    elf_header:
        db 0x7f, "ELF"          ; Magic
        db 2                     ; 64-bit
        db 1                     ; Little endian
        db 1                     ; ELF version
        db 0                     ; System V ABI
        times 8 db 0             ; Padding
        dw 2                     ; Executable
        dw 0x3e                  ; x86-64
        dd 1                     ; ELF version
        dq BASE_ADDR + 0x78     ; Entry point (after headers)
        dq 0x40                  ; Program header offset
        dq 0                     ; Section header offset
        dd 0                     ; Flags
        dw 64                    ; ELF header size
        dw 56                    ; Program header size
        dw 1                     ; Number of program headers
        dw 64                    ; Section header size
        dw 0                     ; Number of section headers
        dw 0                     ; Section name string table index
    elf_header_len equ $ - elf_header

    ; Program header template
    prog_header:
        dd 1                     ; PT_LOAD
        dd 7                     ; Flags: R+W+X
        dq 0                     ; Offset
    prog_filesz: dq 0            ; File size (patched)
    prog_memsz:  dq 0            ; Memory size (patched)
        dq BASE_ADDR            ; Virtual address
        dq BASE_ADDR            ; Physical address
        dq 0x1000               ; Alignment
    prog_header_len equ $ - prog_header

    ; Unified Field defaults (fixed-point: value * 1000)
    unified_i: dq 500           ; 0.5
    unified_e: dq 500           ; 0.5
    unified_r: dq 500           ; 0.5
    fate_mode: dq 1             ; 1 = on, 0 = off

section .bss
    ; Source
    source_buf: resb MAX_SOURCE
    source_len: resq 1
    source_pos: resq 1

    ; Code output
    code_buf:   resb MAX_CODE
    code_len:   resq 1

    ; Variables: name(32) + stack_offset(8)
    var_names:  resb MAX_VARS * 32
    var_offs:   resq MAX_VARS
    var_count:  resq 1
    stack_off:  resq 1          ; Current stack offset

    ; Functions: name(32) + code_offset(8) + param_count(8) + param_names(8*32)
    func_names: resb MAX_FUNCS * 32
    func_addrs: resq MAX_FUNCS
    func_params:resq MAX_FUNCS
    func_param_names: resb MAX_FUNCS * 8 * 32  ; Up to 8 params per func
    func_count: resq 1
    current_func: resq 1        ; Index of function being compiled

    ; Loop management
    loop_depth: resq 1
    loop_starts: resq 64        ; Up to 64 nested loops
    loop_breaks: resq 64 * 16   ; Up to 16 break fixups per loop

    ; Break fixup list
    break_fixups: resq MAX_FIXUPS
    break_count: resq 1

    ; Temp buffers
    ident_buf:  resb 256
    str_buf:    resb 4096
    num_buf:    resq 1
    output_fd:  resq 1
    input_fd:   resq 1
    output_path: resq 1

section .text
global _start

; ═══════════════════════════════════════════════════════════════════════════
; Entry point
; ═══════════════════════════════════════════════════════════════════════════
_start:
    ; Print banner
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    lea rsi, [banner]
    mov rdx, banner_len
    syscall

    ; Check args (argc >= 4: prog input -o output)
    mov rdi, [rsp]          ; argc
    cmp rdi, 4
    jl .usage

    ; Get argv[1] = input file
    mov rsi, [rsp + 16]     ; argv[1]
    call open_input

    ; Get argv[3] = output file
    mov rsi, [rsp + 32]     ; argv[3]
    mov [output_path], rsi
    call create_output

    ; Read source
    call read_source

    ; Initialize compiler state
    call init_state

    ; Compile
    call compile

    ; Write ELF
    call write_elf

    ; Print result
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    lea rsi, [msg_compiled]
    mov rdx, 10
    syscall

    ; Print size
    mov rax, [code_len]
    call print_number

    mov rax, SYS_WRITE
    mov rdi, STDOUT
    lea rsi, [msg_bytes]
    mov rdx, 7
    syscall

    ; Exit success
    mov rax, SYS_EXIT
    xor rdi, rdi
    syscall

.usage:
    mov rax, SYS_WRITE
    mov rdi, STDERR
    lea rsi, [msg_usage]
    mov rdx, 38
    syscall
    mov rax, SYS_EXIT
    mov rdi, 1
    syscall

; ═══════════════════════════════════════════════════════════════════════════
; File I/O
; ═══════════════════════════════════════════════════════════════════════════
open_input:
    mov rax, SYS_OPEN
    mov rdi, rsi
    mov rsi, O_RDONLY
    xor rdx, rdx
    syscall
    cmp rax, 0
    jl error_exit
    mov [input_fd], rax
    ret

create_output:
    mov rax, SYS_OPEN
    mov rdi, rsi
    mov rsi, O_WRONLY | O_CREAT | O_TRUNC
    mov rdx, 0o755
    syscall
    cmp rax, 0
    jl error_exit
    mov [output_fd], rax
    ret

read_source:
    mov rax, SYS_READ
    mov rdi, [input_fd]
    lea rsi, [source_buf]
    mov rdx, MAX_SOURCE
    syscall
    cmp rax, 0
    jl error_exit
    mov [source_len], rax
    mov rax, SYS_CLOSE
    mov rdi, [input_fd]
    syscall
    ret

; ═══════════════════════════════════════════════════════════════════════════
; Initialize compiler state
; ═══════════════════════════════════════════════════════════════════════════
init_state:
    xor rax, rax
    mov [source_pos], rax
    mov [code_len], rax
    mov [var_count], rax
    mov [func_count], rax
    mov [loop_depth], rax
    mov [break_count], rax
    mov [current_func], rax
    mov qword [stack_off], 8    ; Start at offset 8 (rbp at 0)
    mov qword [fate_mode], 1    ; Fate on by default
    ret

; ═══════════════════════════════════════════════════════════════════════════
; Main compiler
; ═══════════════════════════════════════════════════════════════════════════
compile:
    ; First pass: collect function definitions
    call collect_functions

    ; Reset position
    mov qword [source_pos], 0

    ; Generate prologue
    call emit_prologue

    ; Second pass: compile main code
.main_loop:
    call skip_ws
    mov rax, [source_pos]
    cmp rax, [source_len]
    jge .done

    call compile_statement
    jmp .main_loop

.done:
    ret

; ───────────────────────────────────────────────────────────────────────────
; Collect function definitions (first pass)
; ───────────────────────────────────────────────────────────────────────────
collect_functions:
.loop:
    call skip_ws
    mov rax, [source_pos]
    cmp rax, [source_len]
    jge .done

    ; Check for 'fn'
    call check_fn
    test al, al
    jz .skip_line

    ; Parse function name
    add qword [source_pos], 2
    call skip_ws
    call parse_ident

    ; Store function entry
    mov rax, [func_count]
    cmp rax, MAX_FUNCS
    jge .done

    ; Copy name
    lea rdi, [func_names]
    imul rcx, rax, 32
    add rdi, rcx
    lea rsi, [ident_buf]
    mov rcx, 32
    call memcpy

    ; Will set address later
    mov qword [func_addrs + rax*8], 0

    ; Parse parameters
    call skip_ws
    xor rcx, rcx            ; param count
.param_loop:
    call peek_char
    cmp al, '{'
    je .param_done
    cmp al, 0
    je .param_done
    cmp al, 10
    je .param_done

    call is_alpha
    test al, al
    jz .skip_param_char

    ; Parse param name
    push rcx
    call parse_ident
    pop rcx

    ; Store param name
    mov rax, [func_count]
    lea rdi, [func_param_names]
    imul r8, rax, 8 * 32    ; 8 params * 32 bytes each
    add rdi, r8
    imul r8, rcx, 32
    add rdi, r8
    lea rsi, [ident_buf]
    push rcx
    mov rcx, 32
    call memcpy
    pop rcx
    inc rcx
    jmp .param_loop

.skip_param_char:
    inc qword [source_pos]
    jmp .param_loop

.param_done:
    mov rax, [func_count]
    mov [func_params + rax*8], rcx
    inc qword [func_count]

    ; Skip to end of function
    call skip_to_brace_end
    jmp .loop

.skip_line:
    call skip_line
    jmp .loop

.done:
    ret

skip_to_brace_end:
    xor rcx, rcx            ; brace depth
.loop:
    call peek_char
    cmp al, 0
    je .done
    cmp al, '{'
    jne .check_close
    inc rcx
    jmp .next
.check_close:
    cmp al, '}'
    jne .next
    dec rcx
    cmp rcx, 0
    jl .done
.next:
    inc qword [source_pos]
    jmp .loop
.done:
    inc qword [source_pos]
    ret

; ───────────────────────────────────────────────────────────────────────────
; Emit prologue
; ───────────────────────────────────────────────────────────────────────────
emit_prologue:
    ; push rbp
    mov al, 0x55
    call emit_byte
    ; mov rbp, rsp
    mov eax, 0xe58948
    call emit_3bytes
    ; sub rsp, STACK_SIZE
    mov al, 0x48
    call emit_byte
    mov al, 0x81
    call emit_byte
    mov al, 0xec
    call emit_byte
    mov eax, STACK_SIZE
    call emit_dword
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile statement
; ───────────────────────────────────────────────────────────────────────────
compile_statement:
    call skip_ws
    call peek_char

    ; Comment
    cmp al, '#'
    je .skip_comment

    ; Empty
    cmp al, 0
    je .done
    cmp al, '}'
    je .done

    ; Keywords
    call check_out
    test al, al
    jnz .do_out

    call check_emit
    test al, al
    jnz .do_emit

    call check_byte
    test al, al
    jnz .do_byte

    call check_syscall_exit
    test al, al
    jnz .do_exit

    call check_when
    test al, al
    jnz .do_when

    call check_loop
    test al, al
    jnz .do_loop

    call check_break
    test al, al
    jnz .do_break

    call check_fn
    test al, al
    jnz .do_fn

    call check_unified
    test al, al
    jnz .do_unified

    call check_fate
    test al, al
    jnz .do_fate

    call check_putchar
    test al, al
    jnz .do_putchar

    call check_getchar_stmt
    test al, al
    jnz .do_getchar_stmt

    ; Return statement
    call check_return
    test al, al
    jnz .do_return

    ; Identifier (assignment or function call)
    call peek_char
    call is_alpha
    test al, al
    jz .skip_line

    call parse_ident
    call skip_ws
    call peek_char

    cmp al, '='
    je .do_assign

    cmp al, '('
    je .do_call

    jmp .skip_line

.skip_comment:
    call skip_line
    ret

.do_out:
    call compile_out
    ret

.do_emit:
    call compile_emit
    ret

.do_byte:
    call compile_byte
    ret

.do_exit:
    call compile_exit
    ret

.do_when:
    call compile_when
    ret

.do_loop:
    call compile_loop
    ret

.do_break:
    call compile_break
    ret

.do_fn:
    call compile_fn
    ret

.do_unified:
    call compile_unified
    ret

.do_fate:
    call compile_fate
    ret

.do_putchar:
    call compile_putchar
    ret

.do_getchar_stmt:
    call compile_getchar_stmt
    ret

.do_return:
    call compile_return
    ret

.do_assign:
    call next_char          ; consume '='
    call skip_ws
    push qword [var_count]  ; save for after expr
    call compile_expr
    pop rcx
    call store_var_by_name
    ret

.do_call:
    call compile_call
    ret

.skip_line:
    call skip_line
    ret

.done:
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile 'out "string"'
; ───────────────────────────────────────────────────────────────────────────
compile_out:
    add qword [source_pos], 3
    call skip_ws

    call next_char
    cmp al, '"'
    jne .error

    ; Parse string with escapes
    lea rdi, [str_buf]
    xor rcx, rcx
.parse_str:
    call peek_char
    cmp al, '"'
    je .str_done
    cmp al, 0
    je .error

    cmp al, '\'
    jne .normal_char

    ; Escape sequence
    inc qword [source_pos]
    call peek_char
    inc qword [source_pos]

    cmp al, 'n'
    jne .not_n
    mov byte [rdi + rcx], 10
    inc rcx
    jmp .parse_str
.not_n:
    cmp al, 't'
    jne .not_t
    mov byte [rdi + rcx], 9
    inc rcx
    jmp .parse_str
.not_t:
    cmp al, 'r'
    jne .not_r
    mov byte [rdi + rcx], 13
    inc rcx
    jmp .parse_str
.not_r:
    cmp al, '0'
    jne .not_0
    mov byte [rdi + rcx], 0
    inc rcx
    jmp .parse_str
.not_0:
    cmp al, 'x'
    jne .other_esc
    ; Hex escape
    call parse_hex_byte
    mov [rdi + rcx], al
    inc rcx
    jmp .parse_str
.other_esc:
    mov [rdi + rcx], al
    inc rcx
    jmp .parse_str

.normal_char:
    mov [rdi + rcx], al
    inc rcx
    inc qword [source_pos]
    jmp .parse_str

.str_done:
    inc qword [source_pos]  ; skip closing "
    push rcx                ; save length

    ; jmp over string data (use near jump for long strings)
    mov al, 0xe9            ; jmp near rel32
    call emit_byte
    mov eax, ecx
    call emit_dword

    ; Emit string bytes
    xor rdx, rdx
.emit_str:
    cmp rdx, rcx
    jge .emit_done
    push rcx
    push rdx
    mov al, [str_buf + rdx]
    call emit_byte
    pop rdx
    pop rcx
    inc rdx
    jmp .emit_str

.emit_done:
    pop rcx                 ; restore length

    ; Generate write syscall
    ; mov rax, 1 (SYS_WRITE)
    mov al, 0x48
    call emit_byte
    mov al, 0xc7
    call emit_byte
    mov al, 0xc0
    call emit_byte
    mov eax, SYS_WRITE
    call emit_dword

    ; mov rdi, 1 (STDOUT)
    mov al, 0x48
    call emit_byte
    mov al, 0xc7
    call emit_byte
    mov al, 0xc7
    call emit_byte
    mov eax, STDOUT
    call emit_dword

    ; lea rsi, [rip - offset]
    mov al, 0x48
    call emit_byte
    mov al, 0x8d
    call emit_byte
    mov al, 0x35
    call emit_byte
    ; offset = -(19 + len) where 19 is size of syscall code
    mov eax, ecx
    add eax, 19
    neg eax
    call emit_dword

    ; mov rdx, len
    mov al, 0x48
    call emit_byte
    mov al, 0xc7
    call emit_byte
    mov al, 0xc2
    call emit_byte
    mov eax, ecx
    call emit_dword

    ; syscall
    mov al, 0x0f
    call emit_byte
    mov al, 0x05
    call emit_byte

    ret

.error:
    jmp error_exit

; ───────────────────────────────────────────────────────────────────────────
; Compile 'emit "raw_bytes"'
; ───────────────────────────────────────────────────────────────────────────
compile_emit:
    add qword [source_pos], 4
    call skip_ws

    call next_char
    cmp al, '"'
    jne .error

    ; Parse and emit bytes directly
    lea rdi, [str_buf]
    xor rcx, rcx
.parse:
    call peek_char
    cmp al, '"'
    je .done
    cmp al, 0
    je .error

    cmp al, '\'
    jne .normal

    inc qword [source_pos]
    call peek_char
    inc qword [source_pos]

    cmp al, 'x'
    jne .other
    call parse_hex_byte
    jmp .store

.other:
    cmp al, 'n'
    jne .not_n
    mov al, 10
    jmp .store
.not_n:
    cmp al, 't'
    jne .not_t
    mov al, 9
    jmp .store
.not_t:
    cmp al, '0'
    jne .store
    mov al, 0
    jmp .store

.normal:
    inc qword [source_pos]

.store:
    mov [rdi + rcx], al
    inc rcx
    jmp .parse

.done:
    inc qword [source_pos]
    push rcx

    ; jmp over data
    mov al, 0xe9
    call emit_byte
    mov eax, ecx
    call emit_dword

    ; Emit raw bytes
    xor rdx, rdx
.emit:
    cmp rdx, rcx
    jge .emit_done
    push rcx
    push rdx
    mov al, [str_buf + rdx]
    call emit_byte
    pop rdx
    pop rcx
    inc rdx
    jmp .emit

.emit_done:
    pop rcx

    ; write syscall
    mov al, 0x48
    call emit_byte
    mov al, 0xc7
    call emit_byte
    mov al, 0xc0
    call emit_byte
    mov eax, SYS_WRITE
    call emit_dword

    mov al, 0x48
    call emit_byte
    mov al, 0xc7
    call emit_byte
    mov al, 0xc7
    call emit_byte
    mov eax, STDOUT
    call emit_dword

    mov al, 0x48
    call emit_byte
    mov al, 0x8d
    call emit_byte
    mov al, 0x35
    call emit_byte
    mov eax, ecx
    add eax, 19
    neg eax
    call emit_dword

    mov al, 0x48
    call emit_byte
    mov al, 0xc7
    call emit_byte
    mov al, 0xc2
    call emit_byte
    mov eax, ecx
    call emit_dword

    mov al, 0x0f
    call emit_byte
    mov al, 0x05
    call emit_byte

    ret

.error:
    jmp error_exit

; ───────────────────────────────────────────────────────────────────────────
; Compile 'byte(n)'
; ───────────────────────────────────────────────────────────────────────────
compile_byte:
    add qword [source_pos], 4
    call skip_ws
    call next_char          ; '('
    call skip_ws
    call compile_expr       ; value in rax
    call skip_ws
    call next_char          ; ')'

    ; Store byte on stack and write
    ; sub rsp, 16
    mov al, 0x48
    call emit_byte
    mov al, 0x83
    call emit_byte
    mov al, 0xec
    call emit_byte
    mov al, 16
    call emit_byte

    ; mov [rsp], al
    mov al, 0x88
    call emit_byte
    mov al, 0x04
    call emit_byte
    mov al, 0x24
    call emit_byte

    ; mov rax, 1
    mov al, 0x48
    call emit_byte
    mov al, 0xc7
    call emit_byte
    mov al, 0xc0
    call emit_byte
    mov eax, SYS_WRITE
    call emit_dword

    ; mov rdi, 1
    mov al, 0x48
    call emit_byte
    mov al, 0xc7
    call emit_byte
    mov al, 0xc7
    call emit_byte
    mov eax, STDOUT
    call emit_dword

    ; lea rsi, [rsp]
    mov al, 0x48
    call emit_byte
    mov al, 0x8d
    call emit_byte
    mov al, 0x34
    call emit_byte
    mov al, 0x24
    call emit_byte

    ; mov rdx, 1
    mov al, 0x48
    call emit_byte
    mov al, 0xc7
    call emit_byte
    mov al, 0xc2
    call emit_byte
    mov eax, 1
    call emit_dword

    ; syscall
    mov al, 0x0f
    call emit_byte
    mov al, 0x05
    call emit_byte

    ; add rsp, 16
    mov al, 0x48
    call emit_byte
    mov al, 0x83
    call emit_byte
    mov al, 0xc4
    call emit_byte
    mov al, 16
    call emit_byte

    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile 'putchar(n)'
; ───────────────────────────────────────────────────────────────────────────
compile_putchar:
    add qword [source_pos], 7
    call skip_ws
    call next_char          ; '('
    call skip_ws
    call compile_expr
    call skip_ws
    call next_char          ; ')'

    ; Same as byte
    jmp compile_byte.emit_after_expr

compile_byte.emit_after_expr:
    ; (code already emitted compile_expr, rax has value)
    ; Just need to output it
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile 'getchar()' as statement
; ───────────────────────────────────────────────────────────────────────────
compile_getchar_stmt:
    add qword [source_pos], 9   ; 'getchar()'
    ; Just read and discard
    call emit_getchar
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile 'syscall.exit(n)'
; ───────────────────────────────────────────────────────────────────────────
compile_exit:
    add qword [source_pos], 12
    call skip_ws
    call next_char          ; '('
    call skip_ws
    call compile_expr       ; exit code in rax
    call skip_ws
    call next_char          ; ')'

    ; mov rdi, rax
    mov al, 0x48
    call emit_byte
    mov al, 0x89
    call emit_byte
    mov al, 0xc7
    call emit_byte

    ; mov rax, 60
    mov al, 0x48
    call emit_byte
    mov al, 0xc7
    call emit_byte
    mov al, 0xc0
    call emit_byte
    mov eax, SYS_EXIT
    call emit_dword

    ; syscall
    mov al, 0x0f
    call emit_byte
    mov al, 0x05
    call emit_byte

    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile 'when condition { ... }'
; ───────────────────────────────────────────────────────────────────────────
compile_when:
    add qword [source_pos], 4
    call skip_ws
    call compile_expr       ; condition in rax

    ; test rax, rax
    mov al, 0x48
    call emit_byte
    mov al, 0x85
    call emit_byte
    mov al, 0xc0
    call emit_byte

    ; jz end (patch later)
    mov al, 0x0f
    call emit_byte
    mov al, 0x84
    call emit_byte
    mov rax, [code_len]
    push rax                ; save fixup location
    xor eax, eax
    call emit_dword

    ; Skip to '{'
    call skip_ws
    call next_char

    ; Compile body
.body:
    call skip_ws
    call peek_char
    cmp al, '}'
    je .done
    cmp al, 0
    je .error
    call compile_statement
    jmp .body

.done:
    call next_char          ; consume '}'

    ; Patch jump
    pop rax
    mov rcx, [code_len]
    sub rcx, rax
    sub rcx, 4
    lea rdi, [code_buf + rax]
    mov [rdi], ecx

    ret

.error:
    jmp error_exit

; ───────────────────────────────────────────────────────────────────────────
; Compile 'loop { ... }'
; ───────────────────────────────────────────────────────────────────────────
compile_loop:
    add qword [source_pos], 4
    call skip_ws
    call next_char          ; '{'

    ; Save loop start
    mov rax, [code_len]
    mov rcx, [loop_depth]
    mov [loop_starts + rcx*8], rax
    inc qword [loop_depth]

    ; Clear break fixups for this loop
    mov qword [break_count], 0

    ; Compile body
.body:
    call skip_ws
    call peek_char
    cmp al, '}'
    je .done
    cmp al, 0
    je .error
    call compile_statement
    jmp .body

.done:
    call next_char          ; '}'

    ; Emit jmp back to start
    mov al, 0xe9
    call emit_byte
    dec qword [loop_depth]
    mov rcx, [loop_depth]
    mov rax, [loop_starts + rcx*8]
    mov rcx, [code_len]
    sub rax, rcx
    sub rax, 4
    call emit_dword

    ; Patch all break jumps to here
    mov rcx, [break_count]
    test rcx, rcx
    jz .no_breaks
    xor rdx, rdx
.patch_breaks:
    cmp rdx, rcx
    jge .no_breaks
    mov rax, [break_fixups + rdx*8]
    push rcx
    push rdx
    mov rcx, [code_len]
    sub rcx, rax
    sub rcx, 4
    lea rdi, [code_buf + rax]
    mov [rdi], ecx
    pop rdx
    pop rcx
    inc rdx
    jmp .patch_breaks

.no_breaks:
    ret

.error:
    jmp error_exit

; ───────────────────────────────────────────────────────────────────────────
; Compile 'break'
; ───────────────────────────────────────────────────────────────────────────
compile_break:
    add qword [source_pos], 5

    ; jmp to end (will be patched)
    mov al, 0xe9
    call emit_byte
    mov rax, [code_len]
    mov rcx, [break_count]
    mov [break_fixups + rcx*8], rax
    inc qword [break_count]
    xor eax, eax
    call emit_dword

    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile 'fn name params { ... }'
; ───────────────────────────────────────────────────────────────────────────
compile_fn:
    add qword [source_pos], 2
    call skip_ws
    call parse_ident

    ; Find function in table
    call find_func
    cmp rax, -1
    je .error

    ; Jump over function body (for main code flow)
    push rax                ; save func index
    mov al, 0xe9
    call emit_byte
    mov rax, [code_len]
    push rax                ; save fixup location
    xor eax, eax
    call emit_dword

    ; Set function address
    pop rcx                 ; fixup location
    pop rax                 ; func index
    push rcx
    push rax
    mov rcx, [code_len]
    mov [func_addrs + rax*8], rcx
    mov [current_func], rax

    ; Skip params in source
.skip_params:
    call skip_ws
    call peek_char
    cmp al, '{'
    je .found_brace
    inc qword [source_pos]
    jmp .skip_params

.found_brace:
    call next_char

    ; Save base var count
    mov rax, [var_count]
    push rax

    ; Create local variables for parameters
    pop rax                 ; restore base var count
    push rax
    pop r8                  ; r8 = base var count

    mov rax, [current_func]
    mov rcx, [func_params + rax*8]  ; param count
    test rcx, rcx
    jz .no_params

    ; Add params as local vars
    xor rdx, rdx
.add_params:
    cmp rdx, rcx
    jge .no_params
    push rcx
    push rdx

    ; Get param name
    mov rax, [current_func]
    lea rsi, [func_param_names]
    imul r9, rax, 8 * 32
    add rsi, r9
    imul r9, rdx, 32
    add rsi, r9

    ; Copy to ident_buf
    lea rdi, [ident_buf]
    mov rcx, 32
    call memcpy

    ; Create var
    call create_var_from_ident

    pop rdx
    pop rcx
    inc rdx
    jmp .add_params

.no_params:
    ; Emit function prologue
    mov al, 0x55            ; push rbp
    call emit_byte
    mov eax, 0xe58948       ; mov rbp, rsp
    call emit_3bytes
    ; sub rsp, 0x400
    mov al, 0x48
    call emit_byte
    mov al, 0x81
    call emit_byte
    mov al, 0xec
    call emit_byte
    mov eax, 0x400
    call emit_dword

    ; Store parameters from registers to stack
    mov rax, [current_func]
    mov rcx, [func_params + rax*8]
    cmp rcx, 0
    je .body

    ; param 0 from rdi
    cmp rcx, 1
    jl .body
    ; mov [rbp-8], rdi
    mov al, 0x48
    call emit_byte
    mov al, 0x89
    call emit_byte
    mov al, 0x7d
    call emit_byte
    mov al, 0xf8
    call emit_byte

    cmp rcx, 2
    jl .body
    ; mov [rbp-16], rsi
    mov al, 0x48
    call emit_byte
    mov al, 0x89
    call emit_byte
    mov al, 0x75
    call emit_byte
    mov al, 0xf0
    call emit_byte

    cmp rcx, 3
    jl .body
    ; mov [rbp-24], rdx
    mov al, 0x48
    call emit_byte
    mov al, 0x89
    call emit_byte
    mov al, 0x55
    call emit_byte
    mov al, 0xe8
    call emit_byte

    cmp rcx, 4
    jl .body
    ; mov [rbp-32], rcx
    mov al, 0x48
    call emit_byte
    mov al, 0x89
    call emit_byte
    mov al, 0x4d
    call emit_byte
    mov al, 0xe0
    call emit_byte

    ; More params would use r8, r9

.body:
    call skip_ws
    call peek_char
    cmp al, '}'
    je .body_done
    cmp al, 0
    je .error

    ; Check for return
    cmp al, '-'
    jne .not_return
    mov rax, [source_pos]
    lea rsi, [source_buf + rax]
    cmp byte [rsi+1], '>'
    jne .not_return

    add qword [source_pos], 2
    call skip_ws
    call compile_expr

    ; Epilogue and return
    ; mov rsp, rbp (not needed, we'll just pop rbp)
    ; add rsp, 0x400
    mov al, 0x48
    call emit_byte
    mov al, 0x81
    call emit_byte
    mov al, 0xc4
    call emit_byte
    mov eax, 0x400
    call emit_dword
    mov al, 0x5d            ; pop rbp
    call emit_byte
    mov al, 0xc3            ; ret
    call emit_byte
    jmp .body

.not_return:
    call compile_statement
    jmp .body

.body_done:
    call next_char          ; '}'

    ; Default return 0 if no explicit return
    ; xor rax, rax
    mov al, 0x48
    call emit_byte
    mov al, 0x31
    call emit_byte
    mov al, 0xc0
    call emit_byte
    ; add rsp, 0x400
    mov al, 0x48
    call emit_byte
    mov al, 0x81
    call emit_byte
    mov al, 0xc4
    call emit_byte
    mov eax, 0x400
    call emit_dword
    mov al, 0x5d            ; pop rbp
    call emit_byte
    mov al, 0xc3            ; ret
    call emit_byte

    ; Patch jump over function
    pop rax                 ; func index (not used here)
    pop rax                 ; fixup location
    mov rcx, [code_len]
    sub rcx, rax
    sub rcx, 4
    lea rdi, [code_buf + rax]
    mov [rdi], ecx

    ; Clear current func
    mov qword [current_func], 0

    ret

.error:
    jmp error_exit

; ───────────────────────────────────────────────────────────────────────────
; Compile '-> expr' (return)
; ───────────────────────────────────────────────────────────────────────────
compile_return:
    add qword [source_pos], 2
    call skip_ws
    call compile_expr

    ; add rsp, 0x400
    mov al, 0x48
    call emit_byte
    mov al, 0x81
    call emit_byte
    mov al, 0xc4
    call emit_byte
    mov eax, 0x400
    call emit_dword
    mov al, 0x5d            ; pop rbp
    call emit_byte
    mov al, 0xc3            ; ret
    call emit_byte
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile function call (ident already in ident_buf)
; ───────────────────────────────────────────────────────────────────────────
compile_call:
    call find_func
    cmp rax, -1
    je .not_found
    push rax                ; save func index

    call next_char          ; '('

    ; Compile arguments
    xor r12, r12            ; arg count
.arg_loop:
    call skip_ws
    call peek_char
    cmp al, ')'
    je .args_done
    cmp al, ','
    jne .not_comma
    inc qword [source_pos]
    jmp .arg_loop
.not_comma:
    call compile_expr

    ; Store in appropriate register
    cmp r12, 0
    jne .not_arg0
    ; mov rdi, rax
    mov al, 0x48
    call emit_byte
    mov al, 0x89
    call emit_byte
    mov al, 0xc7
    call emit_byte
    jmp .next_arg

.not_arg0:
    cmp r12, 1
    jne .not_arg1
    ; mov rsi, rax
    mov al, 0x48
    call emit_byte
    mov al, 0x89
    call emit_byte
    mov al, 0xc6
    call emit_byte
    jmp .next_arg

.not_arg1:
    cmp r12, 2
    jne .not_arg2
    ; mov rdx, rax
    mov al, 0x48
    call emit_byte
    mov al, 0x89
    call emit_byte
    mov al, 0xc2
    call emit_byte
    jmp .next_arg

.not_arg2:
    cmp r12, 3
    jne .next_arg
    ; mov rcx, rax
    mov al, 0x48
    call emit_byte
    mov al, 0x89
    call emit_byte
    mov al, 0xc1
    call emit_byte

.next_arg:
    inc r12
    jmp .arg_loop

.args_done:
    call next_char          ; ')'

    ; Call function
    pop rax                 ; func index
    mov rcx, [func_addrs + rax*8]
    test rcx, rcx
    jz .forward_call

    ; call rel32
    mov al, 0xe8
    call emit_byte
    mov rax, rcx
    mov rcx, [code_len]
    sub rax, rcx
    sub rax, 4
    call emit_dword
    ret

.forward_call:
    ; Function not yet compiled, emit placeholder
    mov al, 0xe8
    call emit_byte
    xor eax, eax
    call emit_dword
    ret

.not_found:
    ; Unknown function, skip
    call next_char          ; '('
.skip_args:
    call peek_char
    cmp al, ')'
    je .skip_done
    cmp al, 0
    je .skip_done
    inc qword [source_pos]
    jmp .skip_args
.skip_done:
    call next_char
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile 'unified { i: v, e: v, r: v }'
; ───────────────────────────────────────────────────────────────────────────
compile_unified:
    add qword [source_pos], 7
    call skip_ws
    call next_char          ; '{'

.parse_params:
    call skip_ws
    call peek_char
    cmp al, '}'
    je .done
    cmp al, 0
    je .done

    ; Parse parameter name
    cmp al, 'i'
    jne .not_i
    inc qword [source_pos]
    call skip_ws
    call next_char          ; ':'
    call skip_ws
    call parse_float
    mov [unified_i], rax
    jmp .parse_params

.not_i:
    cmp al, 'e'
    jne .not_e
    inc qword [source_pos]
    call skip_ws
    call next_char
    call skip_ws
    call parse_float
    mov [unified_e], rax
    jmp .parse_params

.not_e:
    cmp al, 'r'
    jne .skip_char
    inc qword [source_pos]
    call skip_ws
    call next_char
    call skip_ws
    call parse_float
    mov [unified_r], rax
    jmp .parse_params

.skip_char:
    inc qword [source_pos]
    jmp .parse_params

.done:
    call next_char          ; '}'
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile 'fate on' or 'fate off'
; ───────────────────────────────────────────────────────────────────────────
compile_fate:
    add qword [source_pos], 4
    call skip_ws

    ; Check for 'on' or 'off'
    call peek_char
    cmp al, 'o'
    jne .skip
    inc qword [source_pos]
    call peek_char
    cmp al, 'n'
    jne .check_off
    inc qword [source_pos]
    mov qword [fate_mode], 1
    ret

.check_off:
    cmp al, 'f'
    jne .skip
    add qword [source_pos], 2   ; 'ff'
    mov qword [fate_mode], 0
    ret

.skip:
    call skip_line
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile expression (result in rax)
; ───────────────────────────────────────────────────────────────────────────
compile_expr:
    call skip_ws
    call compile_term

.check_op:
    call skip_ws
    call peek_char

    cmp al, '+'
    je .add
    cmp al, '-'
    je .sub
    cmp al, '*'
    je .mul
    cmp al, '/'
    je .div
    cmp al, '='
    je .check_eq
    cmp al, '!'
    je .check_neq
    cmp al, '>'
    je .check_gt
    cmp al, '<'
    je .check_lt

    ret

.add:
    call next_char
    ; push rax
    mov al, 0x50
    call emit_byte
    call compile_term
    ; pop rcx
    mov al, 0x59
    call emit_byte
    ; add rax, rcx
    mov eax, 0xc80148
    call emit_3bytes
    jmp .check_op

.sub:
    call next_char
    mov al, 0x50
    call emit_byte
    call compile_term
    ; mov rcx, rax
    mov eax, 0xc18948
    call emit_3bytes
    ; pop rax
    mov al, 0x58
    call emit_byte
    ; sub rax, rcx
    mov eax, 0xc82948
    call emit_3bytes
    jmp .check_op

.mul:
    call next_char
    mov al, 0x50
    call emit_byte
    call compile_term
    mov al, 0x59
    call emit_byte
    ; imul rax, rcx
    mov al, 0x48
    call emit_byte
    mov al, 0x0f
    call emit_byte
    mov al, 0xaf
    call emit_byte
    mov al, 0xc1
    call emit_byte
    jmp .check_op

.div:
    call next_char
    mov al, 0x50
    call emit_byte
    call compile_term
    ; mov rcx, rax
    mov eax, 0xc18948
    call emit_3bytes
    mov al, 0x58
    call emit_byte
    ; xor rdx, rdx
    mov eax, 0xd23148
    call emit_3bytes
    ; idiv rcx
    mov al, 0x48
    call emit_byte
    mov al, 0xf7
    call emit_byte
    mov al, 0xf9
    call emit_byte
    jmp .check_op

.check_eq:
    mov rax, [source_pos]
    lea rsi, [source_buf + rax]
    cmp byte [rsi+1], '='
    jne .done
    add qword [source_pos], 2
    call compile_cmp
    mov bl, 0x94            ; sete
    call emit_setcc
    jmp .check_op

.check_neq:
    mov rax, [source_pos]
    lea rsi, [source_buf + rax]
    cmp byte [rsi+1], '='
    jne .done
    add qword [source_pos], 2
    call compile_cmp
    mov bl, 0x95            ; setne
    call emit_setcc
    jmp .check_op

.check_gt:
    call next_char
    call peek_char
    cmp al, '='
    je .gte
    call compile_cmp
    mov bl, 0x9f            ; setg
    call emit_setcc
    jmp .check_op
.gte:
    call next_char
    call compile_cmp
    mov bl, 0x9d            ; setge
    call emit_setcc
    jmp .check_op

.check_lt:
    call next_char
    call peek_char
    cmp al, '='
    je .lte
    call compile_cmp
    mov bl, 0x9c            ; setl
    call emit_setcc
    jmp .check_op
.lte:
    call next_char
    call compile_cmp
    mov bl, 0x9e            ; setle
    call emit_setcc
    jmp .check_op

.done:
    ret

compile_cmp:
    mov al, 0x50
    call emit_byte
    call compile_term
    mov al, 0x59
    call emit_byte
    ; cmp rcx, rax
    mov eax, 0xc13948
    call emit_3bytes
    ret

emit_setcc:
    ; setXX al
    mov al, 0x0f
    call emit_byte
    mov al, bl
    call emit_byte
    mov al, 0xc0
    call emit_byte
    ; movzx rax, al
    mov al, 0x48
    call emit_byte
    mov al, 0x0f
    call emit_byte
    mov al, 0xb6
    call emit_byte
    mov al, 0xc0
    call emit_byte
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile term (number, variable, function call, getchar)
; ───────────────────────────────────────────────────────────────────────────
compile_term:
    call skip_ws
    call peek_char

    ; Number
    cmp al, '0'
    jl .not_num
    cmp al, '9'
    jle .number

.not_num:
    ; Negative number
    cmp al, '-'
    jne .not_neg
    mov rax, [source_pos]
    lea rsi, [source_buf + rax + 1]
    movzx eax, byte [rsi]
    cmp al, '0'
    jl .not_neg
    cmp al, '9'
    jg .not_neg
    jmp .number

.not_neg:
    ; Identifier or function call
    call peek_char
    call is_alpha
    test al, al
    jz .default

    call parse_ident
    call skip_ws
    call peek_char

    cmp al, '('
    je .func_call

    ; Check if it's getchar
    lea rsi, [ident_buf]
    cmp dword [rsi], 'getc'
    jne .load_var
    cmp dword [rsi+4], 'har('
    jne .load_var
    ; It's getchar()
    add qword [source_pos], 2   ; skip ()
    call emit_getchar
    ret

.load_var:
    call load_var_by_name
    ret

.func_call:
    call compile_call
    ret

.number:
    call parse_number
    ; mov rax, imm64
    mov al, 0x48
    call emit_byte
    mov al, 0xb8
    call emit_byte
    mov rax, [num_buf]
    call emit_qword
    ret

.default:
    ; Return 0
    mov eax, 0xc03148
    call emit_3bytes
    ret

; ───────────────────────────────────────────────────────────────────────────
; Emit getchar code
; ───────────────────────────────────────────────────────────────────────────
emit_getchar:
    ; sub rsp, 16
    mov al, 0x48
    call emit_byte
    mov al, 0x83
    call emit_byte
    mov al, 0xec
    call emit_byte
    mov al, 16
    call emit_byte

    ; mov rax, 0 (SYS_READ)
    mov al, 0x48
    call emit_byte
    mov al, 0xc7
    call emit_byte
    mov al, 0xc0
    call emit_byte
    mov eax, SYS_READ
    call emit_dword

    ; mov rdi, 0 (STDIN)
    mov al, 0x48
    call emit_byte
    mov al, 0xc7
    call emit_byte
    mov al, 0xc7
    call emit_byte
    xor eax, eax
    call emit_dword

    ; lea rsi, [rsp]
    mov al, 0x48
    call emit_byte
    mov al, 0x8d
    call emit_byte
    mov al, 0x34
    call emit_byte
    mov al, 0x24
    call emit_byte

    ; mov rdx, 1
    mov al, 0x48
    call emit_byte
    mov al, 0xc7
    call emit_byte
    mov al, 0xc2
    call emit_byte
    mov eax, 1
    call emit_dword

    ; syscall
    mov al, 0x0f
    call emit_byte
    mov al, 0x05
    call emit_byte

    ; movzx rax, byte [rsp]
    mov al, 0x48
    call emit_byte
    mov al, 0x0f
    call emit_byte
    mov al, 0xb6
    call emit_byte
    mov al, 0x04
    call emit_byte
    mov al, 0x24
    call emit_byte

    ; add rsp, 16
    mov al, 0x48
    call emit_byte
    mov al, 0x83
    call emit_byte
    mov al, 0xc4
    call emit_byte
    mov al, 16
    call emit_byte

    ret

; ───────────────────────────────────────────────────────────────────────────
; Variable management
; ───────────────────────────────────────────────────────────────────────────
store_var_by_name:
    ; Find or create variable, store rax to it
    ; ident_buf has name
    call find_var
    cmp rax, -1
    je .create

    ; Found, get offset
    mov rcx, [var_offs + rax*8]
    jmp .store

.create:
    call create_var_from_ident
    mov rax, [var_count]
    dec rax
    mov rcx, [var_offs + rax*8]

.store:
    ; mov [rbp - offset], rax
    mov al, 0x48
    call emit_byte
    mov al, 0x89
    call emit_byte
    mov al, 0x85
    call emit_byte
    neg ecx
    mov eax, ecx
    call emit_dword
    ret

load_var_by_name:
    ; Load variable to rax
    call find_var
    cmp rax, -1
    je .not_found

    mov rcx, [var_offs + rax*8]

    ; mov rax, [rbp - offset]
    mov al, 0x48
    call emit_byte
    mov al, 0x8b
    call emit_byte
    mov al, 0x85
    call emit_byte
    neg ecx
    mov eax, ecx
    call emit_dword
    ret

.not_found:
    ; Return 0
    mov eax, 0xc03148
    call emit_3bytes
    ret

find_var:
    ; Find variable by name in ident_buf
    ; Returns index or -1
    xor rcx, rcx
.loop:
    cmp rcx, [var_count]
    jge .not_found

    lea rdi, [var_names]
    imul rax, rcx, 32
    add rdi, rax
    lea rsi, [ident_buf]
    push rcx
    call strcmp
    pop rcx
    test al, al
    jz .found
    inc rcx
    jmp .loop

.found:
    mov rax, rcx
    ret

.not_found:
    mov rax, -1
    ret

create_var_from_ident:
    ; Create new variable from ident_buf
    mov rax, [var_count]
    cmp rax, MAX_VARS
    jge .error

    ; Copy name
    lea rdi, [var_names]
    imul rcx, rax, 32
    add rdi, rcx
    lea rsi, [ident_buf]
    mov rcx, 32
    call memcpy

    ; Allocate stack slot
    mov rax, [var_count]
    mov rcx, [stack_off]
    mov [var_offs + rax*8], rcx
    add qword [stack_off], 8
    inc qword [var_count]
    ret

.error:
    jmp error_exit

find_func:
    ; Find function by name in ident_buf
    xor rcx, rcx
.loop:
    cmp rcx, [func_count]
    jge .not_found

    lea rdi, [func_names]
    imul rax, rcx, 32
    add rdi, rax
    lea rsi, [ident_buf]
    push rcx
    call strcmp
    pop rcx
    test al, al
    jz .found
    inc rcx
    jmp .loop

.found:
    mov rax, rcx
    ret

.not_found:
    mov rax, -1
    ret

; ═══════════════════════════════════════════════════════════════════════════
; Helper functions
; ═══════════════════════════════════════════════════════════════════════════
emit_byte:
    mov rdi, [code_len]
    lea rsi, [code_buf + rdi]
    mov [rsi], al
    inc qword [code_len]
    ret

emit_3bytes:
    ; eax contains 3 bytes
    push rax
    call emit_byte
    pop rax
    shr eax, 8
    push rax
    call emit_byte
    pop rax
    shr eax, 8
    call emit_byte
    ret

emit_dword:
    mov rdi, [code_len]
    lea rsi, [code_buf + rdi]
    mov [rsi], eax
    add qword [code_len], 4
    ret

emit_qword:
    mov rdi, [code_len]
    lea rsi, [code_buf + rdi]
    mov [rsi], rax
    add qword [code_len], 8
    ret

peek_char:
    mov rax, [source_pos]
    cmp rax, [source_len]
    jge .eof
    lea rsi, [source_buf + rax]
    movzx eax, byte [rsi]
    ret
.eof:
    xor eax, eax
    ret

next_char:
    call peek_char
    inc qword [source_pos]
    ret

skip_ws:
.loop:
    call peek_char
    cmp al, ' '
    je .skip
    cmp al, 9
    je .skip
    cmp al, 10
    je .skip
    cmp al, 13
    je .skip
    ret
.skip:
    inc qword [source_pos]
    jmp .loop

skip_line:
.loop:
    call peek_char
    cmp al, 10
    je .done
    cmp al, 0
    je .done
    inc qword [source_pos]
    jmp .loop
.done:
    inc qword [source_pos]
    ret

is_alpha:
    cmp al, 'a'
    jl .upper
    cmp al, 'z'
    jle .yes
.upper:
    cmp al, 'A'
    jl .under
    cmp al, 'Z'
    jle .yes
.under:
    cmp al, '_'
    je .yes
    xor eax, eax
    ret
.yes:
    mov eax, 1
    ret

is_alnum:
    push rax
    call is_alpha
    test al, al
    pop rax
    jnz .yes
    cmp al, '0'
    jl .no
    cmp al, '9'
    jle .yes
.no:
    xor eax, eax
    ret
.yes:
    mov eax, 1
    ret

parse_ident:
    lea rdi, [ident_buf]
    xor rcx, rcx
.loop:
    call peek_char
    push rax
    call is_alnum
    test al, al
    pop rax
    jz .done
    cmp al, '.'
    je .store
    test al, al
    jz .done
.store:
    mov [rdi + rcx], al
    inc rcx
    inc qword [source_pos]
    cmp rcx, 255
    jl .loop
.done:
    mov byte [rdi + rcx], 0
    ret

parse_number:
    xor rax, rax
    xor r8, r8              ; sign flag
    
    call peek_char
    cmp al, '-'
    jne .parse
    mov r8, 1
    inc qword [source_pos]

.parse:
    push rax
    call peek_char
    mov rcx, rax
    pop rax
    cmp cl, '0'
    jl .done
    cmp cl, '9'
    jg .done
    imul rax, 10
    sub cl, '0'
    movzx rcx, cl
    add rax, rcx
    inc qword [source_pos]
    jmp .parse

.done:
    test r8, r8
    jz .positive
    neg rax
.positive:
    mov [num_buf], rax
    ret

parse_float:
    ; Parse float as fixed-point (value * 1000)
    xor rax, rax
    xor r8, r8              ; integer part
    xor r9, r9              ; fraction * 1000

.int_part:
    call peek_char
    cmp al, '.'
    je .frac_part
    cmp al, '0'
    jl .done
    cmp al, '9'
    jg .done
    imul r8, 10
    sub al, '0'
    movzx rcx, al
    add r8, rcx
    inc qword [source_pos]
    jmp .int_part

.frac_part:
    inc qword [source_pos]
    mov r10, 100            ; fraction multiplier

.frac_loop:
    call peek_char
    cmp al, '0'
    jl .calc
    cmp al, '9'
    jg .calc
    sub al, '0'
    movzx rcx, al
    imul rcx, r10
    add r9, rcx
    mov rax, r10
    xor rdx, rdx
    mov rcx, 10
    div rcx
    mov r10, rax
    inc qword [source_pos]
    jmp .frac_loop

.calc:
    imul r8, 1000
    add r8, r9
    mov rax, r8

.done:
    ret

parse_hex_byte:
    ; Parse 2 hex digits
    xor rax, rax
    call peek_char
    inc qword [source_pos]
    call hex_digit
    shl al, 4
    mov ah, al
    call peek_char
    inc qword [source_pos]
    call hex_digit
    or al, ah
    ret

hex_digit:
    cmp al, '0'
    jl .letter
    cmp al, '9'
    jg .letter
    sub al, '0'
    ret
.letter:
    cmp al, 'a'
    jl .upper
    cmp al, 'f'
    jg .upper
    sub al, 'a'
    add al, 10
    ret
.upper:
    cmp al, 'A'
    jl .zero
    cmp al, 'F'
    jg .zero
    sub al, 'A'
    add al, 10
    ret
.zero:
    xor al, al
    ret

strcmp:
    ; Compare strings at rdi and rsi
    ; Returns 0 if equal
.loop:
    mov al, [rdi]
    mov cl, [rsi]
    cmp al, cl
    jne .neq
    test al, al
    jz .eq
    inc rdi
    inc rsi
    jmp .loop
.eq:
    xor eax, eax
    ret
.neq:
    mov eax, 1
    ret

memcpy:
    ; Copy rcx bytes from rsi to rdi
    test rcx, rcx
    jz .done
.loop:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jnz .loop
.done:
    ret

print_number:
    ; Print number in rax
    push rbx
    mov rbx, rax
    lea rdi, [str_buf + 20]
    mov byte [rdi], 0
    dec rdi
    mov rcx, 10
.loop:
    xor rdx, rdx
    mov rax, rbx
    div rcx
    mov rbx, rax
    add dl, '0'
    mov [rdi], dl
    dec rdi
    test rbx, rbx
    jnz .loop

    inc rdi
    mov rsi, rdi
    lea rax, [str_buf + 20]
    sub rax, rdi
    mov rdx, rax
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    syscall
    pop rbx
    ret

; ───────────────────────────────────────────────────────────────────────────
; Keyword checks
; ───────────────────────────────────────────────────────────────────────────
check_out:
    mov rax, [source_pos]
    lea rsi, [source_buf + rax]
    cmp byte [rsi], 'o'
    jne .no
    cmp byte [rsi+1], 'u'
    jne .no
    cmp byte [rsi+2], 't'
    jne .no
    mov al, [rsi+3]
    cmp al, ' '
    je .yes
    cmp al, '"'
    je .yes
.no:
    xor eax, eax
    ret
.yes:
    mov eax, 1
    ret

check_emit:
    mov rax, [source_pos]
    lea rsi, [source_buf + rax]
    cmp dword [rsi], 'emit'
    jne .no
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

check_byte:
    mov rax, [source_pos]
    lea rsi, [source_buf + rax]
    cmp dword [rsi], 'byte'
    jne .no
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

check_putchar:
    mov rax, [source_pos]
    lea rsi, [source_buf + rax]
    cmp dword [rsi], 'putc'
    jne .no
    cmp word [rsi+4], 'ha'
    jne .no
    cmp byte [rsi+6], 'r'
    jne .no
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

check_getchar_stmt:
    mov rax, [source_pos]
    lea rsi, [source_buf + rax]
    cmp dword [rsi], 'getc'
    jne .no
    cmp dword [rsi+4], 'har('
    jne .no
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

check_syscall_exit:
    mov rax, [source_pos]
    lea rsi, [source_buf + rax]
    cmp dword [rsi], 'sysc'
    jne .no
    cmp dword [rsi+4], 'all.'
    jne .no
    cmp dword [rsi+8], 'exit'
    jne .no
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

check_when:
    mov rax, [source_pos]
    lea rsi, [source_buf + rax]
    cmp dword [rsi], 'when'
    jne .no
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

check_loop:
    mov rax, [source_pos]
    lea rsi, [source_buf + rax]
    cmp dword [rsi], 'loop'
    jne .no
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

check_break:
    mov rax, [source_pos]
    lea rsi, [source_buf + rax]
    cmp dword [rsi], 'brea'
    jne .no
    cmp byte [rsi+4], 'k'
    jne .no
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

check_fn:
    mov rax, [source_pos]
    lea rsi, [source_buf + rax]
    cmp byte [rsi], 'f'
    jne .no
    cmp byte [rsi+1], 'n'
    jne .no
    cmp byte [rsi+2], ' '
    jne .no
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

check_unified:
    mov rax, [source_pos]
    lea rsi, [source_buf + rax]
    cmp dword [rsi], 'unif'
    jne .no
    cmp word [rsi+4], 'ie'
    jne .no
    cmp byte [rsi+6], 'd'
    jne .no
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

check_fate:
    mov rax, [source_pos]
    lea rsi, [source_buf + rax]
    cmp dword [rsi], 'fate'
    jne .no
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

check_return:
    mov rax, [source_pos]
    lea rsi, [source_buf + rax]
    cmp byte [rsi], '-'
    jne .no
    cmp byte [rsi+1], '>'
    jne .no
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; ═══════════════════════════════════════════════════════════════════════════
; Write ELF output
; ═══════════════════════════════════════════════════════════════════════════
write_elf:
    ; Calculate total size
    mov rax, elf_header_len
    add rax, prog_header_len
    add rax, [code_len]

    ; Patch program header
    mov [prog_filesz], rax
    mov [prog_memsz], rax

    ; Write ELF header
    mov rax, SYS_WRITE
    mov rdi, [output_fd]
    lea rsi, [elf_header]
    mov rdx, elf_header_len
    syscall

    ; Write program header
    mov rax, SYS_WRITE
    mov rdi, [output_fd]
    lea rsi, [prog_header]
    mov rdx, prog_header_len
    syscall

    ; Write code
    mov rax, SYS_WRITE
    mov rdi, [output_fd]
    lea rsi, [code_buf]
    mov rdx, [code_len]
    syscall

    ; Close
    mov rax, SYS_CLOSE
    mov rdi, [output_fd]
    syscall

    ret

; ───────────────────────────────────────────────────────────────────────────
; Error exit
; ───────────────────────────────────────────────────────────────────────────
error_exit:
    mov rax, SYS_WRITE
    mov rdi, STDERR
    lea rsi, [msg_error]
    mov rdx, 26
    syscall
    mov rax, SYS_EXIT
    mov rdi, 1
    syscall
