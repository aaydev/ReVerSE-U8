        DEVICE ZXSPECTRUM48

; PCB ReVerSE U8EP3C POST

; -------------------------------------------------------------------------------
; -- N80v1 CPU Memory Map
; -------------------------------------------------------------------------------
; -- A15 A14 A13
; --  0   0   x   0000-3FFF (16384) RAM
; --                ( 4800) Text buffer (char, attr, char...)
;
; -- #BF W/R: txt0_addr1 Low byte of text video buffer start address
; -- #7F W/R: txt0_addr2 High byte of text video buffer start address
; -------------------------------------------------------------------------------
; Constants
; -------------------------------------------------------------------------------

BUFFER          EQU #2000       ; Start address of text buffer
COLS            EQU 80
ROWS            EQU 30
BYTES_PER_ROW   EQU (COLS * 2)
TEXT_BYTES      EQU (COLS * ROWS * 2)

VARIABLES       EQU #003A       ; Start address of variables
print_color     EQU (VARIABLES + 0)

CTRL_SET_COLOR  EQU #01

; I/O ports
port_addr_low   EQU #FE         ; %11111110
port_addr_hi    EQU #FD         ; %11111101
port_data       EQU #FB         ; %11111011
port_status     EQU %11110111   ; IOFLAG & "111111" & SEL
port_txt_addr1  EQU #BF
port_txt_addr2  EQU #7F

; Screen positions for live hex values
IO_POS          EQU (BUFFER + (BYTES_PER_ROW * 28) + (4 * 2))
DATA_POS        EQU (BUFFER + (BYTES_PER_ROW * 28) + (16 * 2))

; Attributes
ATTR_HEADER     EQU %01111000
ATTR_INFO       EQU %00000110
ATTR_TITLE      EQU %01000111
ATTR_ITEM       EQU %00000111

; =============================================================================
; Reset vector
; =============================================================================

        ORG #0000
StartProg:
        di
        xor a
        out (port_txt_addr1), a
        ld a, #10
        out (port_txt_addr2), a
        jp Test

; =============================================================================
; INT vector
; =============================================================================

        ORG #0038
Int:
        reti

; =============================================================================
; NMI vector
; =============================================================================

        ORG #0066
Nmi:
        retn

; =============================================================================
; Main
; =============================================================================

Test:
        ld sp, #3FFF

        call Cls
        call DrawScreen

test1:
        ld hl, IO_POS

        in a, (port_addr_hi)
        call ByteToHexStr

        in a, (port_addr_low)
        call ByteToHexStr

        ld hl, DATA_POS

        in a, (port_data)
        call ByteToHexStr

        jr test1

; =============================================================================
; Clear text video buffer
; char = #00, attr = #07
; =============================================================================

Cls:
        ld hl, BUFFER
        ld (hl), #00
        inc hl
        ld (hl), #07
        dec hl

        ld de, BUFFER + 2
        ld bc, TEXT_BYTES - 2
        ldir
        ret

; =============================================================================
; Print string to text buffer
; Input:
;   DE = string address
;   HL = screen buffer address
;
; Control byte CTRL_SET_COLOR: next byte is attribute.
; =============================================================================

PrintStr:
        ld a, (print_color)
        ld c, a

PrintStrLoop:
        ld a, (de)
        or a
        jr z, PrintStrDone

        inc de
        cp CTRL_SET_COLOR
        jr z, PrintStrSetColor

        ld (hl), a
        inc hl
        ld (hl), c
        inc hl
        jr PrintStrLoop

PrintStrSetColor:
        ld a, (de)
        inc de
        ld c, a
        jr PrintStrLoop

PrintStrDone:
        ld a, c
        ld (print_color), a
        ret

; =============================================================================
; Convert byte in A to two HEX ASCII characters
; Input:
;   A  = byte
;   HL = screen buffer address
;
; Writes only characters, skips attribute bytes.
; =============================================================================

ByteToHexStr:
        ld b, a

        rrca
        rrca
        rrca
        rrca
        and #0F
        add a, #90
        daa
        adc a, #40
        daa
        ld (hl), a
        inc hl
        inc hl

        ld a, b
        and #0F
        add a, #90
        daa
        adc a, #40
        daa
        ld (hl), a
        inc hl
        inc hl
        ret

; =============================================================================
; Static screen layout table
; Format: dw screen_address, string_address
; =============================================================================

ScreenTable:
        dw BUFFER + (BYTES_PER_ROW * 0),  str01
        dw BUFFER + (BYTES_PER_ROW * 29), strgradient
        dw BUFFER + (BYTES_PER_ROW * 2),  strTitle

        dw BUFFER + (BYTES_PER_ROW * 4),  str0301
        dw BUFFER + (BYTES_PER_ROW * 5),  str0302
        dw BUFFER + (BYTES_PER_ROW * 6),  str0303
        dw BUFFER + (BYTES_PER_ROW * 7),  str0304
        dw BUFFER + (BYTES_PER_ROW * 8),  str0305
        dw BUFFER + (BYTES_PER_ROW * 9),  str0306
        dw BUFFER + (BYTES_PER_ROW * 10), str0307
        dw BUFFER + (BYTES_PER_ROW * 11), str0308
        dw BUFFER + (BYTES_PER_ROW * 12), str0309
        dw BUFFER + (BYTES_PER_ROW * 13), str0310

        dw BUFFER + (BYTES_PER_ROW * 15), str0311
        dw BUFFER + (BYTES_PER_ROW * 16), str0312

        dw BUFFER + (BYTES_PER_ROW * 27), str02a
        dw BUFFER + (BYTES_PER_ROW * 28), str02
ScreenTableEnd:

SCREEN_ITEMS EQU (ScreenTableEnd - ScreenTable) / 4

; =============================================================================
; Draw all strings from ScreenTable
; =============================================================================

DrawScreen:
        ld hl, ScreenTable
        ld b, SCREEN_ITEMS

DrawScreenLoop:
        ; Read destination address
        ld e, (hl)
        inc hl
        ld d, (hl)
        inc hl
        push de                  ; save destination

        ; Read string address
        ld e, (hl)
        inc hl
        ld d, (hl)
        inc hl                   ; HL = next table entry

        ; Swap: HL = destination, [SP] = table pointer
        ex (sp), hl

        push bc
        call PrintStr
        pop bc

        pop hl                   ; restore table pointer
        djnz DrawScreenLoop

        ret

; =============================================================================
; String data
; =============================================================================

;        00000000001111111111222222222233333333334444444444555555555566666666667777777777
;        01234567890123456789012345678901234567890123456789012345678901234567890123456789

str01:
        db CTRL_SET_COLOR, ATTR_HEADER
        db " -= REVERSE-U8 =-                          U8-Speccy v.0.8.9 build date: "
Build:
        db "261008"
        db " ", 0

str02a:
        db CTRL_SET_COLOR, ATTR_INFO
        db "CPU: T80 V351, ESXDOS V0.8.9", 0

str02:
        db CTRL_SET_COLOR, ATTR_INFO
        db "IO= ....h Data= ..h", 0

strgradient:
        db CTRL_SET_COLOR, %00000000, "     "
        db CTRL_SET_COLOR, %01000000, "     "
        db CTRL_SET_COLOR, %00001000, "     "
        db CTRL_SET_COLOR, %01001000, "     "
        db CTRL_SET_COLOR, %00010000, "     "
        db CTRL_SET_COLOR, %01010000, "     "
        db CTRL_SET_COLOR, %00011000, "     "
        db CTRL_SET_COLOR, %01011000, "     "
        db CTRL_SET_COLOR, %00100000, "     "
        db CTRL_SET_COLOR, %01100000, "     "
        db CTRL_SET_COLOR, %00101000, "     "
        db CTRL_SET_COLOR, %01101000, "     "
        db CTRL_SET_COLOR, %00110000, "     "
        db CTRL_SET_COLOR, %01110000, "     "
        db CTRL_SET_COLOR, %00111000, "     "
        db CTRL_SET_COLOR, %01111000, "     ", 0

strTitle:
        db CTRL_SET_COLOR, ATTR_TITLE
        db "CONTROL KEYS", 0

str0301:
        db CTRL_SET_COLOR, ATTR_ITEM
        db " F3:  Clock #1 (7/3.5 MHz)", 0

str0302:
        db CTRL_SET_COLOR, ATTR_ITEM
        db " F4:  CPU Reset", 0

str0303:
        db CTRL_SET_COLOR, ATTR_ITEM
        db " F5:  NMI", 0

str0304:
        db CTRL_SET_COLOR, ATTR_ITEM
        db " F6:  divMMC (off/on)", 0

str0305:
        db CTRL_SET_COLOR, ATTR_ITEM
        db " F7:  Frame (off/on)", 0

str0306:
        db CTRL_SET_COLOR, ATTR_ITEM
        db " F8:  POST", 0

str0307:
        db CTRL_SET_COLOR, ATTR_ITEM
        db " F9:  Clock #2 (14/7 MHz)", 0

str0308:
        db CTRL_SET_COLOR, ATTR_ITEM
        db " F10: GS Reset", 0

str0309:
        db CTRL_SET_COLOR, ATTR_ITEM
        db " F11: SounDrive", 0

str0310:
        db CTRL_SET_COLOR, ATTR_ITEM
        db " F12: Video: (Spectrum/Pentagon)", 0

str0311:
        db CTRL_SET_COLOR, ATTR_ITEM
        db " Scroll Lock: Hard Reset", 0

str0312:
        db CTRL_SET_COLOR, ATTR_ITEM
        db " Num. Lock: Kempston", 0

        savebin "rom.bin", StartProg, 16384