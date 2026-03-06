# ============================================================
#  Blender JSON Exporter
#  Version 1.0
#
#  Created by Claude (Anthropic)
#  under the leadership of Kruglov Iurii
# ============================================================
#
#  Exports selected objects (transforms + animation +
#  collection hierarchy) to JSON for import into 3ds Max.
#
#  USAGE
#  -----
#  Install via Edit -> Preferences -> Add-ons -> Install...
#  Panel: View3D -> Sidebar -> Hierarchy tab
#  Select objects to export, then click "Export JSON".
# ============================================================

import bpy
import json
import math
from bpy.props import StringProperty
from bpy_extras.io_utils import ExportHelper

bl_info = {
    "name":        "Blender JSON Exporter",
    "author":      "Claude (Anthropic) / Kruglov Iurii",
    "version":     (1, 0, 0),
    "blender":     (3, 0, 0),
    "location":    "View3D > Sidebar > Hierarchy",
    "description": "Export selected objects (transforms + animation + collections) to JSON for 3ds Max",
    "category":    "Import-Export",
}


# ── Keyframe helpers ──────────────────────────────────────────────────────────

def _fcurve_keys(obj, data_path, index):
    """Return list of {frame, value} dicts for a specific fcurve channel."""
    if obj.animation_data is None or obj.animation_data.action is None:
        return []
    for fc in obj.animation_data.action.fcurves:
        if fc.data_path == data_path and fc.array_index == index:
            return [{"frame": kp.co[0], "value": kp.co[1]} for kp in fc.keyframe_points]
    return []


def _export_object(obj):
    """Build the transform + animation dict for one object."""
    loc   = obj.location
    rot   = obj.rotation_euler      # always radians, in rotation_mode order
    sc    = obj.scale
    mode  = obj.rotation_mode       # 'XYZ', 'YZX', etc. or 'QUATERNION'

    # Quaternion mode: convert to euler XYZ for compatibility
    if mode == 'QUATERNION':
        euler = obj.rotation_quaternion.to_euler('XYZ')
        rot   = euler
        mode  = 'XYZ'

    parent_name = obj.parent.name if obj.parent else ""

    return {
        "parent":         parent_name,
        "rotation_mode":  mode,
        "location":       [loc.x,   loc.y,   loc.z],
        "rotation_euler": [rot[0],  rot[1],  rot[2]],
        "scale":          [sc.x,    sc.y,    sc.z],
        "animation": {
            "location": {
                "X": _fcurve_keys(obj, "location",       0),
                "Y": _fcurve_keys(obj, "location",       1),
                "Z": _fcurve_keys(obj, "location",       2),
            },
            "rotation_euler": {
                "X": _fcurve_keys(obj, "rotation_euler", 0),
                "Y": _fcurve_keys(obj, "rotation_euler", 1),
                "Z": _fcurve_keys(obj, "rotation_euler", 2),
            },
            "scale": {
                "X": _fcurve_keys(obj, "scale",          0),
                "Y": _fcurve_keys(obj, "scale",          1),
                "Z": _fcurve_keys(obj, "scale",          2),
            },
        },
    }


# ── Collection hierarchy (from blender_transfer_hierarchy_with_json.py) ───────

def _export_collections(objects):
    """
    Build the collections block:
      {
        "layers":  { "ChildCol": "ParentCol", "RootCol": "" },
        "objects": { "ObjName": "ColName" }
      }
    Only collections that actually contain any of the exported objects
    (or are ancestors of such collections) are included.
    """
    # Gather all collections that touch the exported objects
    relevant_cols = set()
    obj_to_col = {}

    for obj in objects:
        for col in obj.users_collection:
            obj_to_col[obj.name] = col.name
            # Walk up the collection tree
            relevant_cols.add(col.name)

    # Build parent map for ALL collections in the file
    col_parent = {}
    for col in bpy.data.collections:
        for child in col.children:
            col_parent[child.name] = col.name
        for _ in col.objects:
            pass   # objects handled above

    # Add ancestor collections of relevant ones
    def add_ancestors(col_name):
        parent = col_parent.get(col_name)
        if parent and parent not in relevant_cols:
            relevant_cols.add(parent)
            add_ancestors(parent)

    for col_name in list(relevant_cols):
        add_ancestors(col_name)

    # Build layers dict  { colName: parentColName or "" }
    layers = {}
    for col_name in relevant_cols:
        layers[col_name] = col_parent.get(col_name, "")

    return {
        "layers":  layers,
        "objects": obj_to_col,
    }


# ── Main export function ──────────────────────────────────────────────────────

def do_export(filepath, objects):
    objects_data = {}
    for obj in objects:
        if obj.type not in ('MESH', 'EMPTY', 'ARMATURE', 'CURVE', 'LIGHT', 'CAMERA'):
            continue
        objects_data[obj.name] = _export_object(obj)

    result = {
        "objects":     objects_data,
        "collections": _export_collections(objects),
    }

    with open(filepath, 'w', encoding='utf-8') as fh:
        json.dump(result, fh, indent=2)

    return len(objects_data)


# ── Operator ──────────────────────────────────────────────────────────────────

class EXPORT_OT_blender_json(bpy.types.Operator, ExportHelper):
    bl_idname  = "export.blender_json"
    bl_label   = "Export Blender JSON"
    bl_options = {'REGISTER', 'UNDO'}

    filename_ext = ".json"
    filter_glob: StringProperty(default="*.json", options={'HIDDEN'})

    def execute(self, context):
        objects = list(context.selected_objects)
        if not objects:
            self.report({'WARNING'}, "No objects selected.")
            return {'CANCELLED'}

        count = do_export(self.filepath, objects)
        self.report({'INFO'}, f"Exported {count} objects to {self.filepath}")
        return {'FINISHED'}


# ── Panel ─────────────────────────────────────────────────────────────────────

class VIEW3D_PT_blender_json_exporter(bpy.types.Panel):
    bl_space_type  = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category    = 'Hierarchy'
    bl_label       = 'Transfer hierarchy'

    def draw(self, context):
        col = self.layout.column(align=True)
        col.scale_y = 1.5
        col.operator("export.blender_json",    icon='EXPORT', text="Export JSON")


# ── Registration ──────────────────────────────────────────────────────────────

classes = [
    EXPORT_OT_blender_json,
    VIEW3D_PT_blender_json_exporter,
]


def register():
    for cls in classes:
        bpy.utils.register_class(cls)


def unregister():
    for cls in classes:
        bpy.utils.unregister_class(cls)


if __name__ == "__main__":
    register()
