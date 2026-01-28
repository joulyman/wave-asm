; ═══════════════════════════════════════════════════════════════════════════
; Wave-ASM Alpha Test 1.0 - Rule-Driven Compiler (x86-64 Assembly)
; 
; A minimal Wave compiler written in pure x86-64 assembly.
; Compiles Wave source to ELF64 executables.
;
; Features:
;   - Unified Field (i, e, r) - three-parameter rule mapping
;   - Variables, conditions, loops, functions
;   - x86-64 ELF output
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
SYS_LSEEK   equ 8
SYS_MMAP    equ 9
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
MAX_CODE    equ 1048576     ; 1MB code
MAX_VARS    equ 1024
MAX_FUNCS   equ 256
MAX_LABELS  equ 2048
BASE_ADDR   equ 0x400000    ; ELF load address

section .data
    ; Banner
    banner: db 0xF0, 0x9F, 0x8C, 0x8A, " Wave-ASM 1.0-alpha", 10
            db "   Rule-Driven Compiler | Rogue Intelligence LNC.", 10, 10, 0
    banner_len equ $ - banner

    ; Messages
    msg_usage:   db "Usage: wavec <input.wave> -o <output>", 10, 0
    msg_reading: db "Compiling...", 10, 0
    msg_done:    db "Done.", 10, 0
    msg_error:   db "Error", 10, 0

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
        dd 5                     ; Flags: R+X
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

section .bss
    source_buf: resb MAX_SOURCE
    source_len: resq 1
    source_pos: resq 1

    code_buf:   resb MAX_CODE
    code_len:   resq 1

    ; Variables: name(64) + offset(8)
    var_names:  resb MAX_VARS * 64
    var_offs:   resq MAX_VARS
    var_count:  resq 1

    ; Functions: name(64) + addr(8) + params(8)
    func_names: resb MAX_FUNCS * 64
    func_addrs: resq MAX_FUNCS
    func_params:resq MAX_FUNCS
    func_count: resq 1

    ; Labels for fixups
    label_addrs:resq MAX_LABELS
    label_count:resq 1

    ; Temp buffers
    ident_buf:  resb 256
    num_buf:    resq 1
    output_fd:  resq 1
    input_fd:   resq 1

    ; Stack frame offset
    stack_off:  resq 1

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
    call create_output

    ; Read source
    call read_source

    ; Compile
    call compile

    ; Write ELF
    call write_elf

    ; Done message
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    lea rsi, [msg_done]
    mov rdx, 6
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
    ; rsi = filename
    mov rax, SYS_OPEN
    mov rdi, rsi
    mov rsi, O_RDONLY
    xor rdx, rdx
    syscall
    cmp rax, 0
    jl .error
    mov [input_fd], rax
    ret
.error:
    jmp error_exit

create_output:
    ; rsi = filename
    mov rax, SYS_OPEN
    mov rdi, rsi
    mov rsi, O_WRONLY | O_CREAT | O_TRUNC
    mov rdx, 0o755
    syscall
    cmp rax, 0
    jl .error
    mov [output_fd], rax
    ret
.error:
    jmp error_exit

read_source:
    mov rax, SYS_READ
    mov rdi, [input_fd]
    lea rsi, [source_buf]
    mov rdx, MAX_SOURCE
    syscall
    cmp rax, 0
    jl .error
    mov [source_len], rax

    ; Close input
    mov rax, SYS_CLOSE
    mov rdi, [input_fd]
    syscall
    ret
.error:
    jmp error_exit

; ═══════════════════════════════════════════════════════════════════════════
; Compiler
; ═══════════════════════════════════════════════════════════════════════════
compile:
    ; Initialize
    xor rax, rax
    mov [source_pos], rax
    mov [code_len], rax
    mov [var_count], rax
    mov [func_count], rax
    mov [stack_off], rax

    ; Generate prologue (setup stack frame)
    call emit_prologue

    ; Parse and compile statements
.loop:
    call skip_ws
    mov rax, [source_pos]
    cmp rax, [source_len]
    jge .done

    call compile_statement
    jmp .loop

.done:
    ret

; ───────────────────────────────────────────────────────────────────────────
; Emit prologue
; ───────────────────────────────────────────────────────────────────────────
emit_prologue:
    ; push rbp
    mov al, 0x55
    call emit_byte
    ; mov rbp, rsp
    mov al, 0x48
    call emit_byte
    mov al, 0x89
    call emit_byte
    mov al, 0xe5
    call emit_byte
    ; sub rsp, 0x1000 (reserve stack)
    mov al, 0x48
    call emit_byte
    mov al, 0x81
    call emit_byte
    mov al, 0xec
    call emit_byte
    mov eax, 0x1000
    call emit_dword
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile statement
; ───────────────────────────────────────────────────────────────────────────
compile_statement:
    call skip_ws
    call peek_char
    
    ; Check for comment
    cmp al, '#'
    je .skip_comment

    ; Check for 'out'
    call check_out
    test al, al
    jnz .compile_out

    ; Check for 'syscall.exit'
    call check_syscall_exit
    test al, al
    jnz .compile_exit

    ; Check for 'when'
    call check_when
    test al, al
    jnz .compile_when

    ; Check for 'loop'
    call check_loop
    test al, al
    jnz .compile_loop

    ; Check for 'break'
    call check_break
    test al, al
    jnz .compile_break

    ; Check for 'fn'
    call check_fn
    test al, al
    jnz .compile_fn

    ; Check for 'unified'
    call check_unified
    test al, al
    jnz .compile_unified

    ; Check for identifier (variable or function call)
    call peek_char
    call is_alpha
    test al, al
    jz .skip_line

    ; Parse identifier
    call parse_ident

    call skip_ws
    call peek_char
    
    ; Check for '=' (assignment)
    cmp al, '='
    je .compile_assign

    ; Check for '(' (function call)
    cmp al, '('
    je .compile_call

    jmp .skip_line

.skip_comment:
    call skip_line
    ret

.compile_out:
    call compile_out
    ret

.compile_exit:
    call compile_exit
    ret

.compile_when:
    call compile_when
    ret

.compile_loop:
    call compile_loop
    ret

.compile_break:
    call compile_break
    ret

.compile_fn:
    call compile_fn
    ret

.compile_unified:
    call compile_unified
    ret

.compile_assign:
    call next_char       ; consume '='
    call skip_ws
    call compile_expr
    ; Store result (rax) to variable
    call store_var
    ret

.compile_call:
    call compile_call
    ret

.skip_line:
    call skip_line
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile 'out "string"'
; ───────────────────────────────────────────────────────────────────────────
compile_out:
    ; Skip 'out'
    add qword [source_pos], 3
    call skip_ws

    ; Expect string
    call next_char
    cmp al, '"'
    jne .error

    ; Get string start
    mov rsi, [source_pos]
    lea rsi, [source_buf + rsi]
    xor rcx, rcx        ; string length

.count_len:
    mov al, [rsi + rcx]
    cmp al, '"'
    je .found_end
    cmp al, 0
    je .error
    inc rcx
    jmp .count_len

.found_end:
    ; rcx = length, rsi = string start
    push rcx
    push rsi

    ; Generate: jmp over_string
    mov al, 0xeb        ; jmp rel8
    call emit_byte
    mov rax, rcx
    add rax, 1          ; +1 for the length byte itself
    call emit_byte

    ; Emit string data
    pop rsi
    pop rcx
    push rcx
    mov rdx, rcx
.emit_str:
    test rdx, rdx
    jz .emit_str_done
    mov al, [rsi]
    ; Handle escape sequences
    cmp al, '\'
    jne .emit_normal
    inc rsi
    dec rdx
    mov al, [rsi]
    cmp al, 'n'
    jne .not_newline
    mov al, 10
    jmp .emit_normal
.not_newline:
    cmp al, 't'
    jne .emit_normal
    mov al, 9
.emit_normal:
    call emit_byte
    inc rsi
    dec rdx
    jmp .emit_str

.emit_str_done:
    pop rcx             ; string length

    ; Generate write syscall:
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

    ; lea rsi, [rip - offset]
    mov al, 0x48
    call emit_byte
    mov al, 0x8d
    call emit_byte
    mov al, 0x35
    call emit_byte
    ; Calculate offset: -(19 + strlen)
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

    ; Skip past closing quote
    mov rax, [source_pos]
    add rax, rcx
    inc rax             ; skip "
    mov [source_pos], rax

    ret

.error:
    jmp error_exit

; ───────────────────────────────────────────────────────────────────────────
; Compile syscall.exit(n)
; ───────────────────────────────────────────────────────────────────────────
compile_exit:
    ; Skip 'syscall.exit'
    add qword [source_pos], 12
    call skip_ws

    ; Expect '('
    call next_char
    cmp al, '('
    jne .error

    call skip_ws
    call compile_expr    ; exit code in rax

    ; Expect ')'
    call skip_ws
    call next_char
    cmp al, ')'
    jne .error

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

.error:
    jmp error_exit

; ───────────────────────────────────────────────────────────────────────────
; Compile expression (result in rax)
; ───────────────────────────────────────────────────────────────────────────
compile_expr:
    call skip_ws
    call compile_term

    ; Check for operators
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
    mov al, 0x48
    call emit_byte
    mov al, 0x01
    call emit_byte
    mov al, 0xc8
    call emit_byte
    jmp .check_op

.sub:
    call next_char
    ; push rax
    mov al, 0x50
    call emit_byte
    call compile_term
    ; mov rcx, rax
    mov al, 0x48
    call emit_byte
    mov al, 0x89
    call emit_byte
    mov al, 0xc1
    call emit_byte
    ; pop rax
    mov al, 0x58
    call emit_byte
    ; sub rax, rcx
    mov al, 0x48
    call emit_byte
    mov al, 0x29
    call emit_byte
    mov al, 0xc8
    call emit_byte
    jmp .check_op

.mul:
    call next_char
    ; push rax
    mov al, 0x50
    call emit_byte
    call compile_term
    ; pop rcx
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
    ; push rax
    mov al, 0x50
    call emit_byte
    call compile_term
    ; mov rcx, rax
    mov al, 0x48
    call emit_byte
    mov al, 0x89
    call emit_byte
    mov al, 0xc1
    call emit_byte
    ; pop rax
    mov al, 0x58
    call emit_byte
    ; xor rdx, rdx
    mov al, 0x48
    call emit_byte
    mov al, 0x31
    call emit_byte
    mov al, 0xd2
    call emit_byte
    ; idiv rcx
    mov al, 0x48
    call emit_byte
    mov al, 0xf7
    call emit_byte
    mov al, 0xf9
    call emit_byte
    jmp .check_op

.check_eq:
    ; Check for ==
    mov rax, [source_pos]
    inc rax
    lea rsi, [source_buf + rax]
    cmp byte [rsi], '='
    jne .done
    add qword [source_pos], 2
    call compile_comparison
    mov bl, 0x94        ; sete
    call emit_setcc
    jmp .check_op

.check_neq:
    ; Check for !=
    mov rax, [source_pos]
    inc rax
    lea rsi, [source_buf + rax]
    cmp byte [rsi], '='
    jne .done
    add qword [source_pos], 2
    call compile_comparison
    mov bl, 0x95        ; setne
    call emit_setcc
    jmp .check_op

.check_gt:
    call next_char
    call peek_char
    cmp al, '='
    je .gte
    call compile_comparison
    mov bl, 0x9f        ; setg
    call emit_setcc
    jmp .check_op
.gte:
    call next_char
    call compile_comparison
    mov bl, 0x9d        ; setge
    call emit_setcc
    jmp .check_op

.check_lt:
    call next_char
    call peek_char
    cmp al, '='
    je .lte
    call compile_comparison
    mov bl, 0x9c        ; setl
    call emit_setcc
    jmp .check_op
.lte:
    call next_char
    call compile_comparison
    mov bl, 0x9e        ; setle
    call emit_setcc
    jmp .check_op

.done:
    ret

compile_comparison:
    ; push rax
    mov al, 0x50
    call emit_byte
    call compile_term
    ; pop rcx
    mov al, 0x59
    call emit_byte
    ; cmp rcx, rax
    mov al, 0x48
    call emit_byte
    mov al, 0x39
    call emit_byte
    mov al, 0xc1
    call emit_byte
    ret

emit_setcc:
    ; setXX al (bl = opcode)
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
; Compile term (number, variable, or function call)
; ───────────────────────────────────────────────────────────────────────────
compile_term:
    call skip_ws
    call peek_char

    ; Check for number
    call is_digit
    test al, al
    jnz .number

    ; Check for identifier
    call peek_char
    call is_alpha
    test al, al
    jnz .ident

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

.ident:
    call parse_ident
    call skip_ws
    call peek_char
    cmp al, '('
    je .func_call

    ; Load variable
    call load_var
    ret

.func_call:
    call compile_call
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile 'when condition { ... }'
; ───────────────────────────────────────────────────────────────────────────
compile_when:
    add qword [source_pos], 4
    call skip_ws
    call compile_expr

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
    push rax            ; save fixup location
    xor eax, eax
    call emit_dword

    ; Skip to '{'
    call skip_ws
    call next_char      ; consume '{'

    ; Compile body
.body_loop:
    call skip_ws
    call peek_char
    cmp al, '}'
    je .body_done
    cmp al, 0
    je .error
    call compile_statement
    jmp .body_loop

.body_done:
    call next_char      ; consume '}'

    ; Patch jump
    pop rax             ; fixup location
    mov rcx, [code_len]
    sub rcx, rax
    sub rcx, 4          ; adjust for offset size
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
    call next_char      ; consume '{'

    ; Save loop start
    mov rax, [code_len]
    push rax

    ; Push break target (will patch later)
    push qword 0        ; placeholder for break fixup list

.body_loop:
    call skip_ws
    call peek_char
    cmp al, '}'
    je .body_done
    cmp al, 0
    je .error
    call compile_statement
    jmp .body_loop

.body_done:
    call next_char      ; consume '}'

    ; jmp back to start
    mov al, 0xe9
    call emit_byte
    pop rcx             ; break fixup (ignore for now)
    pop rax             ; loop start
    mov rcx, [code_len]
    sub rax, rcx
    sub rax, 4
    call emit_dword

    ret

.error:
    jmp error_exit

; ───────────────────────────────────────────────────────────────────────────
; Compile 'break'
; ───────────────────────────────────────────────────────────────────────────
compile_break:
    add qword [source_pos], 5
    ; For simplicity, emit a far jump that will need manual fixup
    ; In production, would maintain a fixup list
    ; jmp +0 (will be patched by loop end)
    mov al, 0xe9
    call emit_byte
    xor eax, eax
    call emit_dword
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile 'fn name params { ... }'
; ───────────────────────────────────────────────────────────────────────────
compile_fn:
    add qword [source_pos], 2
    call skip_ws

    ; Get function name
    call parse_ident

    ; Store function address
    mov rax, [func_count]
    lea rdi, [func_names]
    imul rcx, rax, 64
    add rdi, rcx
    lea rsi, [ident_buf]
    mov rcx, 64
    rep movsb

    mov rax, [func_count]
    lea rdi, [func_addrs]
    mov rcx, [code_len]
    mov [rdi + rax*8], rcx

    inc qword [func_count]

    ; Skip to '{'
.skip_params:
    call skip_ws
    call peek_char
    cmp al, '{'
    je .found_brace
    call next_char
    jmp .skip_params

.found_brace:
    call next_char      ; consume '{'

    ; Emit function prologue
    mov al, 0x55        ; push rbp
    call emit_byte
    mov al, 0x48        ; mov rbp, rsp
    call emit_byte
    mov al, 0x89
    call emit_byte
    mov al, 0xe5
    call emit_byte

    ; Compile body
.body_loop:
    call skip_ws
    call peek_char
    cmp al, '}'
    je .body_done
    cmp al, 0
    je .error

    ; Check for '->' return
    cmp al, '-'
    jne .not_return
    mov rax, [source_pos]
    inc rax
    lea rsi, [source_buf + rax]
    cmp byte [rsi], '>'
    jne .not_return
    add qword [source_pos], 2
    call skip_ws
    call compile_expr
    ; Emit return
    mov al, 0x5d        ; pop rbp
    call emit_byte
    mov al, 0xc3        ; ret
    call emit_byte
    jmp .body_loop

.not_return:
    call compile_statement
    jmp .body_loop

.body_done:
    call next_char      ; consume '}'

    ; Emit epilogue
    mov al, 0x5d        ; pop rbp
    call emit_byte
    mov al, 0xc3        ; ret
    call emit_byte

    ret

.error:
    jmp error_exit

; ───────────────────────────────────────────────────────────────────────────
; Compile function call
; ───────────────────────────────────────────────────────────────────────────
compile_call:
    ; ident_buf has function name
    call next_char      ; consume '('

    ; For simplicity, skip args for now
.skip_args:
    call skip_ws
    call peek_char
    cmp al, ')'
    je .call_done
    call next_char
    jmp .skip_args

.call_done:
    call next_char      ; consume ')'

    ; Find function
    xor rcx, rcx
.find_func:
    cmp rcx, [func_count]
    jge .not_found

    lea rdi, [func_names]
    imul rax, rcx, 64
    add rdi, rax
    lea rsi, [ident_buf]
    push rcx
    call strcmp
    pop rcx
    test al, al
    jz .found
    inc rcx
    jmp .find_func

.found:
    ; Get address
    lea rdi, [func_addrs]
    mov rax, [rdi + rcx*8]

    ; call rel32
    mov bl, 0xe8
    mov al, bl
    call emit_byte
    mov rcx, [code_len]
    sub rax, rcx
    sub rax, 4
    call emit_dword
    ret

.not_found:
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile 'unified { i: v, e: v, r: v }'
; ───────────────────────────────────────────────────────────────────────────
compile_unified:
    add qword [source_pos], 7
    ; Skip to '}'
.skip:
    call skip_ws
    call peek_char
    cmp al, '}'
    je .done
    cmp al, 0
    je .done
    call next_char
    jmp .skip
.done:
    call next_char      ; consume '}'
    ret

; ───────────────────────────────────────────────────────────────────────────
; Variable management
; ───────────────────────────────────────────────────────────────────────────
store_var:
    ; Find or create variable
    xor rcx, rcx
.find:
    cmp rcx, [var_count]
    jge .create

    lea rdi, [var_names]
    imul rax, rcx, 64
    add rdi, rax
    lea rsi, [ident_buf]
    push rcx
    call strcmp
    pop rcx
    test al, al
    jz .found
    inc rcx
    jmp .find

.create:
    ; New variable
    mov rax, [var_count]
    lea rdi, [var_names]
    imul rcx, rax, 64
    add rdi, rcx
    lea rsi, [ident_buf]
    mov rcx, 64
    rep movsb

    ; Allocate stack slot
    mov rax, [var_count]
    mov rcx, [stack_off]
    add rcx, 8
    mov [stack_off], rcx
    lea rdi, [var_offs]
    mov [rdi + rax*8], rcx

    inc qword [var_count]
    mov rcx, [stack_off]
    jmp .store

.found:
    lea rdi, [var_offs]
    mov rcx, [rdi + rcx*8]

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

load_var:
    ; Find variable
    xor rcx, rcx
.find:
    cmp rcx, [var_count]
    jge .not_found

    lea rdi, [var_names]
    imul rax, rcx, 64
    add rdi, rax
    lea rsi, [ident_buf]
    push rcx
    call strcmp
    pop rcx
    test al, al
    jz .found
    inc rcx
    jmp .find

.found:
    lea rdi, [var_offs]
    mov rcx, [rdi + rcx*8]

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
    mov al, 0x48
    call emit_byte
    mov al, 0x31
    call emit_byte
    mov al, 0xc0
    call emit_byte
    ret

; ───────────────────────────────────────────────────────────────────────────
; Helper functions
; ───────────────────────────────────────────────────────────────────────────
emit_byte:
    mov rdi, [code_len]
    lea rsi, [code_buf + rdi]
    mov [rsi], al
    inc qword [code_len]
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
    cmp al, 9       ; tab
    je .skip
    cmp al, 10      ; newline
    je .skip
    cmp al, 13      ; CR
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
    jl .check_upper
    cmp al, 'z'
    jle .yes
.check_upper:
    cmp al, 'A'
    jl .check_under
    cmp al, 'Z'
    jle .yes
.check_under:
    cmp al, '_'
    je .yes
    xor eax, eax
    ret
.yes:
    mov eax, 1
    ret

is_digit:
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

is_alnum:
    push rax
    call is_alpha
    test al, al
    pop rax
    jnz .yes
    call is_digit
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
.loop:
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
    jmp .loop
.done:
    mov [num_buf], rax
    ret

strcmp:
    ; rdi = str1, rsi = str2
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
    cmp byte [rsi+3], ' '
    jne .check_quote
    mov eax, 1
    ret
.check_quote:
    cmp byte [rsi+3], '"'
    jne .no
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

check_syscall_exit:
    mov rax, [source_pos]
    lea rsi, [source_buf + rax]
    ; Check "syscall.exit"
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

; ═══════════════════════════════════════════════════════════════════════════
; Write ELF output
; ═══════════════════════════════════════════════════════════════════════════
write_elf:
    ; Calculate total size
    mov rax, elf_header_len
    add rax, prog_header_len
    add rax, [code_len]

    ; Patch program header sizes
    mov rcx, rax
    mov [prog_filesz], rcx
    mov [prog_memsz], rcx

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

    ; Close output
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
    mov rdx, 6
    syscall
    mov rax, SYS_EXIT
    mov rdi, 1
    syscall
