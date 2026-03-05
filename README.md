# Blender → 3ds Max JSON Pipeline  
**Version 1.0 — Production**

A lightweight, dependency-free pipeline for transferring rigged hierarchies with animation from Blender to 3ds Max without FBX common issues. It preserves every rotation mode, correct parent–child transforms at any depth, and both rotation and location animation curves.

---

## Overview

Standard FBX export from Blender bakes all rotations to world-space XYZ regardless of the object's actual rotation mode, which destroys the original euler channels and makes animation editing in Max painful. This pipeline exports the raw JSON data — local euler angles, rotation mode, parent name, location keyframes, rotation keyframes — and a MAXScript importer reconstructs everything mathematically, keeping the correct rotation order and local animation curves intact.

```
Blender scene  ──►  blender_export.py  ──►  scene.json  ──►  BlenderJSON_Importer.ms  ──►  3ds Max scene
```

---

## Part 1 — Blender Exporter Add-on

### What it exports

For every selected object the add-on writes:

| Field | Description |
|---|---|
| `location` | World-space position in Blender metres |
| `rotation_euler` | Local euler angles in radians, in the object's own `rotation_mode` order |
| `rotation_mode` | One of `XYZ` `YZX` `ZXY` `XZY` `YXZ` `ZYX` |
| `scale` | Local scale XYZ |
| `parent` | Name of the parent object, or `""` for root objects |
| `animation.location` | Per-axis keyframe arrays `{frame, value}` in metres |
| `animation.rotation_euler` | Per-axis keyframe arrays `{frame, value}` in radians |
| `animation.scale` | Per-axis keyframe arrays `{frame, value}` |

Empty arrays `[]` are written when an axis has no keyframes.

### Installation

1. In Blender open **Edit → Preferences → Add-ons → Install…**
2. Select `blender_json_exporter.py` and click **Install Add-on**.
3. Enable the checkbox next to **Import-Export: Blender JSON Exporter**.

### Usage

1. Select group of the objects you want to export (the exporter processes the current selection).
2. Go to **File → Export → Blender JSON (.json)**.
3. Choose a destination path and click **Export Blender JSON**.
4. The resulting `.json` file is plain UTF-8 text and can be inspected in any text editor.
5. Delete all objects animation, unparent all objects, export this group of objects via standart FBX exporter. Very important to to set a few things in Blender FBX exporter settings, in transrorm tab set Y forward in Forward tab, Z Up in Up tab, also hit checkbox Apply Transform, uncheck Bake Animation. Settings should be as in the screenshot:

<img width="249" height="680" alt="image" src="https://github.com/user-attachments/assets/a44bdb4a-5c85-43e5-adfc-05fea501593f" />


### JSON structure

```json
{
  "Cube": {
    "location": [0.0, 0.0, 0.0],
    "rotation_euler": [1.5708, 0.0, 0.0],
    "rotation_mode": "XYZ",
    "scale": [1.0, 1.0, 1.0],
    "parent": "",
    "animation": {
      "location":       { "X": [], "Y": [], "Z": [] },
      "rotation_euler": { "X": [], "Y": [], "Z": [] },
      "scale":          { "X": [], "Y": [], "Z": [] }
    }
  },
  "Cube.001": {
    "location": [1.095, 0.0, 0.892],
    "rotation_euler": [1.437, -1.946, 0.346],
    "rotation_mode": "YZX",
    "scale": [1.0, 1.0, 1.0],
    "parent": "Cube",
    "animation": {
      "location": { "X": [], "Y": [], "Z": [] },
      "rotation_euler": {
        "X": [{"frame": 0.0, "value": 1.437}, {"frame": 20.0, "value": 1.437}],
        "Y": [{"frame": 0.0, "value": -1.946}, {"frame": 20.0, "value": -2.993}],
        "Z": [{"frame": 0.0, "value": 0.346}, {"frame": 20.0, "value": 0.346}]
      },
      "scale": { "X": [], "Y": [], "Z": [] }
    }
  }
}
```

### Requirements

- Blender 3.x or 4.x  
- No external Python packages required

---

## Part 2 — 3ds Max Importer Script

### What it does

`BlenderJSON_Importer_v1.0.ms` reads the exported JSON and applies transforms to objects that already exist in the Max scene (imported separately, e.g. via FBX for mesh geometry). It:

- Sets the correct Euler rotation order on every object's rotation controller
- Computes local rotation values by decomposing the world rotation matrix against the parent transform
- Parents objects in topological order (parents before children) so Max world-pos preservation works correctly
- Writes Bezier rotation keyframes — per-frame world matrix is built from the JSON euler curves, decomposed to local sub-controller angles
- Writes Bezier position keyframes — world positions are converted to local space via `inverse(parent.transform)`
- Writes scale keyframes
- Converts Blender metres to 3ds Max centimetres automatically (× 100)

### Rotation math

Blender stores rotations as local euler angles in a user-chosen order. The importer builds the world rotation matrix for each object as:

```
W = R1(a1) * R2(a2) * R3(a3)   -- in the object's rotation_mode order
```

Local rotation relative to the parent is:

```
L = W * inverse(parent_W)
```

`L` is then decomposed back to sub-controller angles using analytic Euler decomposition matching the same rotation order — no `quatToEuler`, no gimbal flipping from order mismatches.

### Import passes

The importer runs six sequential passes to ensure correct transform propagation at every hierarchy depth:

| Pass | Action |
|---|---|
| **Pre-pass** | Build world rotation matrix dictionary for all objects from JSON static angles |
| **1a** | Set Euler rotation order (`axisOrder`) on every node — all objects still unparented |
| **1b** | Set rotation values — objects are unparented so local space equals world space |
| **1c** | Set scale values |
| **1d** | Parent objects — Max preserves world position automatically |
| **2** | Write rotation & scale animation keyframes |
| **3** | Write location animation keyframes (separate pass, after all rotations are committed) |

Location animation is in its own final pass because `inverse(node.parent.transform)` must be evaluated after all parent rotations and parenting relationships are fully established.

### Installation

1. Copy `BlenderJSON_Importer_v1.0.ms` anywhere on your machine.
2. In 3ds Max open the **MAXScript Editor** (`Scripting → MAXScript Editor`) or use `Scripting → Run Script…`.
3. Run the script once — a small floating dialog appears.

Alternatively, drag and drop the `.ms` file into the Max viewport.

### Usage

1. **Import your mesh geometry first** — via FBX as stated above — so the named objects already exist in the scene. The script matches objects by name.
2. Open the **Blender JSON Importer** dialog (run the script if it is not open).
3. Click **Browse…** and select your exported `.json` file.
4. Click **Import**.
5. A confirmation dialog appears when the import is complete. It will take a few long minutes. Check the MAXScript Listener for any warnings.

> **Important:** Object names in Max must exactly match the object names in the JSON. The matching is case-sensitive.

### Requirements

- 3ds Max 2018 or newer (uses `Dictionary`, `Euler_XYZ` family controllers, `addNewKey`)
- No third-party plug-ins required
- The script is self-contained — the JSON parser is built in

---

## Supported features

| Feature | Supported |
|---|---|
| All 6 Blender euler rotation orders | ✅ |
| Arbitrary hierarchy depth | ✅ |
| Static rotation, position, scale | ✅ |
| Rotation animation (all euler orders) | ✅ |
| Location animation | ✅ |
| Scale animation | ✅ |
| Root objects (no parent) | ✅ |
| Multiple root objects | ✅ |
| Blender m → Max cm unit conversion | ✅ |
| Quaternion rotation mode | ❌ (not exported) |
| Mesh geometry transfer | ❌ (use FBX for mesh, JSON for transforms) |
| Shape keys / morph targets | ❌ |
| Constraints | ❌ |

---

## Typical workflow

```
1. Build and rig your scene in Blender.
2. Export mesh geometry to FBX.
3. Export transforms + animation to JSON with the add-on.
4. Import the FBX into 3ds Max (geometry only, suppress animation).
5. Run BlenderJSON_Importer_v1.0.ms, browse to the JSON, click Import.
   → Hierarchy, rotations, and animation are applied to the existing meshes.
```


