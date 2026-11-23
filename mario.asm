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
