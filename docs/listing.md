# Listing (0.2.0 draft, from the tested build)

Title: Horizon Strike
Tagline: Hunt Horizon Zero Dawn's machines across its real world with Counter-Strike 2 guns, kill money and the buy wheel.

## Description (Markdown)

Walk out of Mother's Heart into **Horizon Zero Dawn's own world** and hunt its machines with **Counter-Strike 2's arsenal**.

**What's in it**
- **Horizon's world, read from your copy of Horizon Zero Dawn Complete Edition:** the real terrain of all 340 main-world tiles with Horizon's own snow, grass, dirt and rock layers and normal maps, Horizon's sky, sun and fog at a fixed morning hour, rocks, ruins, Nora huts and campfires on their original places, trees and undergrowth placed from the game's own density and snow maps, Horizon's music.
- **Six of Horizon's machines:** Watcher, Strider, Grazer, **Sawtooth, Scrapper and Broadhead**, with their real models, skeletons and textures, at their real sites. Each walks, runs, turns, grazes, attacks, flinches and falls with its own procedural animation on its real skeleton. Watchers patrol and go suspicious → alert → attack; Sawtooths stalk and charge; Scrappers ping their radar, call the pack and fire laser bursts; Broadheads charge to defend their herd; Striders and Grazers flee. Hit the weak spots (Watcher eye, blaze canisters, Scrapper power cell and radar) for headshot damage.
- **Counter-Strike 2's guns, read from your CS2 install:** real first-person models with CS2's own viewmodel animations, sounds, damage, fire rate, recoil, clip sizes and prices: knife, Glock, P250, Desert Eagle, MP9, UMP-45, Galil AR, AK-47, M4A1-S, AWP, Nova, HE grenade, Molotov and Kevlar.
- **CS economy:** start with knife, Glock and $800; every machine kill pays the CS2 kill award of your weapon class × the machine's bounty (max $16,000). Press **B** for the buy wheel (not in combat).
- **Death:** you respawn at the last campfire you visited with knife and Glock; other weapons are lost, money stays.

**Smooth streaming:** new areas load in small steps in the background (textures pre-compressed, shaders compiled on the loading screen, occlusion culling and far-distance proxies), and the converter slows itself down while you play.

**First start:** the mashup converts your own game files into a local cache (about 1.5 minutes until you can play, ~0.8 GB). The rest of the world converts in the background as you approach it; the cache limit (default 4 GB) can be changed in the Esc menu. Nothing from either game is included in the download.

**Needs:** Counter-Strike 2 and Horizon Zero Dawn Complete Edition (Steam, original 2020 PC version) installed. If Horizon isn't found, the game tells you on screen. Counter-Strike 2 is never started or modified – only its files are read.

**Controls:** WASD move, Shift walk, Ctrl crouch, Space jump, mouse aim/fire, R reload, 1-4 weapons, B buy wheel (click an item, or hold B and release over it), F inspect, Esc menu.

**Version 0.2 limits:** solo only; machine motion is our own procedural animation on their real skeletons (Horizon's animation format can't be read); no people, quests, loot or day/night cycle; no Frozen Wilds area.

Made by EM. Code MIT. Built with Godot 4.7.2, ValveResourceFormat, LibAtrac9 and other open-source libraries (see THIRD_PARTY_NOTICES.txt). Built with the help of AI (Claude).
