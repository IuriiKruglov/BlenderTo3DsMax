# Legacy: Blender JSON Exporter 1.0 + 3ds Max importer 1.1.1

These are the first tools of this project, kept for anyone still using them. The **[Blender → 3ds Max Bridge](../README.md)** replaces them: it sends geometry too, rebuilds armatures as Dummy + Skin, and works with one button.

| File | Runs in | What it does |
|---|---|---|
| `blender_json_exporter.py` | Blender | *File → Export → Blender JSON (.json)*: writes the selected objects' hierarchy, rotation orders, transforms, keyframes and collections to a JSON file |
| `BlenderJSON_Importer_v1.1.1.ms` | 3ds Max | Applies that JSON to the objects already in the scene (import the geometry with FBX first): parenting, rotation orders, transforms and keys, collections as layers |

Do not enable the old *Blender JSON Exporter* add-on together with the bridge add-on.

Created by Claude (Anthropic) under the leadership of Kruglov Iurii. Licensed under the GNU GPL v3, like the rest of the repository.
