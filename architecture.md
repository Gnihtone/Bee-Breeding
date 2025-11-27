Architecture for GTNH Bee Breeder (OpenComputers)
==================================================

Devices (detected by inventory name via transposer, role by slot-1 marker)
--------------------------------------------------------------------------
- Apiary/Alveary: main breeding machine.
- Acclimatizer: climate adjustment.
- Analyzer: gene scanner (checks purity, Pristine via `individual.isNatural`).
- ME Interface/Interface (main ME): pulls or crafts required blocks, slot 1 marker `ROLE:ME-MAIN`.
- Bee ME Interface (separate ME): provides bees via `setInterfaceConfiguration` + transposer pull, slot 1 marker `ROLE:ME-BEES`.

Storage roles (marked by item name in slot 1)
---------------------------------------------
- `ROLE:BUFFER`: working area for the current step (only one princess in circulation).
- `ROLE:TRASH`: dump dirty drones.
- `ROLE:BLOCKS`: target-block stock for hive requirements.
- `ROLE:ACCLIM`: items for acclimatizer.
- `ROLE:ME-MAIN`: marker inside main ME interface.
- `ROLE:ME-BEES`: marker inside bee ME interface (bee supply/storage).
- Unmarked storage: treated as auxiliary.

Bee supply via dedicated ME interface
-------------------------------------
- Bees live in a separate ME network. A dedicated ME Interface is marked with `ROLE:ME-BEES` in slot 1.
- To request a bee: call `setInterfaceConfiguration(slot, stack)` on that interface for the desired bee stack, then pull from that slot with a transposer into BUFFER.
- Dirty bees still go to TRASH; clean ones after completion return into the bee ME via the same interface.

ME network separation and mapping
---------------------------------
- Interfaces are distinguished by slot-1 markers: `ROLE:ME-MAIN` vs `ROLE:ME-BEES`. Discovery reads slot 1 via transposer to bind role -> side -> component address.
- No reliance on `setInterfaceConfiguration` ghosts (not visible to transposer). If markers are missing/ambiguous, fall back to a manual override in config.

Data
----
- `bee_mutations.txt`: lines `Child:Parent1,Parent2;climate:...;humidity:...;block:...;dim:...`.
- Indices built: `byChild[child] -> {mutations...}`, `byParents[p1][p2] -> {children...}`.

Purity and availability
-----------------------
- Pure bee: analyzer reports `active.species == inactive.species`.
- Pristine princess: `individual.isNatural == true`. Only pristine princesses are used.
- Availability check: bee stock lives in the bee ME interface (`ROLE:ME-BEES`). Pure princess/drones after production are returned there; local chests are not used as primary bee storage.

Modules
-------
- `discovery`: scan transposers, detect devices by name, storages by role marker.
- `bee_db`: parse mutations, provide requirements, paths to target, list of unknown species.
- `analyzer`: NBT read, `isPure(stack)`, species getter, `isPristinePrincess(stack)`.
- `inventory`: move between storages/devices; pick princess/drone (prefer pure); count pure drones; flush BUFFER -> TRASH (dirty drones).
- `me`: ensureBlock(name) via main ME (pull or craft) into `ROLE:BLOCKS`.
- `me_bees`: configure bee ME interface via `setInterfaceConfiguration`, pull bees into BUFFER, return clean output to bee ME.
- `climate`: check requirements; acclimatize princess with item from `ROLE:ACCLIM` (user-configured reagents per climate/humidity).
- `beekeeper`: apiary state machine using BUFFER only; states LOAD -> WAIT -> COLLECT -> EVAL -> STABILIZE -> REPRO -> DONE.
- `planner`: mutation chain to target considering available pure drones (in bee ME); unknown-species queue for discovery mode.
- `ui`: menu for target selection and status output.

Process per step (child species)
--------------------------------
1) Preparation: move required parents (or ancestor princess + pure child drone) to BUFFER; fix a single princess.
2) Requirements: acclimatize if needed; ensure required block via ME into BLOCKS.
3) Apiary cycle: load pair from BUFFER, wait, return outputs to BUFFER.
4) Stabilize: keep the fixed princess with a drone of target species until princess is pure; prefer pure drones, use dirty only if none.
5) Reproduce: same pure princess + pure drone until >=64 pure drones accumulated.
6) Finish: pure princess + drones -> BEES; dirty drones -> TRASH; clear BUFFER.

Special handling
----------------
- If pure drones of species exist but no princess: use an ancestor princess + pure drone of the species, without switching princess mid-process, until a pure princess appears; then reproduce to 64 drones.
- Discovery mode: iterate mutations whose child species lacks a pure princess.
