
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
; ===========================================================================
; MODULES 9, 10, 12, 13 : hero movement, collision, blocks, score
; Position and velocity use 8.8 fixed point. The world position keeps the
; whole pixels in a word (mx, my) and the fraction in a byte (mxf, myf).
; ===========================================================================

; AddScore(points) : 32 bit ADD/ADC, clamped to 999,999 (0x000F423F)
AddScore:
        push bp
        mov bp, sp
        push ax
        push dx
        mov ax, [score_lo]
        mov dx, [score_hi]
        add ax, [bp+4]
        adc dx, 0
        cmp dx, 0x0F
        ja  .clamp
        jb  .ok
        cmp ax, 0x423F
        jbe .ok
.clamp: mov dx, 0x0F
        mov ax, 0x423F
.ok:    mov [score_lo], ax
        mov [score_hi], dx
        pop dx
        pop ax
        pop bp
        ret 2

; AddLife : lives + 1 (never above 99)
AddLife:
        cmp word [lives], 99
        jae .r
        inc word [lives]
.r:     ret

; AddCoin : coins + 1; every 100 coins give a life and the counter restarts
AddCoin:
        inc word [coins]
        cmp word [coins], 100
        jb  .r
        mov word [coins], 0
        call AddLife
.r:     ret

; HurtHero : enemy contact. Super -> Small + blinking, Small -> death
HurtHero:
        cmp word [invuln], 0
        jne .r
        cmp byte [hp], 2
        jne .die
        mov byte [hp], 1
        mov byte [form], 0
        mov word [hh], 16
        add word [my], 16        ; feet stay fixed: top = feet - 16
        mov word [invuln], 60    ; about 2 seconds
        ret
.die:   call KillHero
.r:     ret

; KillHero : start the DYING state (pit deaths skip the upward hop)
KillHero:
        mov byte [hp], 0
        mov word [state], ST_DYING
        mov word [dtimer], 0
        mov word [vx], 0
        mov word [invuln], 0     ; no blinking while dying
        mov word [vy], DEATHV
        cmp word [my], 192
        jl  .ok
        mov word [vy], 0
.ok:    mov byte [myf], 0
        ret

; GrowHero : mushroom while Small. Feet stay fixed: top = feet - 32
GrowHero:
        cmp byte [hp], 2
        je  .r
        mov byte [hp], 2
        mov byte [form], 1
        mov word [hh], 32
        sub word [my], 16
.r:     ret

; SpawnMushroom(x, y) : put a mushroom into a free entity record
SpawnMushroom:
        push bp
        mov bp, sp
        pusha
        mov si, ents+6*ENT_SIZE
        mov cx, 4
.f:     cmp word [si+E_TYPE], 0
        je  .found
        add si, ENT_SIZE
        loop .f
        jmp .out
.found: mov word [si+E_TYPE], 4
        mov word [si+E_STATE], 1
        mov ax, [bp+6]
        mov [si+E_X], ax
        mov ax, [bp+4]
        mov [si+E_Y], ax
        mov word [si+E_DIR], 1
        mov word [si+E_TIMER], 0
        mov word [si+E_XF], 0
.out:   popa
        pop bp
        ret 4

; TriggerBlock(px, py) : the hero's head hit the tile under this pixel
TriggerBlock:
        push bp
        mov bp, sp
        pusha
        push word [bp+6]
        push word [bp+4]
        call GetTile
        cmp al, 2
        je  .brick
        cmp al, 3
        je  .coin
        cmp al, 4
        je  .mush
        jmp .out
.brick: cmp byte [form], 1       ; only Super Mario breaks bricks
        jne .out
        push word [bp+6]
        push word [bp+4]
        push word 0
        call SetTile
        push word 50
        call AddScore
        jmp .out
.coin:  push word [bp+6]
        push word [bp+4]
        push word 5              ; becomes an empty block
        call SetTile
        push word 200
        call AddScore
        call AddCoin
        jmp .out
.mush:  push word [bp+6]
        push word [bp+4]
        push word 5
        call SetTile
        mov ax, [bp+6]
        shr ax, 4
        shl ax, 4                ; x of the block
        push ax
        mov ax, [bp+4]
        shr ax, 4
        shl ax, 4
        sub ax, 16               ; the mushroom appears on top of the block
        push ax
        call SpawnMushroom
.out:   popa
        pop bp
        ret 4

; CheckTiles : coins and flag pole touched by the hero (3 x 3 sample points)
CheckTiles:
        pusha
        xor si, si               ; si = sample row 0..2
.r:     mov dx, [my]
        cmp si, 0
        je  .y
        mov bx, [hh]
        cmp si, 1
        jne .last
        shr bx, 1
        jmp .ya
.last:  dec bx
.ya:    add dx, bx
.y:     xor di, di               ; di = sample column (word offset)
.c:     mov ax, [mx]
        add ax, [xoff+di]
        push ax
        push dx
        call GetTile
        cmp al, 11
        je  .coin
        cmp al, 12
        je  .flag
.nx:    add di, 2
        cmp di, 6
        jb  .c
        inc si
        cmp si, 3
        jb  .r
        jmp .out
.coin:  mov ax, [mx]
        add ax, [xoff+di]
        push ax
        push dx
        push word 0
        call SetTile             ; the coin disappears from the working map
        push word 200
        call AddScore
        call AddCoin
        jmp .nx
.flag:  mov byte [flag_hit], 1
        mov ax, [my]
        add ax, [hh]
        dec ax
        shr ax, 4                ; map row of the feet
        mov [flag_row], ax
        jmp .nx
.out:   popa
        ret
; ---------------------------------------------------------------------------
; MODULE 9/10 : UpdateHero - input, acceleration, jump, gravity, then move one
; axis at a time with tile collision.
; ---------------------------------------------------------------------------
UpdateHero:
        pusha
        mov ax, [my]
        add ax, [hh]
        mov [old_feet], ax       ; feet position of the previous frame
        mov bx, WALKMAX
        cmp byte [keys+KEY_LSHIFT], 0
        je  .nr
        mov bx, RUNMAX
.nr:    mov ax, [vx]
        cmp byte [keys+KEY_RIGHT], 0
        je  .notr
        mov byte [face], 0
        cmp ax, 0
        jge .racc
        add ax, ACC*2            ; braking is faster than friction
        jmp .rcl
.racc:  add ax, ACC
.rcl:   cmp ax, bx
        jle .xdone
        mov ax, bx
        jmp .xdone
.notr:  cmp byte [keys+KEY_LEFT], 0
        je  .fric
        mov byte [face], 1
        cmp ax, 0
        jle .lacc
        sub ax, ACC*2
        jmp .lcl
.lacc:  sub ax, ACC
.lcl:   neg bx
        cmp ax, bx
        jge .xdone
        mov ax, bx
        jmp .xdone
.fric:  cmp ax, 0
        jg  .fp
        jl  .fn
        jmp .xdone
.fp:    sub ax, FRIC
        jge .xdone
        xor ax, ax
        jmp .xdone
.fn:    add ax, FRIC
        jle .xdone
        xor ax, ax
.xdone: mov [vx], ax

        cmp byte [keys+KEY_SPACE], 0
        je  .nospace
        cmp byte [onground], 0   ; jump only from solid ground
        je  .jdone
        cmp byte [jlock], 0      ; and only once per key press
        jne .jdone
        mov word [vy], JUMPV
        mov byte [onground], 0
        mov byte [jlock], 1
        jmp .jdone
.nospace:
        mov byte [jlock], 0
        cmp word [vy], JUMPCUT   ; released while rising fast: cut the jump
        jge .jdone
        mov word [vy], JUMPCUT
.jdone: add word [vy], GRAV
        cmp word [vy], MAXFALL
        jle .gdone
        mov word [vy], MAXFALL
.gdone:

        ; ---- horizontal move: add vx to mx:mxf ----
        mov al, [mxf]
        add al, [vx]
        mov [mxf], al
        mov al, [vx+1]
        cbw
        adc [mx], ax
        mov ax, [vx]
        cmp ax, 0
        je  .xend
        jl  .left
        mov ax, [mx]
        add ax, 13               ; right edge of the 12 pixel hit box
        push ax
        mov ax, [my]
        push ax
        add ax, [hh]
        dec ax
        push ax
        call SolidColumn
        or  al, al
        jz  .xend
        mov ax, [mx]
        add ax, 13
        sar ax, 4
        shl ax, 4
        sub ax, 14               ; place him against the wall
        mov [mx], ax
        mov byte [mxf], 0
        mov word [vx], 0
        jmp .xend
.left:  mov ax, [mx]
        add ax, 2
        push ax
        mov ax, [my]
        push ax
        add ax, [hh]
        dec ax
        push ax
        call SolidColumn
        or  al, al
        jz  .xend
        mov ax, [mx]
        add ax, 2
        sar ax, 4
        inc ax
        shl ax, 4
        sub ax, 2
        mov [mx], ax
        mov byte [mxf], 0
        mov word [vx], 0
.xend:

        ; ---- vertical move: add vy to my:myf ----
        mov al, [myf]
        add al, [vy]
        mov [myf], al
        mov al, [vy+1]
        cbw
        adc [my], ax
        mov byte [onground], 0
        cmp word [vy], 0
        jl  .up
        mov ax, [mx]             ; falling or resting: look one pixel below
        add ax, 2
        push ax
        mov ax, [my]
        add ax, [hh]
        push ax
        call IsSolid
        or  al, al
        jnz .land
        mov ax, [mx]
        add ax, 13
        push ax
        mov ax, [my]
        add ax, [hh]
        push ax
        call IsSolid
        or  al, al
        jz  .yend
.land:  mov ax, [my]
        add ax, [hh]
        sar ax, 4
        shl ax, 4
        sub ax, [hh]             ; feet on top of the tile
        mov [my], ax
        mov byte [myf], 0
        mov word [vy], 0
        mov byte [onground], 1
        mov word [chain], 0      ; landing resets the stomp chain
        jmp .yend
.up:    mov ax, [mx]
        add ax, 2
        push ax
        push word [my]
        call IsSolid
        or  al, al
        jnz .head
        mov ax, [mx]
        add ax, 13
        push ax
        push word [my]
        call IsSolid
        or  al, al
        jz  .yend
.head:  mov ax, [mx]
        add ax, 8                ; tile under the centre of the head
        push ax
        push word [my]
        call TriggerBlock
        mov ax, [my]
        sar ax, 4
        inc ax
        shl ax, 4
        mov [my], ax             ; head just under the block
        mov byte [myf], 0
        mov word [vy], 0         ; he starts falling
.yend:  popa
        ret
; ===========================================================================
; MODULE 11 : enemies, shells and mushrooms
; Entities live in a table of 16 byte records (see E_xxx constants) and are
; visited with indexed addressing [si+E_X].
; ===========================================================================

; EntWalk(ptr, speed, edgeflag)
; Gravity, horizontal step in 8.8 fixed point, turning at walls, at ledges
; (edgeflag = 1, Koopa) and at other walking enemies. A sliding shell kills
; every enemy it touches (+500).
EntWalk:
        push bp
        mov bp, sp
        pusha
        mov si, [bp+8]
        mov ax, [si+E_X]         ; is there ground under the feet?
        add ax, 8
        push ax
        mov ax, [si+E_Y]
        add ax, 16
        push ax
        call IsSolid
        or  al, al
        jnz .stand
        add word [si+E_Y], 2     ; no: fall 2 pixels
        mov ax, [si+E_X]
        add ax, 8
        push ax
        mov ax, [si+E_Y]
        add ax, 16
        push ax
        call IsSolid
        or  al, al
        jnz ..@j12   ; long jump: inverted short jump + near jmp
        jmp near .out
..@j12:
        mov ax, [si+E_Y]
        add ax, 16
        shr ax, 4
        shl ax, 4
        sub ax, 16               ; land on top of the tile
        mov [si+E_Y], ax
        jmp .out
.stand: mov ax, [bp+6]           ; speed
        add [si+E_XF], al        ; fraction accumulates, carry adds a pixel
        adc ah, 0
        mov al, ah
        xor ah, ah               ; ax = whole pixels this frame
        cmp word [si+E_DIR], 0
        jge .rt
        neg ax
.rt:    mov bx, ax               ; bx = signed step (kept for undo)
        add [si+E_X], ax
        mov ax, [si+E_X]         ; leading edge
        cmp word [si+E_DIR], 0
        jl  .lf
        add ax, 15
.lf:    mov dx, ax
        push dx
        mov ax, [si+E_Y]
        add ax, 8
        push ax
        call IsSolid             ; wall in front?
        or  al, al
        jnz .turn
        cmp word [bp+4], 0
        je  .edge
        push dx                  ; Koopa: is there floor ahead?
        mov ax, [si+E_Y]
        add ax, 16
        push ax
        call IsSolid
        or  al, al
        jz  .turn
.edge:  cmp word [si+E_TYPE], 4  ; mushrooms ignore other entities
        je  .out
        mov di, ents
.o:     cmp di, si
        je  .on
        cmp word [di+E_TYPE], 0
        je  .on
        cmp word [di+E_TYPE], 4
        je  .on
        cmp word [di+E_STATE], 1 ; only walking / sliding ones
        jne .on
        push word [si+E_X]
        push word [si+E_Y]
        push word 16
        push word 16
        push word [di+E_X]
        push word [di+E_Y]
        push word 16
        push word 16
        call Overlap
        or  al, al
        jz  .on
        cmp word [si+E_TYPE], 3  ; is the mover a shell?
        jne .turn
        cmp word [di+E_TYPE], 3
        je  .turn                ; shells just bounce off each other
        mov word [di+E_TYPE], 0  ; enemy removed
        push word 500
        call AddScore
.on:    add di, ENT_SIZE
        cmp di, ents_end
        jb  .o
        jmp .out
.turn:  sub [si+E_X], bx         ; undo the step and turn around
        neg word [si+E_DIR]
.out:   popa
        pop bp
        ret 6

; UpdateEnts : activation, removal and movement of every entity
UpdateEnts:
        pusha
        mov si, ents
.loop:  mov ax, [si+E_TYPE]
        or  ax, ax
        jnz ..@j11   ; long jump: inverted short jump + near jmp
        jmp near .next
..@j11:
        mov bx, [cam]
        sub bx, 32
        cmp [si+E_X], bx         ; far to the left of the camera
        jge ..@j10   ; long jump: inverted short jump + near jmp
        jmp near .remove
..@j10:
        cmp word [si+E_Y], 192   ; fell below the map
        jl ..@j9   ; long jump: inverted short jump + near jmp
        jmp near .remove
..@j9:
        cmp ax, 3
        je  .shell
        cmp ax, 4
        je  .mush
        cmp word [si+E_STATE], 0
        jne .gk
        mov bx, [cam]            ; waiting: wake up one tile before the screen
        add bx, 336
        cmp [si+E_X], bx
        jge .next
        mov word [si+E_STATE], 1
        jmp .next
.gk:    cmp ax, 1
        jne .koopa
        cmp word [si+E_STATE], 2 ; flattened Goomba: count down, then remove
        jne .gwalk
        dec word [si+E_TIMER]
        jg  .next
        mov word [si+E_TYPE], 0
        jmp .next
.gwalk: push si
        push word 0x0080         ; 0.5 pixel per frame
        push word 0
        call EntWalk
        jmp .next
.koopa: push si
        push word 0x00C0         ; 0.75 pixel per frame
        push word 1
        call EntWalk
        jmp .next
.shell: cmp word [si+E_TIMER], 0
        jle .s1
        dec word [si+E_TIMER]    ; kick grace time
.s1:    cmp word [si+E_STATE], 1
        jne .next
        push si
        push word 0x0300         ; 3 pixels per frame
        push word 0
        call EntWalk
        jmp .next
.mush:  push si
        push word 0x0100         ; 1 pixel per frame
        push word 0
        call EntWalk
        jmp .next
.remove:
        mov word [si+E_TYPE], 0
.next:  add si, ENT_SIZE
        cmp si, ents_end
        jae ..@j8   ; long jump: inverted short jump + near jmp
        jmp near .loop
..@j8:
        popa
        ret

; HeroVsEnts : stomp / hurt / kick / collect (Section 5.6)
HeroVsEnts:
        pusha
        mov si, ents
.loop:  mov ax, [si+E_TYPE]
        or  ax, ax
        jnz ..@j7   ; long jump: inverted short jump + near jmp
        jmp near .next
..@j7:
        cmp ax, 4
        je  .check
        cmp ax, 3
        je  .shchk
        cmp word [si+E_STATE], 1 ; walking enemies only
        je ..@j6   ; long jump: inverted short jump + near jmp
        jmp near .next
..@j6:
        jmp .check
.shchk: cmp word [si+E_TIMER], 0 ; kick grace: shell ignores Mario
        jle ..@j5   ; long jump: inverted short jump + near jmp
        jmp near .next
..@j5:
.check: mov ax, [mx]
        add ax, 2
        push ax
        push word [my]
        push word 12
        push word [hh]
        push word [si+E_X]
        push word [si+E_Y]
        push word 16
        push word 16
        call Overlap
        or  al, al
        jnz ..@j4   ; long jump: inverted short jump + near jmp
        jmp near .next
..@j4:
        mov ax, [si+E_TYPE]
        cmp ax, 4
        jne ..@j3   ; long jump: inverted short jump + near jmp
        jmp near .mush
..@j3:
        cmp ax, 3
        jne .enemy
        cmp word [si+E_STATE], 0
        jne ..@j2   ; long jump: inverted short jump + near jmp
        jmp near .kick
..@j2:
.enemy: cmp word [vy], 0         ; stomp test: falling ...
        jle .hurt
        mov ax, [si+E_Y]
        add ax, 8
        cmp [old_feet], ax       ; ... and feet were above the upper half
        jg  .hurt
        mov bx, [chain]
        cmp bx, 10
        jae .oneup
        shl bx, 1
        push word [chain_tab+bx] ; chain table: 100,200,400,500,800 ...
        call AddScore
        jmp .sc
.oneup: call AddLife             ; 11th stomp and more: 1-UP
.sc:    inc word [chain]
        mov word [vy], BOUNCE
        cmp byte [keys+KEY_SPACE], 0
        je  .bn
        mov word [vy], BOUNCEHI  ; jump key held = higher bounce
.bn:    mov byte [onground], 0
        mov ax, [si+E_TYPE]
        cmp ax, 1
        jne .k
        mov word [si+E_STATE], 2 ; flat Goomba
        mov word [si+E_TIMER], 30
        jmp .next
.k:     cmp ax, 2
        jne .sh
        mov word [si+E_TYPE], 3  ; Koopa becomes a stationary shell
        mov word [si+E_STATE], 0
        mov word [si+E_TIMER], 8
        jmp .next
.sh:    mov word [si+E_STATE], 0 ; sliding shell is stopped
        mov word [si+E_TIMER], 8
        jmp .next
.hurt:  cmp word [state], ST_PLAY
        jne .next
        call HurtHero
        jmp .next
.kick:  push word 400
        call AddScore
        mov word [si+E_STATE], 1
        mov word [si+E_TIMER], 8
        mov word [si+E_DIR], 1   ; slide away from Mario
        mov ax, [mx]
        add ax, 8
        mov bx, [si+E_X]
        add bx, 8
        cmp ax, bx
        jl  .next
        mov word [si+E_DIR], -1
        jmp .next
.mush:  push word 1000
        call AddScore
        call GrowHero
        mov word [si+E_TYPE], 0
.next:  add si, ENT_SIZE
        cmp si, ents_end
        jae ..@j1   ; long jump: inverted short jump + near jmp
        jmp near .loop
..@j1:
        popa
        ret

; DrawEnts : draw every visible entity (camera x subtracted from world x)
DrawEnts:
        pusha
        mov si, ents
.l:     mov ax, [si+E_TYPE]
        or  ax, ax
        jz  .n
        mov bx, [si+E_X]
        sub bx, [cam]            ; screen x
        cmp bx, -16
        jle .n
        cmp bx, SCRW
        jge .n
        xor dx, dx               ; flags
        mov cx, spr_goomba
        cmp ax, 1
        jne .k
        cmp word [si+E_STATE], 2
        jne .gw
        mov cx, spr_flat
        jmp .draw
.gw:    test byte [ticks], 8     ; two walking frames by mirroring
        jz  .draw
        mov dx, 1
        jmp .draw
.k:     cmp ax, 2
        jne .s
        mov cx, spr_koopa        ; the artwork faces left
        cmp word [si+E_DIR], 0
        jl  .draw
        mov dx, 1
        jmp .draw
.s:     cmp ax, 3
        jne .m
        mov cx, spr_shell
        jmp .draw
.m:     mov cx, spr_mush
.draw:  push bx
        push word [si+E_Y]
        push cx
        push dx
        call DrawSprite
.n:     add si, ENT_SIZE
        cmp si, ents_end
        jb  .l
        popa
        ret
; ===========================================================================
; MODULES 13, 14, 15 : HUD, state machine, screens, win / lose / restart
; ===========================================================================
POLEX       equ 928              ; world x of the flag pole column (58*16)

; ResetLevel : map, enemies, mushrooms, clock, camera and hero back to start.
; Uses block moves (REP MOVSB / REP MOVSW) to copy the untouched originals.
ResetLevel:
        pusha
        push es
        mov ax, ds
        mov es, ax
        cld
        mov si, map_orig
        mov di, map_work
        mov cx, MAPW*MAPH
        rep movsb
        mov si, ent_init
        mov di, ents
        mov cx, NENT*ENT_SIZE/2
        rep movsw
        mov word [mx], 32        ; Mario starts at world x = 32, on row 9
        mov word [my], 144
        mov byte [mxf], 0
        mov byte [myf], 0
        mov word [vx], 0
        mov word [vy], 0
        mov byte [face], 0
        mov byte [onground], 1
        mov byte [form], 0       ; always Small Mario after a death
        mov byte [hp], 1
        mov word [hh], 16
        mov word [invuln], 0
        mov word [chain], 0
        mov byte [jlock], 1
        mov byte [flag_hit], 0
        mov word [cam], 0
        mov word [time], 300
        mov word [clk], 0
        mov word [wphase], 0
        pop es
        popa
        ret

; NewGame : score, coins and lives too
NewGame:
        mov word [score_lo], 0
        mov word [score_hi], 0
        mov word [coins], 0
        mov word [lives], 3
        call ResetLevel
        ret
; ---------------------------------------------------------------------------
; DrawHero : picks the pose, mirrors it, blinks while invulnerable.
; Super Mario is the same bitmap stretched to 16 x 32 (flag bit 2).
; ---------------------------------------------------------------------------
DrawHero:
        pusha
        cmp word [state], ST_WIN
        jne .norm
        cmp word [wphase], 0
        jne .out                 ; he disappears while "walking to the castle"
.norm:  cmp word [invuln], 0
        je  .vis
        test byte [invuln], 1    ; blink: draw on alternate frames only
        jnz .out
.vis:   mov bx, [mx]
        sub bx, [cam]
        mov cx, spr_mstand
        cmp word [state], ST_DYING
        je  .jump
        cmp byte [onground], 0
        jne .gr
.jump:  mov cx, spr_mjump
        jmp .fl
.gr:    cmp word [vx], 0
        je  .fl
        test byte [ticks], 4     ; walking animation
        jz  .fl
        mov cx, spr_mrun
.fl:    xor dx, dx
        cmp byte [face], 0
        je  .f2
        or  dx, 1
.f2:    cmp byte [form], 1
        jne .d
        or  dx, 4
.d:     push bx
        push word [my]
        push cx
        push dx
        call DrawSprite
.out:   popa
        ret

; DrawHUD : the top 16 pixel strip, two text lines
DrawHUD:
        pusha
        push word 0
        push word 0
        push word 320
        push word 16
        push word 0
        call FillRect
        push word 0
        push word 0
        push word s_score
        push word 7
        call DrawText
        push word 48
        push word 0
        push word [score_hi]
        push word [score_lo]
        push word 6
        push word 8
        call DrawNum
        push word 104
        push word 0
        push word s_coins
        push word 7
        call DrawText
        push word 160
        push word 0
        push word 0
        push word [coins]
        push word 2
        push word 8
        call DrawNum
        push word 200
        push word 0
        push word s_time
        push word 7
        call DrawText
        push word 240
        push word 0
        push word 0
        push word [time]
        push word 3
        push word 8
        call DrawNum
        push word 0
        push word 8
        push word s_lives
        push word 7
        call DrawText
        push word 56
        push word 8
        push word 0
        push word [lives]
        push word 2
        push word 8
        call DrawNum
        push word 120
        push word 8
        push word s_world
        push word 7
        call DrawText
        push word 224
        push word 8
        push word s_health
        push word 7
        call DrawText
        mov ax, 13               ; heart 1: filled if hp >= 1
        cmp byte [hp], 1
        jb  .h1
        mov ax, 4
.h1:    push word 280
        push word 8
        push word 3              ; character 3 of the ROM font is a heart
        push ax
        call DrawChar
        mov ax, 13               ; heart 2: filled if hp = 2
        cmp byte [hp], 2
        jb  .h2
        mov ax, 4
.h2:    push word 288
        push word 8
        push word 3
        push ax
        call DrawChar
        popa
        ret

; DrawWorld : steps 9 of the frame order (clear, map, items, hero, HUD)
DrawWorld:
        pusha
        push word 1              ; sky colour
        call ClearFB
        push word 0
        push word 192
        push word 320
        push word 8
        push word 0
        call FillRect            ; bottom 8 pixels stay black
        push word [cam]
        call DrawMap
        mov ax, POLEX-8          ; green flag on the pole, scrolls with world
        sub ax, [cam]
        push ax
        push word 34
        push word 15
        push word 10
        push word 9
        call FillRect
        call DrawEnts
        call DrawHero
        call DrawHUD
        popa
        ret

; DrawBox : bordered panel used by the end screens
DrawBox:
        push word 8
        push word 8
        push word 304
        push word 184
        push word 8
        call FillRect
        push word 12
        push word 12
        push word 296
        push word 176
        push word 0
        call FillRect
        ret


