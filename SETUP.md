Setup Instructions
==================

Markers (slot 1 items, renamed)
-------------------------------
- `ROLE:BUFFER` — working chest for current step (one princess at a time).
- `ROLE:TRASH` — dump dirty drones/garbage.
- `ROLE:ACCLIM` — reagents for acclimatizer (Blaze Rod, Ice, Sand, Water Can).
- `ROLE:BLOCKS` — required hive blocks (optional).
- `ROLE:ME-MAIN` — main ME Interface (slot 1 marker in its inventory AND in interface configuration slot 1).
- `ROLE:ME-BEES` — bee ME Interface (slot 1 marker in its inventory AND in interface configuration slot 1).

Device connections to transposer
--------------------------------
- Apiary/Alveary (inventory name contains `apiculture`/`alveary`).
- Acclimatizer (inventory name contains `labMachine`), slots assumed: 5=princess in, 6=reagent, 9=output.
- Analyzer (inventory name contains `for.core`), slots assumed: input=3, output=9.
- ME interfaces: both main and bee interfaces reachable via transposer side; markers as above.
- Chests with roles (BUFFER/TRASH/ACCLIM/BLOCKS) on transposer sides.

Supplies
--------
- Bee ME must contain clean drones/princesses you already have (at least pure drones for counting).
- Reagents in `ROLE:ACCLIM`: Blaze Rod (HOT/WARM/HELLISH), Ice (COLD/ICY), Sand (ARID), Water Can (DAMP).
- Optional hive blocks in `ROLE:BLOCKS` (not yet used).

Running
-------
1) Place markers in slot 1 of each inventory/interface; for ME interfaces also set interface config slot 1 to the marker.
2) Ensure transposer touches all required devices/storages.
3) Run `main.lua` on the OC computer.
4) Enter target species (exact displayName) or `auto` for discovery mode.

Notes
-----
- Slots are hardcoded: analyzer 3/9, acclimatizer 5/6/9, apiary princess/drone 1/2.
- If markers/slots differ in your setup, adjust code accordingly.
