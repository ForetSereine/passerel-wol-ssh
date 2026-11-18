; ============================================================
;  wol.asm : sends a Wake-on-LAN magic packet (x86-64 Linux)
;
;  Usage :  wol <MAC> [broadcast_ip] [port]
;           MAC          AA:BB:CC:DD:EE:FF  (or AA-BB-CC-DD-EE-FF)
;           broadcast_ip default 255.255.255.255 (e.g. 192.168.1.255)
;           port         default 9
;
;  Build :  nasm -f elf64 wol.asm -o wol.o && ld -o wol wol.o
;  No root privileges needed (SO_BROADCAST is enough).
;
;  This program ONLY sends the wake-up packet. Access control
;  (allowlist, SSH keys) is enforced server-side by iptables
;  and sshd: a client-side check could be bypassed.
;
;  Exit codes : 0 ok, 1 usage, 2 MAC, 3 IP, 4 port,
;               5 socket, 6 send
; ============================================================

%define SYS_write       1
%define SYS_close       3
%define SYS_socket      41
%define SYS_sendto      44
%define SYS_setsockopt  54
%define SYS_exit        60

%define AF_INET         2
%define SOCK_DGRAM      2
%define SOL_SOCKET      1
%define SO_BROADCAST    6

%define STDOUT          1
%define STDERR          2

%define PKT_LEN         102          ; 6 x 0xFF + 16 x MAC (6 bytes)

; Writes a message to stderr, then exits with the given code
%macro FAIL 2
    mov  eax, SYS_write
    mov  edi, STDERR
    lea  rsi, [%1]
    mov  edx, %{1}_len
    syscall
    mov  eax, SYS_exit
    mov  edi, %2
    syscall
%endmacro

section .rodata
    msg_ok:        db "Wake-on-LAN packet sent.", 10
    msg_ok_len     equ $ - msg_ok
    msg_usage:     db "Usage: wol <MAC> [broadcast_ip] [port]", 10
    msg_usage_len  equ $ - msg_usage
    msg_mac:       db "ERROR: invalid MAC address (expected AA:BB:CC:DD:EE:FF).", 10
    msg_mac_len    equ $ - msg_mac
    msg_ip:        db "ERROR: invalid IPv4 address.", 10
    msg_ip_len     equ $ - msg_ip
    msg_port:      db "ERROR: invalid port (1-65535).", 10
    msg_port_len   equ $ - msg_port
    msg_sock:      db "ERROR: cannot create or configure the socket.", 10
    msg_sock_len   equ $ - msg_sock
    msg_send:      db "ERROR: failed to send the packet.", 10
    msg_send_len   equ $ - msg_send

    one:           dd 1                  ; value for SO_BROADCAST

section .bss
    mac:           resb 6                ; binary MAC
    packet:        resb PKT_LEN          ; magic packet (102 bytes)
    addr:          resb 16               ; struct sockaddr_in

section .text
    global _start

; ------------------------------------------------------------
;  _start : on entry, [rsp] = argc, [rsp+8] = argv[0], ...
; ------------------------------------------------------------
_start:
    mov  r12, [rsp]                  ; argc
    cmp  r12, 2
    jb   .usage
    cmp  r12, 4
    ja   .usage

    ; default sockaddr_in : AF_INET, port 9, 255.255.255.255
    mov  word  [addr],     AF_INET
    mov  word  [addr + 2], 0x0900    ; htons(9) : bytes 00 09
    mov  dword [addr + 4], 0xFFFFFFFF
    mov  qword [addr + 8], 0         ; sin_zero

    ; argv[1] : MAC address
    mov  rdi, [rsp + 16]
    call parse_mac
    test eax, eax
    jnz  .bad_mac

    ; argv[2] : broadcast address (optional)
    cmp  r12, 3
    jb   .build
    mov  rdi, [rsp + 24]
    call parse_ipv4
    test eax, eax
    jnz  .bad_ip
    mov  [addr + 4], edx             ; already in network byte order

    ; argv[3] : port (optional)
    cmp  r12, 4
    jb   .build
    mov  rdi, [rsp + 32]
    call parse_port
    test eax, eax
    jnz  .bad_port
    xchg dl, dh                      ; htons
    mov  [addr + 2], dx

.build:
    ; 6 x 0xFF
    lea  rdi, [packet]
    mov  dword [rdi], 0xFFFFFFFF
    mov  word  [rdi + 4], 0xFFFF
    add  rdi, 6
    ; 16 x MAC
    mov  ecx, 16
.copy_mac:
    mov  eax, [mac]
    mov  [rdi], eax
    mov  ax, [mac + 4]
    mov  [rdi + 4], ax
    add  rdi, 6
    dec  ecx
    jnz  .copy_mac

    ; socket(AF_INET, SOCK_DGRAM, 0)
    mov  eax, SYS_socket
    mov  edi, AF_INET
    mov  esi, SOCK_DGRAM
    xor  edx, edx
    syscall
    test rax, rax
    js   .sock_err
    mov  r13, rax                    ; fd

    ; setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, 4)
    mov  eax, SYS_setsockopt
    mov  rdi, r13
    mov  esi, SOL_SOCKET
    mov  edx, SO_BROADCAST
    lea  r10, [one]
    mov  r8d, 4
    syscall
    test rax, rax
    js   .sock_err_close

    ; sendto(fd, packet, 102, 0, &addr, 16)
    ; syscall convention : rdi, rsi, rdx, r10, r8, r9
    mov  eax, SYS_sendto
    mov  rdi, r13
    lea  rsi, [packet]
    mov  edx, PKT_LEN
    xor  r10d, r10d                  ; flags = 0
    lea  r8, [addr]                  ; dest_addr
    mov  r9d, 16                     ; addrlen
    syscall
    mov  r14, rax                    ; sendto result

    ; close(fd)
    mov  eax, SYS_close
    mov  rdi, r13
    syscall

    cmp  r14, PKT_LEN
    jne  .send_err

    mov  eax, SYS_write
    mov  edi, STDOUT
    lea  rsi, [msg_ok]
    mov  edx, msg_ok_len
    syscall
    mov  eax, SYS_exit
    xor  edi, edi
    syscall

.usage:     FAIL msg_usage, 1
.bad_mac:   FAIL msg_mac,   2
.bad_ip:    FAIL msg_ip,    3
.bad_port:  FAIL msg_port,  4
.sock_err_close:
    mov  eax, SYS_close
    mov  rdi, r13
    syscall
.sock_err:  FAIL msg_sock,  5
.send_err:  FAIL msg_send,  6

; ------------------------------------------------------------
;  hexval : al = character -> al = 0..15, CF=1 if not hex
; ------------------------------------------------------------
hexval:
    cmp  al, '0'
    jb   .bad
    cmp  al, '9'
    jbe  .digit
    or   al, 0x20                    ; lowercase
    cmp  al, 'a'
    jb   .bad
    cmp  al, 'f'
    ja   .bad
    sub  al, 'a' - 10
    clc
    ret
.digit:
    sub  al, '0'
    clc
    ret
.bad:
    stc
    ret

; ------------------------------------------------------------
;  parse_mac : rdi = string "AA:BB:CC:DD:EE:FF"
;  Fills [mac]. Returns eax = 0 if ok, 1 otherwise.
;  Requires exactly 6 hex bytes separated by ':' or '-'.
; ------------------------------------------------------------
parse_mac:
    xor  ecx, ecx                    ; byte index
.next:
    movzx eax, byte [rdi]
    call hexval
    jc   .err
    mov  dl, al
    shl  dl, 4
    movzx eax, byte [rdi + 1]
    call hexval
    jc   .err
    or   dl, al
    mov  [mac + rcx], dl
    add  rdi, 2
    inc  ecx
    cmp  ecx, 6
    je   .end
    mov  al, [rdi]
    cmp  al, ':'
    je   .sep
    cmp  al, '-'
    jne  .err
.sep:
    inc  rdi
    jmp  .next
.end:
    cmp  byte [rdi], 0               ; nothing after the 6th byte
    jne  .err
    xor  eax, eax
    ret
.err:
    mov  eax, 1
    ret

; ------------------------------------------------------------
;  parse_ipv4 : rdi = string "a.b.c.d"
;  Returns eax = 0 if ok (edx = IP in network order), 1 otherwise.
;  Requires 4 decimal octets of 1 to 3 digits, each <= 255.
; ------------------------------------------------------------
parse_ipv4:
    xor  r8d, r8d                    ; IP being built
    xor  ecx, ecx                    ; shift : 0, 8, 16, 24
.octet:
    xor  eax, eax                    ; octet value
    xor  r9d, r9d                    ; digit count
.digit:
    movzx r10d, byte [rdi]
    sub  r10d, '0'
    cmp  r10d, 9
    ja   .end_digits                 ; not a digit
    imul eax, eax, 10
    add  eax, r10d
    inc  r9d
    cmp  r9d, 3
    ja   .err
    cmp  eax, 255
    ja   .err
    inc  rdi
    jmp  .digit
.end_digits:
    test r9d, r9d
    jz   .err
    shl  eax, cl                     ; 1st octet in low byte = network order
    or   r8d, eax
    add  ecx, 8
    movzx r10d, byte [rdi]
    cmp  ecx, 32
    je   .last
    cmp  r10b, '.'
    jne  .err
    inc  rdi
    jmp  .octet
.last:
    test r10b, r10b                  ; end of string required
    jnz  .err
    mov  edx, r8d
    xor  eax, eax
    ret
.err:
    mov  eax, 1
    ret

; ------------------------------------------------------------
;  parse_port : rdi = decimal string
;  Returns eax = 0 if ok (edx = port, host order), 1 otherwise.
; ------------------------------------------------------------
parse_port:
    xor  eax, eax
    xor  r9d, r9d
.digit:
    movzx r10d, byte [rdi]
    test r10d, r10d
    jz   .end
    sub  r10d, '0'
    cmp  r10d, 9
    ja   .err
    imul eax, eax, 10
    add  eax, r10d
    inc  r9d
    cmp  r9d, 5
    ja   .err
    cmp  eax, 65535
    ja   .err
    inc  rdi
    jmp  .digit
.end:
    test eax, eax                    ; port 0 or empty string rejected
    jz   .err
    mov  edx, eax
    xor  eax, eax
    ret
.err:
    mov  eax, 1
    ret
