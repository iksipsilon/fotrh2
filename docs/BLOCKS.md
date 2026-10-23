# Editing, saving, and erasing blocks

A **block** (or **screen**) is 1 KiB of source text in flash: 16 lines of
64 characters. There are 38 of them, numbered 1..38. Block 1 runs
automatically at every boot, so it is where your permanent words live.

Everything happens through **one buffer** in RAM. You pull a block into the
buffer, edit the buffer, then flush the buffer back to flash. Only one block
is in the buffer at a time.

## First, three Forth facts that trip everyone up

1. **Forth runs words, not English.** `THE 8 - .` fails because `THE` is not
   a defined word. Only type words that exist (or numbers).
2. **Numbers come first, word second.** It is `8 BLOCK`, never `BLOCK 8`.
   `3 P ...` puts line 3. This is postfix ("reverse Polish") — the whole
   language works this way.
3. **Kernel words are UPPERCASE and case-sensitive.** `two` and `TWO` are
   different words; `emit` is undefined, `EMIT` is not.

## The five editor words

| Word              | Stack        | What it does                                  |
|-------------------|--------------|-----------------------------------------------|
| `n BLOCK DROP`    | ( n -- )     | Load block *n* into the buffer                |
| `CLEAN`           | ( -- )       | Blank the whole buffer (fill with spaces)     |
| `n P your text`   | ( n -- )     | Put the rest of the line into line *n*        |
| `L`               | ( -- )       | List the buffer, all 16 lines                 |
| `FLUSH`           | ( -- )       | Write the buffer to flash                     |

`BLOCK` leaves the buffer address on the stack for programs to use; when you
are just editing, always follow it with `DROP` (see the gotcha at the end).

## Edit and save a block

Say we want block 3 to define a word `SQUARE`:

    3 BLOCK DROP          ok        \ pull block 3 into the buffer
    CLEAN                 ok        \ blank it
    0 P : SQUARE DUP * ;  ok        \ line 0 = the definition
    1 P 5 SQUARE .        ok        \ line 1 = a quick self-test
    L                               \ look at it

    0 : SQUARE DUP * ;
    1 5 SQUARE .
    2
    ... (blank to 15)
                          ok
    FLUSH                 ok        \ burn it to flash — now permanent

`P` copies the rest of the line **literally**, including spaces, up to where
you press Enter. To fix one line, just `P` it again — no need to `CLEAN`
first:

    1 P 9 SQUARE .        ok        \ replace line 1 only
    FLUSH                 ok

## Run a block

    3 LOAD                          \ interpret block 3: defines SQUARE,
                                    \ then the self-test prints 25

`LOAD` reads the block as if you had typed it. After it finishes, input
returns to the keyboard. A block can hand off to another by ending with,
e.g., `4 LOAD` as its last words.

## Make words survive reset

Put their source in **block 1** — it auto-loads at boot:

    1 BLOCK DROP
    CLEAN
    0 P : SQUARE DUP * ;
    FLUSH

Power-cycle, and `SQUARE` is defined before you type anything. To chain more
screens, end block 1's text with `3 LOAD` and keep the rest in block 3.

## Erase a block

Blank it and flush:

    5 BLOCK DROP CLEAN FLUSH        \ block 5 is now empty

This is also how you clean up a block that shows garbage `����` — that is
just old/erased flash content; `CLEAN FLUSH` overwrites it with spaces.

## Recover from a stuck prompt

If a block (or a line you typed) opens a colon definition without closing it,
the prompt changes from ` ok` to `] ` — you are in **compile mode**, and
words are being compiled instead of run. Type a single `;` to close the
definition and get back to ` ok`. To skip a broken boot block entirely,
**hold any key while resetting the board**, then `1 BLOCK DROP CLEAN FLUSH`.

## The one gotcha you already hit

`BLOCK` pushes an address. If you type `8 BLOCK` and then `L` without a
`DROP`, that address just sits on the stack, and every bare `n BLOCK` piles
another one on. It is harmless until some later word consumes the wrong
value. Either always type `n BLOCK DROP`, or clear the stack when it feels
cluttered. (There is no `.S` yet; `DROP DROP DROP` a few times, or just reset
— nothing on the data stack is persistent.)
