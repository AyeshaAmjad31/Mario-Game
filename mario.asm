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