-- The five greys every Reading Atlas card paints with, light to dark.
--
-- Five steps is the ceiling for what is reliably distinguishable on e-ink at
-- card size, validated on a Kindle Paperwhite; step 0 is a light grey rather
-- than white, so an empty day or an unread book still reads as a cell. Both
-- gridwidget.lua and stripwidget.lua paint from this one table, so retuning
-- for another panel changes every card together.
return { [0] = 0xE0, [1] = 0xB0, [2] = 0x80, [3] = 0x50, [4] = 0x20 }
