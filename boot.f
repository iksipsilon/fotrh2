\ boot.f: interpreted from flash at reset (hold any key during reset to skip).
\ The first sections are jonesforth.f verbatim (uppercase, 1/0 booleans);
\ then classic BLOCK storage built on the FERASE/FPPROG flash primitives.

: / /MOD SWAP DROP ;
: MOD /MOD DROP ;

: TRUE 1 ;
: FALSE 0 ;
: NOT 0= ;

: NEGATE 0 SWAP - ;

: BL 32 ;
: SPACE BL EMIT ;
: CR 13 EMIT 10 EMIT ;

: DECIMAL 10 BASE ! ;
: HEX 16 BASE ! ;

: LITERAL IMMEDIATE ' LIT , , ;

\ Control flow, straight from jonesforth.f: branch offsets are relative to
\ the offset cell, IF leaves the address of its offset cell for THEN to patch.
: IF IMMEDIATE ' 0BRANCH , HERE @ 0 , ;
: THEN IMMEDIATE DUP HERE @ SWAP - SWAP ! ;
: ELSE IMMEDIATE ' BRANCH , HERE @ 0 , SWAP DUP HERE @ SWAP - SWAP ! ;
: BEGIN IMMEDIATE HERE @ ;
: UNTIL IMMEDIATE ' 0BRANCH , HERE @ - , ;
: AGAIN IMMEDIATE ' BRANCH , HERE @ - , ;
: WHILE IMMEDIATE ' 0BRANCH , HERE @ 0 , ;
: REPEAT IMMEDIATE ' BRANCH , SWAP HERE @ - , DUP HERE @ SWAP - SWAP ! ;

\ ( ... ) comments, nestable; 40/41 are ( and )
: ( IMMEDIATE 1 BEGIN KEY DUP 40 = IF DROP 1+ ELSE 41 = IF 1- THEN THEN DUP 0= UNTIL DROP ;

( from here on we can use parenthesised comments )

: RECURSE IMMEDIATE LATEST @ >CFA , ;

: CELLS 4 * ;
: ALLOT ( n -- addr ) HERE @ SWAP HERE +! ;
: VARIABLE 1 CELLS ALLOT WORD CREATE DOCOL , ' LIT , , ' EXIT , ;

\ Numeric output: U. prints unsigned in the current BASE, . adds sign+space
: U. ( u -- ) BASE @ /MOD ?DUP IF RECURSE THEN DUP 10 < IF 48 ELSE 10 - 65 THEN + EMIT ;
: . ( n -- ) DUP 0< IF 45 EMIT NEGATE THEN U. SPACE ;

\ ---- BLOCK storage --------------------------------------------------------
\ Classic single-buffer blocks: 1 KiB screens numbered 1..NBLOCKS living in
\ flash above the kernel.  BLOCK buffers a screen in RAM (BLKBUF), UPDATE
\ marks it dirty, FLUSH erases the 16 flash pages and reprograms them by
\ halfwords.  LOAD points KEY at the block's flash text; interpretation ends
\ at the first 0xFF byte (erased flash), which hands input back to the UART,
\ so a block can chain-load another with "n LOAD" as its last words.

VARIABLE BLK-CUR   0 BLK-CUR !   ( buffered block number, 0 = none )
VARIABLE BLK-DIRTY 0 BLK-DIRTY ! ( 1 = buffer modified since read )
VARIABLE BLK-FA                  ( scratch: flash address during FLUSH )

: BLK-ADDR ( n -- flash-addr ) 1- 1024 * BLOCKS + ;

: WIPE-BLK ( flash-addr -- ) 16 BEGIN SWAP DUP FERASE 64 + SWAP 1- DUP 0= UNTIL 2DROP ;

: PROG-BLK ( flash-addr -- ) BLK-FA ! 0 BEGIN
    DUP 64 * BLKBUF OVER + SWAP BLK-FA @ + FPPROG
    1+ DUP 16 >= UNTIL DROP ;

: SAVE-BUFFERS ( -- ) BLK-DIRTY @ IF
    BLK-CUR @ 0> IF BLK-CUR @ BLK-ADDR DUP WIPE-BLK PROG-BLK THEN
    0 BLK-DIRTY ! THEN ;

: EMPTY-BUFFERS ( -- ) 0 BLK-CUR ! 0 BLK-DIRTY ! ;

: FLUSH ( -- ) SAVE-BUFFERS EMPTY-BUFFERS ;

: BLOCK ( n -- addr ) DUP 1 < OVER NBLOCKS > OR IF
      DROP 63 EMIT BLKBUF EXIT THEN     ( out of range: "?", buffer unchanged )
    DUP BLK-CUR @ = IF DROP BLKBUF EXIT THEN
    SAVE-BUFFERS
    DUP BLK-ADDR BLKBUF 1024 CMOVE
    BLK-CUR ! 0 BLK-DIRTY ! BLKBUF ;

: UPDATE ( -- ) 1 BLK-DIRTY ! ;

: LOAD ( n -- ) FLUSH BLK-ADDR DUP 1024 + KEYEND ! KEYSRC ! ;

\ ---- Screen editor --------------------------------------------------------
\ The classic minimum: a block is 16 lines of 64 characters.
\   n BLOCK DROP    pull screen n into the buffer
\   CLEAN           blank the whole buffer
\   3 P : TWO 2 ;   put the rest of the line as line 3 (space padded)
\   L               list the buffer
\   FLUSH           write it to flash
\ Persistent words = their source on a screen; block 1 runs at every boot.

VARIABLE EDP
VARIABLE EDLIM

: BLANKS ( addr n -- ) BEGIN DUP 0> WHILE SWAP BL OVER C! 1+ SWAP 1- REPEAT 2DROP ;
: (LINE) ( n -- addr ) 64 * BLKBUF + ;
: CLEAN ( -- ) BLKBUF 1024 BLANKS UPDATE ;
: P ( n -- ) (LINE) DUP 64 BLANKS DUP EDP ! 64 + EDLIM !
    BEGIN KEY DUP 10 <> WHILE
      EDP @ EDLIM @ < IF EDP @ C! 1 EDP +! ELSE DROP THEN
    REPEAT DROP UPDATE ;
: .2 ( n -- ) 10 /MOD 48 + EMIT 48 + EMIT ;   ( two-digit, zero padded )
: L ( -- ) CR 66 EMIT 76 EMIT 75 EMIT SPACE BLK-CUR @ . CR   ( "BLK n" header )
    0 BEGIN DUP 16 < WHILE DUP .2 SPACE DUP (LINE) 64 TELL CR 1+ REPEAT DROP ;

\ Boot: run the startup screen if one exists (an erased block 1 is a no-op).
\ This must be the last line: LOAD redirects the input source.
1 LOAD
