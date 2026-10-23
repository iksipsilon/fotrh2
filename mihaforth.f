: FORGET
        WORD FIND  ( find the word, gets the dictionary entry address )
        DUP @ LATEST !  ( set LATEST to point to the previous word           )
        HERE !  ( and store HERE with the dictionary address       )
;
