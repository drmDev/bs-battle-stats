BatoEyes 0.2.0 - battle info overlay for Batomon Showdown
============================================================

What it does
------------
Battle: who you are fighting (name, trainer, MMR, their lives / wins / Day) and
your own team's live damage and DPS, unit by unit.
No hotkeys - the card appears by itself in battles. Read-only: nothing in your run,
saves or matchmaking changes.

Card: drag the header to move it, click the header (or its -/+ button) to minimize it.
Settings: Settings > Mods > BatoEyes (Opponent card in battle, Auto-update).

Updates (new in 0.2.0)
----------------------
BatoEyes updates itself. At every game start it reads a small file from its GitHub
releases (github.com/Maxkii3/BatoEyes). When a newer version is out it downloads it,
checks it (SHA-256, only Mods\BatoEyes text files, every script loads on your game
version) and replaces its own files in Mods\BatoEyes. The new version runs from the next
game start; a notice at the top of the screen tells you.
- Auto-update OFF (Settings > Mods): you only get a notice when a new version is out.
- Required updates: when the author marks your version as too old (for example after a
  game patch broke it), the update installs even with Auto-update off, and BatoEyes
  stays off until you restart the game.
Nothing else is downloaded or sent; the request carries only "BatoEyes/<version>".

Requirement
-----------
The community Batomon Showdown Mod Loader (Mods\mod_loader.gd plus its ModLoader= line in
override.cfg). Install it first.

Install
-------
1. Close the game.
2. Open the game folder (Steam: right-click Batomon Showdown > Manage > Browse local files).
3. Coming from BatoEyes 0.1.0: delete the old Mods\BatoEyes folder first.
4. Extract this zip INTO that folder. You get:
       Mods\BatoEyes\mod_main.gd   (and the other BatoEyes files)
5. Start the game. Mods\mod_loader.log shows "Started ...BatoEyes/mod_main.gd".

This zip contains only Mods\BatoEyes\. It does not contain or replace override.cfg, the
Mod Loader or any other mod.

Uninstall
---------
Delete the Mods\BatoEyes folder. Your settings are kept in the game's user folder
(batoeyes.cfg, and the batoeyes_update folder from updates); delete those too for a clean slate.

Files written
-------------
user://batoeyes.cfg (card position, minimized state, update state), the "batoeyes" section of
the Mod Loader's user://mod_settings.cfg, user://batoeyes_update\ (download checks and a copy of
the version an update replaced) and - only when updating - the files in Mods\BatoEyes.
