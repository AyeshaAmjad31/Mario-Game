; ---------------------------------------------------------------------------
; MODULE 1 : named constants
; ---------------------------------------------------------------------------
SCRW        equ 320              ; screen width in pixels
SCRH        equ 200              ; screen height in pixels
MAPW        equ 60               ; level width in tiles
MAPH        equ 12               ; level height in tiles
LEVELW      equ 960              ; level width in pixels
MAXCAM      equ 640              ; last camera position (960 - 320)
NENT        equ 10               ; entity records (6 enemies + 4 mushrooms)
ENT_SIZE    equ 16               ; bytes per entity record
E_TYPE      equ 0                ; 0 none,1 goomba,2 koopa,3 shell,4 mushroom
E_STATE     equ 2                ; 0 waiting/stationary, 1 walking/sliding, 2 flat
E_X         equ 4                ; world x (pixels)
E_Y         equ 6                ; y of top edge (pixels)
E_DIR       equ 8                ; +1 right, -1 left
E_TIMER     equ 10               ; flat timer / kick grace timer
E_XF        equ 12               ; fraction accumulator for x

ST_TITLE    equ 0                ; game states (index into state_tab)
ST_PLAY     equ 1
ST_PAUSE    equ 2
ST_DYING    equ 3
ST_LIFE     equ 4
ST_WIN      equ 5
ST_COMPLETE equ 6
ST_OVER     equ 7
ST_EXIT     equ 8

KEY_ESC     equ 0x01             ; scan codes (Appendix A.3)
KEY_ENTER   equ 0x1C
KEY_P       equ 0x19
KEY_LSHIFT  equ 0x2A
KEY_SPACE   equ 0x39
KEY_UP      equ 0x48
KEY_DOWN    equ 0x50
KEY_LEFT    equ 0x4B
KEY_RIGHT   equ 0x4D
KEY_F1      equ 0x3B             ; debug: time = 5
KEY_F2      equ 0x3C             ; debug: coins = 99

ACC         equ 0x0020           ; physics constants, 8.8 fixed point (A.5)
FRIC        equ 0x0010
WALKMAX     equ 0x0180
RUNMAX      equ 0x0280
GRAV        equ 0x0040
JUMPV       equ 0xFA80           ; -5.5
JUMPCUT     equ 0xFE00           ; -2.0
MAXFALL     equ 0x0400
BOUNCE      equ 0xFD00           ; -3.0
BOUNCEHI    equ 0xFC00           ; -4.0 (jump key held)
DEATHV      equ 0xFB00           ; -5.0 (death hop of about 48 pixels)
; ---------------------------------------------------------------------------
; MODULE 1/2/5/7/8 : program start, memory, video, interrupt hooking
; ---------------------------------------------------------------------------
start:
        mov ax, cs
        mov ds, ax
        mov es, ax
        cld
        mov bx, 0x1000           ; shrink our memory block to 64 KB ...
        mov ah, 0x4A
        int 0x21
        jnc ..@j14   ; long jump: inverted short jump + near jmp
        jmp near mem_fail
..@j14:
        mov bx, 0x0FA0           ; ... and allocate 64000 bytes (4000 paragraphs)
        mov ah, 0x48             ; for the off-screen frame buffer
        int 0x21
        jnc ..@j13   ; long jump: inverted short jump + near jmp
        jmp near mem_fail
..@j13:
        mov [fbseg], ax
        mov ax, 0x1130           ; ask the BIOS where its 8x8 font lives
        mov bh, 3
        int 0x10
        mov [fontseg], es
        mov [fontoff], bp
        mov ax, cs
        mov es, ax

        push word spr_start      ; turn the sprite letters into palette colours
        push word spr_end - spr_start
        push word spr_legend
        push word 15
        push word spr_cols
        call DecodeBytes
        push word map_orig       ; turn the level letters into tile codes
        push word MAPW*MAPH
        push word map_legend
        push word 13
        push word 0
        call DecodeBytes

        mov ax, 0x0013           ; VGA mode 13h
        int 0x10
        mov ax, 0x1012           ; load our 16 colours into the DAC
        xor bx, bx
        mov cx, 16
        mov dx, palette
        int 0x10

        mov ax, 0x3509           ; save and replace the keyboard interrupt
        int 0x21
        mov [old9], bx
        mov [old9+2], es
        mov ax, 0x3508           ; save and replace the timer interrupt
        int 0x21
        mov [old8], bx
        mov [old8+2], es
        mov ax, cs
        mov es, ax
        mov dx, kb_isr
        mov ax, 0x2509
        int 0x21
        mov dx, tm_isr
        mov ax, 0x2508
        int 0x21
        mov al, 0x36             ; timer channel 0 -> about 30 ticks a second
        out 0x43, al
        mov ax, 39773
        out 0x40, al
        mov al, ah
        out 0x40, al

        call NewGame             ; initialise every game variable
        mov word [state], ST_TITLE
        mov word [menu_sel], 0
        call ClearEdges

main_loop:
        cld
        call WaitTick            ; step 1 of every frame
        mov bx, [state]
        cmp bx, ST_EXIT
        je  shutdown
        shl bx, 1
        call [state_tab+bx]      ; jump table indexed by the state number
        jmp main_loop

mem_fail:
        mov dx, s_memfail
        mov ah, 0x09
        int 0x21
        mov ax, 0x4C01
        int 0x21
; ---------------------------------------------------------------------------
; shutdown: every exit path ends here. Restore timer rate, both vectors,
; text mode and return to DOS.
; ---------------------------------------------------------------------------
shutdown:
        cli
        mov al, 0x36             ; timer back to the default 18.2 Hz
        out 0x43, al
        xor al, al
        out 0x40, al
        out 0x40, al
        push ds
        mov dx, [old9]           ; restore keyboard vector
        mov ds, [old9+2]
        mov ax, 0x2509
        int 0x21
        pop ds
        push ds
        mov dx, [old8]           ; restore timer vector
        mov ds, [old8+2]
        mov ax, 0x2508
        int 0x21
        pop ds
        sti
        mov ax, 0x0003           ; back to text mode
        int 0x10
        mov ax, 0x4C00           ; terminate program
        int 0x21
; ---------------------------------------------------------------------------
; MODULE 7: keyboard interrupt handler
; Reads port 60h, ignores the E0h prefix, keeps a 128 byte table of held keys
; and a table of fresh key presses (edge). Sends EOI and returns with IRET.
; ---------------------------------------------------------------------------
kb_isr:
        push ax
        push bx
        push ds
        mov ax, cs
        mov ds, ax
        in  al, 0x60             ; scan code
        cmp al, 0xE0             ; extended prefix: ignore, next code follows
        je  .done
        mov bl, al
        xor bh, bh
        and bl, 0x7F             ; strip the release bit
        test al, 0x80
        jnz .release
        cmp byte [keys+bx], 0    ; typematic repeat: already held
        jne .done
        mov byte [keys+bx], 1
        mov byte [edge+bx], 1    ; fresh press
        jmp .done
.release:
        mov byte [keys+bx], 0
.done:
        mov al, 0x20             ; end of interrupt
        out 0x20, al
        pop ds
        pop bx
        pop ax
        iret

; ---------------------------------------------------------------------------
; MODULE 8: timer interrupt handler. Counts ticks, then chains to the old one.
; ---------------------------------------------------------------------------
tm_isr:
        push ds
        push ax
        mov ax, cs
        mov ds, ax
        inc word [ticks]
        pop ax
        pop ds
        jmp far [cs:old8]        ; the old handler sends the EOI and does IRET

; ---------------------------------------------------------------------------
; WaitTick : waits until the tick counter changes (game speed from timer)
; outputs  : [tickdelta] = ticks passed since the last frame (at least 1)
; ---------------------------------------------------------------------------
WaitTick:
        push ax
.w:     mov ax, [ticks]
        cmp ax, [lasttick]
        je  .w
        mov [lasttick], ax
        sub ax, [prevtick]
        mov [tickdelta], ax
        mov ax, [lasttick]
        mov [prevtick], ax
        pop ax
        ret

; ---------------------------------------------------------------------------
; TestEdge(scancode) : AL = 1 if the key was freshly pressed since the last
; test, and clears the flag.        changes: AX
; ---------------------------------------------------------------------------
TestEdge:
        push bp
        mov bp, sp
        push bx
        mov bx, [bp+4]
        mov al, [edge+bx]
        mov byte [edge+bx], 0
        xor ah, ah
        pop bx
        pop bp
        ret 2

; ClearEdges : forget all pending key presses.    changes: nothing
ClearEdges:
        push ax
        push cx
        push di
        mov di, edge
        mov cx, 128
        xor al, al
        rep stosb
        pop di
        pop cx
        pop ax
        ret

; ---------------------------------------------------------------------------
; DecodeBytes(ptr, count, legend, legendlen, valtab)
; Replaces every byte at ptr by its position in 'legend'; if valtab is not
; zero the position is looked up in valtab. Unknown letters become 0.
; ---------------------------------------------------------------------------
DecodeBytes:
        push bp
        mov bp, sp
        pusha
        push es
        mov ax, ds
        mov es, ax
        mov si, [bp+12]
.next:  mov al, [si]
        mov di, [bp+8]
        mov cx, [bp+6]
        repne scasb
        jne .none
        mov bx, di
        sub bx, [bp+8]
        dec bx                   ; bx = position in the legend
        mov al, bl
        cmp word [bp+4], 0
        je  .store
        mov di, [bp+4]
        mov al, [di+bx]
        jmp .store
.none:  xor al, al
.store: mov [si], al
        inc si
        dec word [bp+10]
        jnz .next
        pop es
        popa
        pop bp
        ret 10
; ===========================================================================
; MODULES 2-6 : video, tiles, sprites, text, frame buffer, camera
; Every procedure preserves all registers it does not return.
; ===========================================================================

; PutPixel(x, y, colour) : plot one pixel into the frame buffer (clipped)
; offset = y*320 + x = (y<<8) + (y<<6) + x
PutPixel:
        push bp
        mov bp, sp
        push ax
        push bx
        push di
        push es
        mov ax, [bp+8]           ; x
        cmp ax, SCRW
        jae .out                 ; unsigned compare also rejects negatives
        mov bx, [bp+6]           ; y
        cmp bx, SCRH
        jae .out
        mov es, [fbseg]
        mov di, bx
        shl di, 8
        shl bx, 6
        add di, bx
        add di, ax
        mov al, [bp+4]
        mov [es:di], al
.out:   pop es
        pop di
        pop bx
        pop ax
        pop bp
        ret 6

; FillRect(x, y, w, h, colour) : solid rectangle, clipped to the screen
FillRect:
        push bp
        mov bp, sp
        pusha
        push es
        mov ax, [bp+12]          ; x0
        mov bx, [bp+10]          ; y0
        mov cx, [bp+8]
        add cx, ax               ; x1
        mov dx, [bp+6]
        add dx, bx               ; y1
        cmp ax, 0
        jge .a
        xor ax, ax
.a:     cmp cx, SCRW
        jle .b
        mov cx, SCRW
.b:     cmp bx, 0
        jge .c
        xor bx, bx
.c:     cmp dx, SCRH
        jle .d
        mov dx, SCRH
.d:     cmp ax, cx
        jge .done
        cmp bx, dx
        jge .done
        sub cx, ax               ; cx = width
        mov di, bx
        shl di, 8
        mov si, bx
        shl si, 6
        add di, si
        add di, ax               ; di = y0*320 + x0
        mov es, [fbseg]
        mov al, [bp+4]
.row:   push cx
        push di
        rep stosb
        pop di
        pop cx
        add di, SCRW
        inc bx
        cmp bx, dx
        jl  .row
.done:  pop es
        popa
        pop bp
        ret 10

; ClearFB(colour) : fill the whole frame buffer with REP STOSW
ClearFB:
        push bp
        mov bp, sp
        push ax
        push cx
        push di
        push es
        mov es, [fbseg]
        xor di, di
        mov al, [bp+4]
        mov ah, al
        mov cx, 32000
        rep stosw
        pop es
        pop di
        pop cx
        pop ax
        pop bp
        ret 2

; Flip : copy the frame buffer to video memory with REP MOVSW
Flip:
        push ax
        push cx
        push si
        push di
        push ds
        push es
        mov ax, [fbseg]
        mov ds, ax
        mov ax, 0xA000
        mov es, ax
        xor si, si
        xor di, di
        mov cx, 32000
        rep movsw
        pop es
        pop ds
        pop di
        pop si
        pop cx
        pop ax
        ret

; GetTile(px, py) : AL = tile code under the pixel position.
; Outside the level on the left/right the tile is solid ground; above the
; top or below the map it is sky.
GetTile:
        push bp
        mov bp, sp
        push bx
        push cx
        mov bx, [bp+6]           ; px
        mov cx, [bp+4]           ; py
        cmp bx, 0
        jl  .wall
        cmp bx, LEVELW
        jge .wall
        cmp cx, 0
        jl  .air
        cmp cx, 192
        jge .air
        shr cx, 4                ; row
        shr bx, 4                ; column
        mov ax, cx
        shl ax, 6
        shl cx, 2
        sub ax, cx               ; row*64 - row*4 = row*60
        add bx, ax
        mov al, [map_work+bx]    ; based addressing into the working map
        jmp .ret
.wall:  mov al, 1
        jmp .ret
.air:   xor al, al
.ret:   xor ah, ah
        pop cx
        pop bx
        pop bp
        ret 4

; IsSolid(px, py) : AL = 1 if the tile there is solid
IsSolid:
        push bp
        mov bp, sp
        push bx
        push word [bp+6]
        push word [bp+4]
        call GetTile
        mov bl, al
        xor bh, bh
        mov al, [solid_tab+bx]
        xor ah, ah
        pop bx
        pop bp
        ret 4

; SetTile(px, py, code) : write a tile of the WORKING map
SetTile:
        push bp
        mov bp, sp
        push ax
        push bx
        push cx
        mov bx, [bp+8]
        mov cx, [bp+6]
        shr bx, 4
        shr cx, 4
        mov ax, cx
        shl ax, 6
        shl cx, 2
        sub ax, cx
        add bx, ax
        mov al, [bp+4]
        mov [map_work+bx], al
        pop cx
        pop bx
        pop ax
        pop bp
        ret 6

; SolidColumn(x, y0, y1) : AL = 1 if any tile at x between y0..y1 is solid
SolidColumn:
        push bp
        mov bp, sp
        push dx
        mov dx, [bp+6]
.l:     push word [bp+8]
        push dx
        call IsSolid
        or  al, al
        jnz .yes
        cmp dx, [bp+4]
        jge .no
        add dx, 8
        cmp dx, [bp+4]
        jle .l
        mov dx, [bp+4]
        jmp .l
.no:    xor al, al
        jmp .out
.yes:   mov al, 1
.out:   xor ah, ah
        pop dx
        pop bp
        ret 6

; Overlap(x1,y1,w1,h1, x2,y2,w2,h2) : AL = 1 if the rectangles overlap
Overlap:
        push bp
        mov bp, sp
        push bx
        mov ax, [bp+18]
        mov bx, [bp+10]
        add bx, [bp+6]
        cmp ax, bx
        jge .no
        mov ax, [bp+10]
        mov bx, [bp+18]
        add bx, [bp+14]
        cmp ax, bx
        jge .no
        mov ax, [bp+16]
        mov bx, [bp+8]
        add bx, [bp+4]
        cmp ax, bx
        jge .no
        mov ax, [bp+8]
        mov bx, [bp+16]
        add bx, [bp+12]
        cmp ax, bx
        jge .no
        mov al, 1
        jmp .out
.no:    xor al, al
.out:   xor ah, ah
        pop bx
        pop bp
        ret 16

; ---------------------------------------------------------------------------
; MODULE 4 : DrawSprite(x, y, address, flags)
; flags: bit0 mirror, bit1 dither (half transparent), bit2 stretch x2 in height
; colour 0 is transparent. Clipped on all four sides.
; ---------------------------------------------------------------------------
DrawSprite:
        push bp
        mov bp, sp
        pusha
        push es
        mov es, [fbseg]
        mov word [spr_r], 0
.row:   mov ax, [spr_r]
        mov si, ax
        shl si, 4
        add si, [bp+6]           ; si -> this row of the bitmap
        test byte [bp+4], 4
        jz  .n1
        shl ax, 1
.n1:    add ax, [bp+8]
        mov [spr_dy], ax
        call .line
        test byte [bp+4], 4
        jz  .next
        inc word [spr_dy]
        call .line
.next:  inc word [spr_r]
        cmp word [spr_r], 16
        jb  .row
        pop es
        popa
        pop bp
        ret 8

.line:  mov bx, [spr_dy]
        cmp bx, SCRH
        jae .lret
        mov di, bx
        shl di, 8
        shl bx, 6
        add di, bx               ; di = y*320
        xor cx, cx
.px:    mov ax, [bp+10]
        add ax, cx               ; screen x
        cmp ax, SCRW
        jae .pn
        mov bx, si
        test byte [bp+4], 1
        jz  .nm
        mov dx, 15
        sub dx, cx
        add bx, dx               ; mirrored column
        jmp .gp
.nm:    add bx, cx
.gp:    mov dl, [bx]
        or  dl, dl
        jz  .pn
        test byte [bp+4], 2
        jz  .put
        push ax
        add ax, [spr_dy]
        test al, 1
        pop ax
        jnz .pn
.put:   mov bx, ax
        mov [es:di+bx], dl
.pn:    inc cx
        cmp cx, 16
        jb  .px
.lret:  ret
; ---------------------------------------------------------------------------
; MODULE 3 : DrawMap(camera) draws the visible 21 columns of the working map
; ---------------------------------------------------------------------------
DrawMap:
        push bp
        mov bp, sp
        pusha
        xor si, si               ; si = screen column
.col:   mov ax, [bp+4]
        shr ax, 4
        add ax, si               ; ax = map column
        cmp ax, MAPW
        jae .end
        mov di, ax
        mov cx, 1                ; row 0 is the HUD
.row:   mov ax, cx
        shl ax, 6
        mov bx, cx
        shl bx, 2
        sub ax, bx
        add ax, di
        mov bx, ax
        mov al, [map_work+bx]
        or  al, al
        jz  .nxt
        xor ah, ah
        shl ax, 1
        mov bx, ax
        mov bx, [tile_addr+bx]   ; sprite of this tile
        mov dx, si
        shl dx, 4
        mov ax, [bp+4]
        and ax, 15
        sub dx, ax               ; x = col*16 - (camera mod 16)
        push dx
        mov dx, cx
        shl dx, 4
        push dx
        push bx
        push word 0
        call DrawSprite
.nxt:   inc cx
        cmp cx, MAPH
        jb  .row
        inc si
        cmp si, 21
        jb  .col
.end:   popa
        pop bp
        ret 2

; ---------------------------------------------------------------------------
; MODULE 13 : text.  The 8x8 letters come from the BIOS ROM font.
; DrawChar(x, y, ch, colour)
; ---------------------------------------------------------------------------
DrawChar:
        push bp
        mov bp, sp
        pusha
        mov ax, [bp+6]
        and ax, 0x00FF
        shl ax, 3
        add ax, [fontoff]
        mov si, ax
        mov bx, [fontseg]
        xor cx, cx               ; row
.row:   push ds
        mov ds, bx
        mov dl, [si]
        pop ds
        inc si
        xor di, di               ; column
.col:   test dl, 0x80
        jz  .nb
        mov ax, [bp+10]
        add ax, di
        push ax
        mov ax, [bp+8]
        add ax, cx
        push ax
        push word [bp+4]
        call PutPixel
.nb:    shl dl, 1
        inc di
        cmp di, 8
        jb  .col
        inc cx
        cmp cx, 8
        jb  .row
        popa
        pop bp
        ret 8

; DrawText(x, y, string, colour) : zero terminated string
DrawText:
        push bp
        mov bp, sp
        pusha
        mov si, [bp+6]
        mov di, [bp+10]
.l:     mov al, [si]
        or  al, al
        jz  .d
        xor ah, ah
        push di
        push word [bp+8]
        push ax
        push word [bp+4]
        call DrawChar
        add di, 8
        inc si
        jmp .l
.d:     popa
        pop bp
        ret 8

; DrawNum(x, y, high, low, digits, colour) : 32 bit number as decimal.
; Remainders of repeated division by 10 are pushed, then popped in reverse.
DrawNum:
        push bp
        mov bp, sp
        pusha
        mov bx, [bp+10]          ; high word
        mov si, [bp+8]           ; low word
        mov di, [bp+6]           ; digit count
        mov cx, di
.d1:    mov ax, bx
        xor dx, dx
        div word [ten]
        mov bx, ax
        mov ax, si
        div word [ten]           ; dx:ax / 10, remainder in dx
        mov si, ax
        push dx
        loop .d1
        mov cx, di
        mov si, [bp+14]
.d2:    pop ax
        add al, '0'
        xor ah, ah
        push si
        push word [bp+12]
        push ax
        push word [bp+4]
        call DrawChar
        add si, 8
        loop .d2
        popa
        pop bp
        ret 12
; ---------------------------------------------------------------------------
; MODULE 6 : UpdateCamera(marioX) : AX = new camera x   (Section 5.3 rules)
; ---------------------------------------------------------------------------
UpdateCamera:
        push bp
        mov bp, sp
        mov ax, [bp+4]
        sub ax, [cam]            ; screen x
        cmp ax, 160
        jle .keep
        mov ax, [bp+4]
        sub ax, 160
        cmp ax, MAXCAM
        jle .a
        mov ax, MAXCAM
.a:     cmp ax, [cam]
        jge .out                 ; never move the camera back
.keep:  mov ax, [cam]
.out:   pop bp
        ret 2

