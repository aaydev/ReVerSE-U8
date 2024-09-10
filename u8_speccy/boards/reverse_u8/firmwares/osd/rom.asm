	DEVICE	ZXSPECTRUM48

; PCB ReVerSE U8EP3C POST

; -------------------------------------------------------------------------------
; -- Карта памяти N80v1 CPU
; -------------------------------------------------------------------------------
; -- A15 A14 A13
; -- 0   0   x	0000-3FFF (16384) RAM
; -- 			  ( 4800) текстовый буфер (символ, цвет, символ...)

; -- #BF W/R:txt0_addr1 мл.адрес начала текстового видео буфера
; -- #7F W/R:txt0_addr2 ст.адрес начала текстового видео буфера

BUFFER			EQU #2000	; Адрес начала текстового буфера
VARIABLES		EQU #003a	; Адрес начала переменных

; Переменные
print_color		EQU VARIABLES+0
print_addr		EQU VARIABLES+1


; I/O
port_addr_low		EQU %11111110
port_addr_hi		EQU %11111101
port_data		EQU %11111011
port_status		EQU %11110111	;IOFLAG & "111111" & SEL

port_txt_addr1		EQU #bf
port_txt_addr2		EQU #7f

;--------------------------------------
; Reset
		ORG #0000
StartProg:
		di
		ld a,#00
		out (port_txt_addr1),a
		ld a,#10
		out (port_txt_addr2),a
		jp Test
;--------------------------------------
; INT
		ORG #0038
Int
		reti
;--------------------------------------
; NMI
		ORG #0066
Nmi
		retn
;--------------------------------------
Test
		ld sp,#3FFF

		call Cls
		
		ld de,str01
		ld hl,BUFFER
		call PrintStr

		ld de,strgradient
		ld hl,BUFFER+160*29
		call PrintStr


		ld de,strTitle
		ld hl,BUFFER+160*2
		call PrintStr
		ld de,str0301
		ld hl,BUFFER+160*4
		call PrintStr
		ld de,str0302
		ld hl,BUFFER+160*5
		call PrintStr
		ld de,str0303
		ld hl,BUFFER+160*6
		call PrintStr
		ld de,str0304
		ld hl,BUFFER+160*7
		call PrintStr
		ld de,str0305
		ld hl,BUFFER+160*8
		call PrintStr
		ld de,str0306
		ld hl,BUFFER+160*9
		call PrintStr
		ld de,str0307
		ld hl,BUFFER+160*10
		call PrintStr
		ld de,str0308
		ld hl,BUFFER+160*11
		call PrintStr
		ld de,str0309
		ld hl,BUFFER+160*12
		call PrintStr
		ld de,str0310
		ld hl,BUFFER+160*13
		call PrintStr
		ld de,str0311
		ld hl,BUFFER+160*15
		call PrintStr
		ld de,str0312
		ld hl,BUFFER+160*16
		call PrintStr
		
		ld de,str02
		ld hl,BUFFER+160*28
		call PrintStr		

test1		in a,(port_addr_hi)
		ld hl,BUFFER+160*28+4*2
		call ByteToHexStr

		in a,(port_addr_low)
		call ByteToHexStr

		in a,(port_data)
		ld hl,BUFFER+160*28+16*2
		call ByteToHexStr


		jp test1

;--------------------------------------
; Очистка текстового видео буфера	
;--------------------------------------
Cls		ld de,#0700
		ld bc,#0960
		ld hl,BUFFER
cls1		ld (hl),e
		inc hl
		ld (hl),d
		inc hl
		dec bc
		ld a,c
		or b
		jr nz,cls1
		ret

;--------------------------------------
; Печать
;--------------------------------------
PrintStr	ld a,(print_color)
printStr2	ld c,a
printStr3	ld a,(de)
		or a
		ret z
		inc de
		cp #01
		jr z,printStr1
		ld (hl),a
		inc hl
		ld (hl),c
		inc hl
		jr printStr3
printStr1	ld a,(de)
		ld (print_color),a
		inc de
		jr printStr2

;--------------------------------------
; Byte to HEX string
;--------------------------------------
; A  = byte
; HL = buffer
ByteToHexStr	ld b,a
		rrca
		rrca
		rrca
		rrca
		and #0f
		add a,#90
		daa
		adc a,#40
		daa
		ld (hl),a
		inc hl
		inc hl
		ld a,b
		and #0f
		add a,#90
		daa
		adc a,#40
		daa
		ld (hl),a
		inc hl
		inc hl
		ret

; цвет
; b2..0 = ink
; b5..3 = paper
; b6	= bright
; b7	= -

;				 00000000001111111111222222222233333333334444444444555555555566666666667777777777	
;				 01234567890123456789012345678901234567890123456789012345678901234567890123456789
str01		db 1,%01111000,	" REVERSE-U8 POST                           U8-Speccy v.0.8.9 build date: "
Build		db "240910"
		db " ",0

str02		db 1,%00000110,	"IO= ....h Data= ..h",0

strgradient	db 1,%00000000, "     ", 1,%01000000, "     ", 1,%00001000, "     ", 1,%01001000, "     ", 1,%00010000, "     ", 1,%01010000, "     ", 1,%00011000, "     ", 1,%01011000, "     "
		db 1,%00100000, "     ", 1,%01100000, "     ", 1,%00101000, "     ", 1,%01101000, "     ", 1,%00110000, "     ", 1,%01110000, "     ", 1,%00111000, "     ", 1,%01111000, "     ", 0


strTitle	db 1,%01000111, "-= CONTROL KEYS =-",0
str0301		db 1,%00000111, " F3:  Clock #1 (7/3.5 MHz)",0
str0302		db 1,%00000111, " F4:  CPU Reset",0
str0303		db 1,%00000111, " F5:  NMI",0
str0304		db 1,%00000111, " F6:  divMMC (off/on)",0	
str0305		db 1,%00000111, " F7:  Frame (off/on)",0
str0306		db 1,%00000111, " F8:  POST",0
str0307		db 1,%00000111, " F9:  Clock #2 (14/7 MHz)",0
str0308		db 1,%00000111, " F10: GS Reset",0
str0309		db 1,%00000111, " F11: SounDrive",0
str0310		db 1,%00000111, " F12: Video: (Spectrum/Pentagon)",0

str0311		db 1,%00000111, " Scroll Lock: Hard Reset",0
str0312		db 1,%00000111, " Num. Lock: Kempston",0

	savebin "rom.bin",StartProg, 16384