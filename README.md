# Proper 3rd Person Camera — Resident Evil 9: Requiem

Pulls the third-person camera further back for a wider view of the action. Modifies the game's internal camera distance parameter so wall collision works natively at the extended distance.

## Features

- Adjustable camera distance multiplier (1x to 3x, default 3x)
- Full wall collision at the extended distance — handled by the game engine
- Only affects movement states (walking, running, crouching)
- Aiming, cutscenes, and special actions keep their vanilla camera distance
- Settings persist across sessions
- Real-time adjustment via the REFramework menu

## Requirements

- [REFramework](https://www.nexusmods.com/residentevilrequiem/mods/13)

## Installation

1. Install REFramework if you haven't already
2. Extract the `reframework` folder from this mod into your game directory:
   ```
   RESIDENT EVIL requiem BIOHAZARD requiem/
     reframework/
       autorun/
         proper_3rd_person_camera.lua
   ```
3. Launch the game

## Usage

- Press **Insert** to open the REFramework menu
- Go to **Script Generated UI** > **Proper 3rd Person Camera**
- Use the **Distance Multiplier** slider to adjust how far back the camera sits
- Toggle **Enabled** to turn the mod on/off

> **Note:** Slider changes need a quick stance change to take effect — aim briefly, crouch, or run. You can also restart from the game menu. Once set, the value persists and applies automatically on game load.

## Uninstall

Delete `reframework/autorun/proper_3rd_person_camera.lua` from your game directory.
