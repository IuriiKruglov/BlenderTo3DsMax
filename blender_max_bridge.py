# ============================================================
#  Blender -> 3ds Max Bridge  (Blender add-on)
#  Version 2.3
#
#  Created by Claude (Anthropic)
#  under the leadership of Kruglov Iurii
# ============================================================
#
#  One button in Blender -> result in 3ds Max.
#
#  "Send to 3ds Max" does, in this order:
#    1. Remembers the scene state (frame, selection, parents,
#       transforms, actions, NLA, drivers, constraints, pose
#       position of armatures).
#    2. Goes to the pose frame (default 0, the frame 3ds Max reads)
#       and writes the JSON: names, hierarchy, rotation order,
#       transforms, per-axis animation keys, collections, and the
#       parent space of children parented while their parent had
#       another pose ("parent_space", new in 2.3).
#    3. Armatures (option "Bones -> Dummies + Skin", on by default):
#       every deform bone becomes a 3ds Max Dummy (Z forward, Y up,
#       scale 100 %, bone hierarchy kept), with its animation as
#       dummy keys, and every mesh deformed by the armature gets a
#       Skin modifier with the painted weights (normalized exactly
#       like Blender's Armature modifier).
#    4. Mutes all constraints, removes animation (unassigns actions,
#       disables NLA and transform drivers), puts converted
#       armatures in REST pose, clears parents with "keep
#       transform", selects the objects and exports the FBX:
#       Forward Y, Up Z, Apply Unit, Use Space Transform,
#       Apply Transform, Apply Scalings = All Local.
#    5. Restores the scene exactly as it was and checks it.
#    6. Drops a job file into the bridge folder. The 3ds Max
#       listener (BlenderMaxBridge_v2.3.ms) imports the FBX,
#       applies the JSON and writes back a result, shown in the
#       Max Bridge panel.
#
#  Compatible with Blender 3.6 - 5.2 (animation keys are read
#  through slotted actions on 4.4+, Action.fcurves before that).
#
#  The JSON keeps the v1 layout (plus "armatures" and "skins"),
#  so BlenderJSON_Importer_v1.1.1.ms can still read the objects.
#
#  INSTALL: Edit > Preferences > Add-ons > Install (from Disk),
#  pick this .py file, enable "Blender -> 3ds Max Bridge".
#  Disable the old "Blender JSON Exporter" add-on.
#  UI: View3D > Sidebar (N) > Max Bridge,
#      File > Export > "Send to 3ds Max (FBX + JSON)"
#      File > Export > "Blender JSON (.json)"
# ============================================================

bl_info = {
    "name":        "Blender -> 3ds Max Bridge",
    "author":      "Claude (Anthropic) under the leadership of Kruglov Iurii",
    "version":     (2, 3, 0),
    "blender":     (3, 6, 0),
    "location":    "View3D > Sidebar > Max Bridge  |  File > Export",
    "description": "One-click transfer of objects, hierarchy, rotation orders, animation keys, "
                   "collections and armatures (as dummies + Skin) to 3ds Max (FBX + JSON)",
    "category":    "Import-Export",
}

import json
import math
import os
import re
import tempfile
import time
import uuid

import bpy
from bpy.props import (BoolProperty, EnumProperty, IntProperty,
                       PointerProperty, StringProperty)
from bpy_extras.io_utils import ExportHelper
from mathutils import Matrix, Quaternion, Vector

ADDON_VERSION = "2.3"
JSON_FORMAT = "BlenderMaxBridge"
JSON_VERSION = 3
JOB_FORMAT = "BlenderMaxBridgeJob"

JOB_FILE = "job.json"
RESULT_FILE = "result.json"
HEARTBEAT_FILE = "listener.json"
HEARTBEAT_MAX_AGE = 10.0          # seconds; Max rewrites it every ~2 s

PICKUP_TIMEOUT_OFFLINE = 30.0     # listener not running: give up after this
PICKUP_TIMEOUT_ONLINE = 180.0     # listener alive but busy: wait this long
RESULT_TIMEOUT = 1800.0           # import itself may take a while on big scenes

# Object types the FBX exporter writes with object_types = all six groups.
FBX_TYPES = {'EMPTY', 'CAMERA', 'LIGHT', 'ARMATURE', 'MESH',
             'CURVE', 'SURFACE', 'FONT', 'META'}
AXES = ("X", "Y", "Z")


# ─────────────────────────────────────────────────────────────────────────────
#  Paths and preferences
# ─────────────────────────────────────────────────────────────────────────────

def default_bridge_dir():
    base = os.environ.get("LOCALAPPDATA") or tempfile.gettempdir()
    return os.path.join(base, "BlenderMaxBridge")


def _prefs():
    try:
        addon = bpy.context.preferences.addons.get(__name__)
        return addon.preferences if addon else None
    except Exception:
        return None


def bridge_dir():
    p = _prefs()
    path = bpy.path.abspath(p.bridge_dir) if (p and p.bridge_dir.strip()) else default_bridge_dir()
    return os.path.normpath(path)


def _resolve_output(settings):
    """Folder and base file name for the FBX/JSON pair."""
    folder = settings.output_dir.strip()
    if folder:
        folder = bpy.path.abspath(folder)
    elif bpy.data.filepath:
        folder = os.path.dirname(bpy.data.filepath)
    else:
        folder = os.path.join(bridge_dir(), "exports")
    base = settings.base_name.strip()
    if not base:
        base = bpy.path.display_name_from_filepath(bpy.data.filepath) if bpy.data.filepath else "untitled"
    base = bpy.path.clean_name(base)
    return os.path.normpath(folder), base


def listener_status():
    """(alive, seconds since last heartbeat or None)."""
    path = os.path.join(bridge_dir(), HEARTBEAT_FILE)
    try:
        age = time.time() - os.path.getmtime(path)
    except OSError:
        return False, None
    return age <= HEARTBEAT_MAX_AGE, age


# ─────────────────────────────────────────────────────────────────────────────
#  Compact JSON writer
#  Plain decimals only (no exponent notation), one object per line.
# ─────────────────────────────────────────────────────────────────────────────

def _num(v):
    v = float(v)
    if not math.isfinite(v) or abs(v) < 1e-12:
        return "0"
    s = ("%.10f" % v).rstrip("0").rstrip(".")
    return "0" if s in ("", "-0") else s


def _str(s):
    return json.dumps(str(s), ensure_ascii=False)


def _dump(v):
    if isinstance(v, dict):
        return "{" + ",".join(_str(k) + ":" + _dump(x) for k, x in v.items()) + "}"
    if isinstance(v, (list, tuple)):
        return "[" + ",".join(_dump(x) for x in v) + "]"
    if isinstance(v, bool):
        return "true" if v else "false"
    if v is None:
        return "null"
    if isinstance(v, (int, float)):
        return _num(v)
    return _str(v)


def write_bridge_json(path, data):
    sections = ("objects", "collections", "armatures", "skins")
    header = {k: v for k, v in data.items() if k not in sections}
    parts = ["{"]
    parts.append(",".join(_str(k) + ":" + _dump(v) for k, v in header.items()) + ",")
    parts.append('"objects":{')
    parts.append(",\n".join(_str(name) + ":" + _dump(rec) for name, rec in data["objects"].items()))
    parts.append("},")
    parts.append('"collections":' + _dump(data["collections"]))
    for sec in ("armatures", "skins"):          # JSON v3; older importers ignore them
        if data.get(sec):
            parts.append(',"%s":{' % sec)
            parts.append(",\n".join(_str(name) + ":" + _dump(rec) for name, rec in data[sec].items()))
            parts.append("}")
    parts.append("}")
    text = "\n".join(parts) + "\n"
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    os.replace(tmp, path)
    return len(text)


def _write_json_atomic(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, ensure_ascii=False, indent=1)
    for attempt in range(20):            # Max may hold the file for a moment
        try:
            os.replace(tmp, path)
            return
        except PermissionError:
            time.sleep(0.05)
    os.replace(tmp, path)


def _read_json(path):
    try:
        with open(path, "r", encoding="utf-8-sig") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


# ─────────────────────────────────────────────────────────────────────────────
#  Animation access, Blender 3.6 - 5.2
# ─────────────────────────────────────────────────────────────────────────────

def assigned_fcurves(id_data):
    """F-Curves of the action that actually animates id_data."""
    ad = getattr(id_data, "animation_data", None)
    if ad is None or ad.action is None:
        return ()
    act = ad.action
    if hasattr(act, "layers"):                        # Blender 4.4+ slotted actions
        slot = getattr(ad, "action_slot", None)
        if slot is None:
            return ()
        try:
            from bpy_extras.anim_utils import action_get_channelbag_for_slot
        except ImportError:
            action_get_channelbag_for_slot = None
        if action_get_channelbag_for_slot is not None:
            bag = action_get_channelbag_for_slot(act, slot)
            return tuple(bag.fcurves) if bag is not None else ()
        for layer in act.layers:
            for strip in layer.strips:
                bag = strip.channelbag(slot) if hasattr(strip, "channelbag") else None
                if bag is not None:
                    return tuple(bag.fcurves)
        return ()
    return tuple(act.fcurves)                         # Blender 3.6 - 4.3


def _keys(fc):
    return [{"frame": kp.co[0], "value": kp.co[1]} for kp in fc.keyframe_points]


def _quat_from_mode(mode, values):
    if mode == 'QUATERNION':
        return Quaternion(values).normalized()
    # AXIS_ANGLE: (angle, x, y, z)
    axis = Vector(values[1:4])
    if axis.length < 1e-12:
        return Quaternion()
    return Quaternion(axis.normalized(), values[0])


# ─────────────────────────────────────────────────────────────────────────────
#  Scene data -> JSON  (same fields and meaning as add-on v1.0)
# ─────────────────────────────────────────────────────────────────────────────

def object_record(obj, parent):
    """parent: name of the 3ds Max parent node ("" = none), see resolve_max_parent()."""
    mode = obj.rotation_mode
    if mode in ('QUATERNION', 'AXIS_ANGLE'):
        static = (tuple(obj.rotation_quaternion) if mode == 'QUATERNION'
                  else tuple(obj.rotation_axis_angle))
        rot = _quat_from_mode(mode, static).to_euler('XYZ')
        out_mode = 'XYZ'
    else:
        rot = obj.rotation_euler
        out_mode = mode

    anim = {ch: {"X": [], "Y": [], "Z": []} for ch in ("location", "rotation_euler", "scale")}

    fcurves = assigned_fcurves(obj)
    for fc in fcurves:
        dp, idx = fc.data_path, fc.array_index
        if idx > 2:
            continue
        if dp in ("location", "scale"):
            anim[dp][AXES[idx]] = _keys(fc)
        elif dp == "rotation_euler" and out_mode == mode:
            anim[dp][AXES[idx]] = _keys(fc)

    if out_mode != mode:
        # Quaternion / axis-angle animation -> XYZ euler keys with continuity.
        path = "rotation_quaternion" if mode == 'QUATERNION' else "rotation_axis_angle"
        comps = {fc.array_index: fc for fc in fcurves if fc.data_path == path}
        if comps:
            frames = sorted({kp.co[0] for fc in comps.values() for kp in fc.keyframe_points})
            prev = None
            for f in frames:
                vals = [comps[i].evaluate(f) if i in comps else static[i] for i in range(4)]
                q = _quat_from_mode(mode, vals)
                e = q.to_euler('XYZ', prev) if prev is not None else q.to_euler('XYZ')
                prev = e
                for i, ax in enumerate(AXES):
                    anim["rotation_euler"][ax].append({"frame": f, "value": e[i]})

    return {
        "parent":         parent,
        "rotation_mode":  out_mode,
        "location":       list(obj.location),
        "rotation_euler": [rot[0], rot[1], rot[2]],
        "scale":          list(obj.scale),
        "animation":      anim,
    }


def collections_record(objects):
    """Same structure as add-on v1.0: {"layers": {col: parent}, "objects": {obj: col}}."""
    relevant = set()
    obj_to_col = {}
    for obj in objects:
        for col in obj.users_collection:
            obj_to_col[obj.name] = col.name
            relevant.add(col.name)
    col_parent = {}
    for col in bpy.data.collections:
        for child in col.children:
            col_parent[child.name] = col.name
    for name in list(relevant):
        cur = name
        while cur in col_parent and col_parent[cur] not in relevant:
            cur = col_parent[cur]
            relevant.add(cur)
    layers = {name: col_parent.get(name, "") for name in sorted(relevant)}
    return {"layers": layers, "objects": obj_to_col}


def fbx_unit_factor(scene):
    """Blender units -> FBX centimetres, exactly as io_scene_fbx computes it
    (apply_unit_scale=True, global_scale=1.0)."""
    us = scene.unit_settings
    return 100.0 if us.system == 'NONE' else 100.0 * us.scale_length


def collect_scene_data(context, objects, pose_frame, fbx_name="", plans=None):
    """plans: {armature name: RigPlan} for armatures converted to dummies (may be empty).
    Converted armatures without their own animation are not 3ds Max nodes, so they are
    left out of "objects" and their children are re-parented (see resolve_max_parent)."""
    scene = context.scene
    plans = plans or {}
    scope_set = set(objects)
    nodes = [o for o in objects if not (o.name in plans and not plans[o.name].node)]
    return {
        "format":      JSON_FORMAT,
        "version":     JSON_VERSION,
        "generator":   "Blender %s / blender_max_bridge %s" % (bpy.app.version_string, ADDON_VERSION),
        "source":      os.path.basename(bpy.data.filepath) if bpy.data.filepath else "",
        "fbx":         fbx_name,
        "pose_frame":  pose_frame,
        "fps":         scene.render.fps / (scene.render.fps_base or 1.0),
        "frame_start": scene.frame_start,
        "frame_end":   scene.frame_end,
        "unit_to_cm":  fbx_unit_factor(scene),
        "objects":     {o.name: _object_with_space(o, plans, scope_set) for o in nodes},
        "collections": collections_record(objects),
    }


def _object_with_space(obj, plans, scope_set):
    name, ref = resolve_max_parent(obj, plans, scope_set)
    rec = object_record(obj, name)
    space = parent_space(obj, ref)
    if space is not None:
        rec["parent_space"] = space
    return rec


def parent_space(obj, ref):
    """Space of obj's own channel values relative to its 3ds Max parent.

    Blender: world = parent matrix @ matrix_parent_inverse @ basis. The 3ds Max script
    assumes that the channel values are the world values in the pose the scene is linked
    in, which holds after Ctrl+P as long as the parent has kept the pose it had then. When
    the parent was parented in another pose (or has moved since), this returns the 3x4
    rows of M, constant over time, with
        world(obj) = world(3ds Max parent) @ M @ basis(obj)
    otherwise None. The linking pose is the pose frame; for children of bone dummies it
    is the bind (rest) pose, like the FBX and the dummies. ref: from resolve_max_parent."""
    par = obj.parent
    if par is None:
        return None
    kind, target = ref if ref is not None else (None, None)
    pinv = obj.matrix_parent_inverse
    if obj.parent_type == 'BONE':
        bone = par.data.bones.get(obj.parent_bone) if par.type == 'ARMATURE' else None
        if bone is None or bone.use_relative_parent:
            return None
        tail = Matrix.Translation((0.0, bone.length, 0.0))
        if kind == 'bone':
            q = par.matrix_world @ bone.matrix_local @ tail @ pinv
            w_max = par.matrix_world @ bone.matrix_local @ DUMMY_AXES
        else:
            q = par.matrix_world @ par.pose.bones[obj.parent_bone].matrix @ tail @ pinv
            w_max = target.matrix_world if kind == 'object' else Matrix.Identity(4)
    else:
        if obj.parent_type in ('VERTEX', 'VERTEX_3'):
            q = obj.matrix_world @ obj.matrix_basis.inverted_safe()
        else:
            q = par.matrix_world @ pinv
        w_max = target.matrix_world if kind == 'object' else Matrix.Identity(4)
    if max(abs(q[r][c] - (1.0 if r == c else 0.0)) for r in range(3) for c in range(4)) < 1e-5:
        return None
    m = w_max.inverted_safe() @ q
    return [[m[r][c] for c in range(4)] for r in range(3)]


# ─────────────────────────────────────────────────────────────────────────────
#  Armatures -> 3ds Max dummies + Skin modifier
#
#  Every converted bone becomes a Dummy named like the bone. Its axes are the
#  bone axes turned +90 degrees about the bone X axis:
#      dummy X = bone X,  dummy Y = bone Z (up),  dummy Z = -bone Y
#  For bones pointing backwards (+Y) that is "Z forward, Y up", the same as
#  the hand-made 3ds Max reference scene. A constant per-bone rotation does
#  not change the deformation: the Skin modifier only uses each dummy's
#  motion relative to its bind pose.
#
#  All matrices are evaluated by Blender itself (pose_bone.matrix includes
#  parents, inheritance, constraints, drivers, NLA), converted to the local
#  transform of the dummy relative to its 3ds Max parent and written as
#  position / Euler XYZ / scale values, ready for the 3ds Max controllers.
# ─────────────────────────────────────────────────────────────────────────────

DUMMY_AXES = Matrix.Rotation(math.radians(90.0), 4, 'X')

_POSE_PATH = re.compile(r'^pose\.bones\["((?:[^"\\]|\\.)*)"\]\.'
                        r'(location|rotation_quaternion|rotation_euler|rotation_axis_angle|scale)$')
_OBJECT_TRANSFORM_PATHS = {"location", "rotation_euler", "rotation_quaternion", "rotation_axis_angle",
                           "scale", "delta_location", "delta_rotation_euler",
                           "delta_rotation_quaternion", "delta_scale"}
_ROT_PATH = {'QUATERNION': "rotation_quaternion", 'AXIS_ANGLE': "rotation_axis_angle"}


class RigPlan:
    """How one armature object is converted."""

    def __init__(self, arm):
        self.arm = arm
        self.name = arm.name
        self.node = False        # True: the armature object itself becomes a dummy (it is animated)
        self.bones = []          # converted bones (deform bones + their parents), parents first
        self.bone_set = set()
        self.bake = False        # constraints / drivers / NLA / partial inheritance: sample every frame
        self.parent = ""         # 3ds Max parent of the root bone dummies ("" = world)
        self.parent_ref = None   # ('object', obj) or ('bone', (armature name, bone name)) or None
        self.warnings = []


def _bones_parents_first(bones):
    out, seen = [], set()

    def visit(b):
        if b.name in seen:
            return
        if b.parent is not None:
            visit(b.parent)
        seen.add(b.name)
        out.append(b)

    for b in bones:
        visit(b)
    return out


def _object_animated(obj):
    if any(fc.data_path in _OBJECT_TRANSFORM_PATHS for fc in assigned_fcurves(obj)):
        return True
    ad = obj.animation_data
    if ad is not None and any(fc.data_path in _OBJECT_TRANSFORM_PATHS and not fc.mute for fc in ad.drivers):
        return True
    return any(not c.mute for c in obj.constraints)


def _rig_needs_bake(arm, bones):
    if any(not c.mute for pb in arm.pose.bones for c in pb.constraints):
        return True
    ad = arm.animation_data
    if ad is not None:
        if any(fc.data_path.startswith("pose.bones[") and not fc.mute for fc in ad.drivers):
            return True
        if ad.use_nla and any(len(t.strips) for t in ad.nla_tracks if not t.mute):
            return True
    return any(not b.use_inherit_rotation or getattr(b, "inherit_scale", 'FULL') != 'FULL' for b in bones)


def resolve_max_parent(obj, plans, scope_set):
    """(name, ref) of the node obj gets parented to in 3ds Max. ("", None) = world.
    Converted armatures that are not nodes pass their children on to their own parent;
    children of a converted bone get that bone's dummy."""
    child, par = obj, obj.parent
    while par is not None:
        if par not in scope_set:
            return "", None
        plan = plans.get(par.name) if par.type == 'ARMATURE' else None
        if plan is None:
            return par.name, ('object', par)
        if child.parent_type == 'BONE' and child.parent_bone in plan.bone_set:
            return child.parent_bone, ('bone', (plan.name, child.parent_bone))
        if plan.node:
            return par.name, ('object', par)
        child, par = par, par.parent
    return "", None


def plan_rigs(scope, bake_all=False):
    scope_set = set(scope)
    plans = {}
    for arm in scope:
        if arm.type != 'ARMATURE':
            continue
        p = RigPlan(arm)
        bones = arm.data.bones
        wanted = [b for b in bones if b.use_deform]
        # bones that carry child objects become dummies too
        wanted += [bones[o.parent_bone] for o in scope
                   if o.parent is arm and o.parent_type == 'BONE' and o.parent_bone in bones]
        keep = set()
        for b in wanted:
            x = b
            while x is not None and x.name not in keep:
                keep.add(x.name)
                x = x.parent
        p.bones = [b for b in _bones_parents_first(list(bones)) if b.name in keep]
        p.bone_set = keep
        p.node = _object_animated(arm)
        p.bake = bake_all or _rig_needs_bake(arm, p.bones)
        if not p.bones:
            p.warnings.append("Armature '%s' has no deform bones, nothing to convert." % arm.name)
        for b in p.bones:
            if b.use_deform and b.bbone_segments > 1:
                p.warnings.append("Bone '%s' has %d B-Bone segments; 3ds Max deforms it as a straight bone."
                                  % (b.name, b.bbone_segments))
        plans[arm.name] = p
    for p in plans.values():
        if p.node:
            p.parent, p.parent_ref = p.name, ('object', p.arm)
        else:
            p.parent, p.parent_ref = resolve_max_parent(p.arm, plans, scope_set)
    return plans


def _rig_fcurves(arm):
    """{bone name: {property: [fcurves]}} from the action that animates the armature."""
    out = {}
    for fc in assigned_fcurves(arm):
        m = _POSE_PATH.match(fc.data_path)
        if m:
            bone = re.sub(r'\\(.)', r'\1', m.group(1))
            out.setdefault(bone, {}).setdefault(m.group(2), []).append(fc)
    return out


def _side_hint(fc, i, side):
    """3ds Max tangent type that reproduces this side of Blender key i."""
    kps = fc.keyframe_points
    kp = kps[i]
    if side == "out":
        if i == len(kps) - 1:
            return None
        mode, h = kp.interpolation, kp.handle_right
    else:
        if i == 0:
            return None
        mode, h = kps[i - 1].interpolation, kp.handle_left
    if mode == 'CONSTANT':
        return "step"
    if mode == 'LINEAR':
        return "linear"
    if mode == 'BEZIER' and abs(h[1] - kp.co[1]) <= 1e-6 * max(1.0, abs(kp.co[1])):
        return "flat"
    return "auto"


def _combine_hints(hints):
    hs = {h for h in hints if h is not None}
    if not hs:
        return None
    return hs.pop() if len(hs) == 1 else "auto"


def _group_keys(fcurves):
    """{frame key: [frame, ti, to]} for the union of keys of a channel group."""
    keys = {}
    for fc in fcurves:
        for i, kp in enumerate(fc.keyframe_points):
            k = int(round(kp.co[0] * 1000.0))
            e = keys.setdefault(k, [kp.co[0], [], []])
            e[1].append(_side_hint(fc, i, "in"))
            e[2].append(_side_hint(fc, i, "out"))
    return {k: [e[0], _combine_hints(e[1]), _combine_hints(e[2])] for k, e in keys.items()}


def _decompose(m, prev=None):
    loc, q, sca = m.decompose()
    e = q.to_euler('XYZ', prev) if prev is not None else q.to_euler('XYZ')
    return loc, e, sca


def _prs(loc, e, sca):
    return {"location": [loc[0], loc[1], loc[2]], "rotation": [e[0], e[1], e[2]],
            "scale": [sca[0], sca[1], sca[2]]}


def _frame_set(scene, f):
    fi = math.floor(f)
    scene.frame_set(int(fi), subframe=float(f - fi))


def collect_rig_data(context, plans, pose_frame):
    """JSON records for the converted armatures. Leaves the scene at pose_frame."""
    scene = context.scene
    active = [p for p in plans.values() if p.bones]
    if not active:
        return {}

    def dummy_worlds(rest):
        dw = {}
        for p in active:
            arm = p.arm
            for b in p.bones:
                m = b.matrix_local if rest else arm.pose.bones[b.name].matrix
                dw[(p.name, b.name)] = arm.matrix_world @ m @ DUMMY_AXES
        return dw

    def parent_world(p, b, dw):
        if b.parent is not None:
            return dw[(p.name, b.parent.name)]
        if p.parent_ref is None:
            return Matrix.Identity(4)
        kind, ref = p.parent_ref
        if kind == 'object':
            return ref.matrix_world.copy()
        return dw.get(ref, Matrix.Identity(4))

    def locals_at(dw):
        return {(p.name, b.name): parent_world(p, b, dw).inverted_safe() @ dw[(p.name, b.name)]
                for p in active for b in p.bones}

    # rest (bind pose) and pose-frame values
    _frame_set(scene, pose_frame)
    dw_rest = dummy_worlds(True)
    rest = locals_at(dw_rest)
    pose = locals_at(dummy_worlds(False))

    # which frames are needed, per bone and channel group
    groups = {}            # (rig, bone) -> {"location": {fk: [f, ti, to]}, ...}
    frames = {}            # frame key -> frame
    for p in active:
        fcs = {} if p.bake else _rig_fcurves(p.arm)
        for b in p.bones:
            if p.bake:
                fr = {int(f * 1000): [float(f), None, None]
                      for f in range(scene.frame_start, scene.frame_end + 1)}
                g = {"location": fr, "rotation": fr, "scale": fr}
            else:
                bf = fcs.get(b.name, {})
                rot_path = _ROT_PATH.get(p.arm.pose.bones[b.name].rotation_mode, "rotation_euler")
                g = {"location": _group_keys(bf.get("location", [])),
                     "rotation": _group_keys(bf.get(rot_path, [])),
                     "scale": _group_keys(bf.get("scale", []))}
            groups[(p.name, b.name)] = g
            for keys in g.values():
                for fk, e in keys.items():
                    frames[fk] = e[0]

    # evaluate Blender at every needed frame
    sampled = {}           # (rig, bone) -> {fk: local matrix}
    for fk in sorted(frames):
        _frame_set(scene, frames[fk])
        loc = locals_at(dummy_worlds(False))
        for key, g in groups.items():
            if any(fk in keys for keys in g.values()):
                sampled.setdefault(key, {})[fk] = loc[key]
    _frame_set(scene, pose_frame)

    out = {}
    for p in active:
        arm = p.arm
        bones_out = []
        for b in p.bones:
            key = (p.name, b.name)
            r_loc, r_rot, r_sca = _decompose(rest[key])
            q_loc, q_rot, q_sca = _decompose(pose[key], r_rot)
            anim = {"location": {}, "rotation": {}, "scale": {}}
            smp = sampled.get(key, {})
            prev = q_rot
            values = {}
            for fk in sorted(smp):
                l, e, s = _decompose(smp[fk], prev)
                prev = e
                values[fk] = (l, e, s)
            static = (q_loc, q_rot, q_sca)
            for gi, gname in enumerate(("location", "rotation", "scale")):
                keys = groups[key][gname]
                if not keys:
                    continue
                ordered = sorted(keys)
                for ax in range(3):
                    vals = [values[fk][gi][ax] for fk in ordered]
                    if max(vals) - min(vals) <= 1e-6 and abs(vals[0] - static[gi][ax]) <= 1e-6:
                        continue                      # this axis does not move: no keys
                    lst = []
                    for fk, v in zip(ordered, vals):
                        f, ti, to = keys[fk]
                        k = {"frame": f, "value": v}
                        if ti is not None:
                            k["ti"] = ti
                        if to is not None:
                            k["to"] = to
                        lst.append(k)
                    anim[gname][AXES[ax]] = lst
            bones_out.append({
                "name":           b.name,
                "parent":         b.parent.name if b.parent is not None else p.parent,
                "deform":         b.use_deform,
                "length":         b.length,
                "rest":           _prs(r_loc, r_rot, r_sca),
                "pose":           _prs(q_loc, q_rot, q_sca),
                "world_rotation": list(dw_rest[key].to_3x3().normalized().to_quaternion().to_euler('XYZ')),
                "animation":      anim,
            })
        w_loc, w_rot, w_sca = _decompose(arm.matrix_world)
        out[p.name] = {
            "node":   p.node,
            "parent": p.parent,
            "bake":   p.bake,
            "world":  _prs(w_loc, w_rot, w_sca),
            "bones":  bones_out,
        }
    return out


def collect_skin_data(context, plans, scope, warnings):
    """Per-vertex weights of meshes deformed by converted armatures, read from the
    evaluated mesh exactly as the FBX exporter writes it (armatures in REST pose).
    Weights are normalized like Blender's Armature modifier does; vertices whose
    total weight is <= 0.0001 are not deformed by Blender (empty list)."""
    dg = context.evaluated_depsgraph_get()
    skins = {}
    for o in scope:
        if o.type != 'MESH':
            continue
        mods = [m for m in o.modifiers if m.type == 'ARMATURE' and m.object is not None
                and m.object.name in plans and plans[m.object.name].bones and m.show_viewport]
        if not mods:
            continue
        mod = mods[0]
        plan = plans[mod.object.name]
        if len(mods) > 1:
            warnings.append("'%s': only the first Armature modifier is converted." % o.name)
        if not mod.use_vertex_groups:
            warnings.append("'%s': Armature modifier does not use vertex groups; no skin." % o.name)
            continue
        if mod.use_bone_envelopes:
            warnings.append("'%s': bone envelopes are not converted, only vertex group weights." % o.name)
        if mod.use_deform_preserve_volume:
            warnings.append("'%s': 'Preserve Volume' is on; 3ds Max uses linear skinning." % o.name)
        if mod.vertex_group:
            warnings.append("'%s': the Armature modifier vertex group mask is ignored." % o.name)
        deform = [b.name for b in plan.bones if b.use_deform]
        index = {n: i for i, n in enumerate(deform)}
        gnames = [g.name for g in o.vertex_groups]
        eo = o.evaluated_get(dg)
        me = eo.to_mesh(preserve_all_data_layers=True, depsgraph=dg)
        try:
            weights, static = [], 0
            for v in me.vertices:
                acc = {}
                for g in v.groups:
                    bi = index.get(gnames[g.group]) if g.group < len(gnames) else None
                    if bi is not None and g.weight > 0.0:
                        acc[bi] = acc.get(bi, 0.0) + g.weight
                tot = sum(acc.values())
                if tot <= 0.0001:
                    weights.append([])
                    static += 1
                else:
                    row = []
                    for bi in sorted(acc):
                        row += [bi, acc[bi] / tot]
                    weights.append(row)
            nverts = len(me.vertices)
        finally:
            eo.to_mesh_clear()
        skins[o.name] = {"armature": plan.name, "bones": deform, "vertices": nverts,
                         "static_vertices": static, "weights": weights}
    return skins


# ─────────────────────────────────────────────────────────────────────────────
#  Scene state: save -> strip for FBX -> restore
# ─────────────────────────────────────────────────────────────────────────────

def scope_objects(context, scope):
    if scope == 'SELECTED':
        objs = [o for o in context.selected_objects]
    else:
        objs = [o for o in context.view_layer.objects if o.visible_get()]
    return [o for o in objs if o.type in FBX_TYPES]


def _sorted_parents_first(objects):
    order, seen = [], set()
    pool = set(objects)

    def visit(o):
        if o in seen:
            return
        seen.add(o)
        if o.parent is not None and o.parent in pool:
            visit(o.parent)
        order.append(o)

    for o in objects:
        visit(o)
    return order


def _basis(o):
    return {
        "rotation_mode":       o.rotation_mode,
        "location":            tuple(o.location),
        "rotation_euler":      tuple(o.rotation_euler),
        "rotation_quaternion": tuple(o.rotation_quaternion),
        "rotation_axis_angle": tuple(o.rotation_axis_angle),
        "scale":               tuple(o.scale),
    }


def _set_basis(o, b):
    o.rotation_mode = b["rotation_mode"]
    o.location = b["location"]
    o.rotation_euler = b["rotation_euler"]
    o.rotation_quaternion = b["rotation_quaternion"]
    o.rotation_axis_angle = b["rotation_axis_angle"]
    o.scale = b["scale"]


def save_state(context, scope):
    scene, vl = context.scene, context.view_layer
    st = {
        "frame": scene.frame_current,
        "subframe": scene.frame_subframe,
        "active": vl.objects.active,
        "selected": [o for o in vl.objects if o.select_get()],
        "scope": list(scope),
        "parents": {},
        "basis": {},
        "anim": {},
        "constraints": [],
    }
    for o in scope:
        st["parents"][o] = (o.parent, o.parent_type, o.parent_bone,
                            tuple(o.parent_vertices), o.matrix_parent_inverse.copy())
    for o in scene.objects:
        ad = o.animation_data
        if o in st["parents"] or (ad is not None and ad.action is not None):
            st["basis"][o] = _basis(o)
        for c in o.constraints:
            st["constraints"].append((c, c.mute))
        if o.pose is not None:
            for pb in o.pose.bones:
                for c in pb.constraints:
                    st["constraints"].append((c, c.mute))
    for o in scope:
        ad = o.animation_data
        if ad is None:
            continue
        act = ad.action
        st["anim"][o] = {
            "action": act,
            "slot": getattr(ad, "action_slot", None) if act is not None else None,
            "fake_user": act.use_fake_user if act is not None else None,
            "use_nla": ad.use_nla,
            "drivers": [(fc, fc.mute) for fc in ad.drivers],
        }
    return st


def strip_for_fbx(context, state, plans=None):
    """Mute constraints, remove animation, clear parents keeping transforms.
    Armatures converted to dummies go to REST pose, so the meshes they deform are
    exported undeformed (the bind pose of the 3ds Max Skin modifier)."""
    state.setdefault("pose_position", [])
    for p in (plans or {}).values():
        data = p.arm.data
        if data.pose_position != 'REST' and all(d is not data for d, _pp in state["pose_position"]):
            state["pose_position"].append((data, data.pose_position))
            data.pose_position = 'REST'
    for c, _mute in state["constraints"]:
        c.mute = True
    for o, a in state["anim"].items():
        ad = o.animation_data
        for fc, _mute in a["drivers"]:
            fc.mute = True
        ad.use_nla = False
        if a["action"] is not None:
            a["action"].use_fake_user = True     # never orphaned while unassigned
            ad.action = None
    context.view_layer.update()

    scope = state["scope"]
    world = {o: o.matrix_world.copy() for o in scope}
    for o in scope:
        if o.parent is not None:
            o.parent = None
            o.matrix_world = world[o]
    context.view_layer.update()

    for o in context.view_layer.objects:
        if o.select_get():
            o.select_set(False)
    for o in scope:
        o.select_set(True)
    if scope:
        context.view_layer.objects.active = scope[0]


def restore_state(context, state):
    errors = []

    def guard(label, fn):
        try:
            fn()
        except Exception as exc:                  # keep restoring the rest
            errors.append("%s: %s" % (label, exc))

    scene = context.scene
    for o, (par, ptype, pbone, pverts, pinv) in state["parents"].items():
        def _p(o=o, par=par, ptype=ptype, pbone=pbone, pverts=pverts, pinv=pinv):
            if o.parent != par:
                o.parent = par
            if par is not None:
                if o.parent_type != ptype:
                    o.parent_type = ptype
                if o.parent_bone != pbone:
                    o.parent_bone = pbone
                if tuple(o.parent_vertices) != pverts:
                    o.parent_vertices = pverts
            o.matrix_parent_inverse = pinv
        guard("parent " + o.name, _p)

    for o, a in state["anim"].items():
        def _a(o=o, a=a):
            ad = o.animation_data
            if a["action"] is not None:
                if ad.action != a["action"]:
                    ad.action = a["action"]
                slot = a["slot"]
                if slot is not None and hasattr(ad, "action_slot") and ad.action_slot != slot:
                    ad.action_slot = slot
                a["action"].use_fake_user = a["fake_user"]
            ad.use_nla = a["use_nla"]
            for fc, mute in a["drivers"]:
                fc.mute = mute
        guard("animation " + o.name, _a)

    for c, mute in state["constraints"]:
        guard("constraint " + c.name, lambda c=c, mute=mute: setattr(c, "mute", mute))

    for data, pp in state.get("pose_position", []):
        guard("pose position " + data.name, lambda data=data, pp=pp: setattr(data, "pose_position", pp))

    guard("frame", lambda: scene.frame_set(state["frame"], subframe=state["subframe"]))

    # Raw property values last: keeps exact euler angles and unkeyed edits.
    for o, b in state["basis"].items():
        guard("transform " + o.name, lambda o=o, b=b: _set_basis(o, b))

    def _sel():
        vl = context.view_layer
        for o in vl.objects:
            if o.select_get():
                o.select_set(False)
        for o in state["selected"]:
            if o.name in vl.objects:
                o.select_set(True)
        vl.objects.active = state["active"]
    guard("selection", _sel)
    guard("update", context.view_layer.update)
    return errors


def _ensure_object_mode(context):
    obj = context.view_layer.objects.active
    if obj is not None and obj.mode != 'OBJECT' and bpy.ops.object.mode_set.poll():
        prev = obj.mode
        bpy.ops.object.mode_set(mode='OBJECT')
        return obj, prev
    return None, None


def _restore_mode(context, obj, prev):
    if obj is None or prev is None:
        return
    try:
        if context.view_layer.objects.active is obj and bpy.ops.object.mode_set.poll():
            bpy.ops.object.mode_set(mode=prev)
    except Exception:
        pass


# ─────────────────────────────────────────────────────────────────────────────
#  FBX export with the agreed settings
# ─────────────────────────────────────────────────────────────────────────────

FBX_SETTINGS = dict(
    use_selection=True,
    use_visible=False,
    use_active_collection=False,
    object_types={'EMPTY', 'CAMERA', 'LIGHT', 'ARMATURE', 'MESH', 'OTHER'},
    use_custom_props=False,
    global_scale=1.0,
    apply_scale_options='FBX_SCALE_NONE',     # "All Local"
    axis_forward='Y',
    axis_up='Z',
    apply_unit_scale=True,
    use_space_transform=True,
    bake_space_transform=True,                # "Apply Transform"
    bake_anim=False,
    path_mode='AUTO',
    batch_mode='OFF',
)


def _fbx_operator_props():
    try:
        return set(bpy.ops.export_scene.fbx.get_rna_type().properties.keys())
    except Exception:
        pass
    try:
        import addon_utils
        addon_utils.enable("io_scene_fbx", default_set=True, persistent=True)
        return set(bpy.ops.export_scene.fbx.get_rna_type().properties.keys())
    except Exception:
        return None


def export_fbx(filepath, armatures=True):
    """armatures=False: armature objects are converted to 3ds Max dummies by the
    JSON, so no Blender bones or skin clusters go into the FBX."""
    valid = _fbx_operator_props()
    if valid is None:
        raise RuntimeError("The FBX exporter (io_scene_fbx) is not available.")
    kwargs = {k: v for k, v in FBX_SETTINGS.items() if k in valid}
    if not armatures and "object_types" in kwargs:
        kwargs["object_types"] = set(kwargs["object_types"]) - {'ARMATURE'}
    kwargs["filepath"] = filepath
    if "check_existing" in valid:
        kwargs["check_existing"] = False
    result = bpy.ops.export_scene.fbx(**kwargs)
    if 'FINISHED' not in result:
        raise RuntimeError("FBX export did not finish: %s" % (result,))


# ─────────────────────────────────────────────────────────────────────────────
#  Export bundle (JSON + FBX) with guaranteed scene restore
# ─────────────────────────────────────────────────────────────────────────────

def export_bundle(context, scope, json_path, fbx_path, pose_frame, convert_bones=True, bake_bones=False):
    """Write JSON (and FBX if fbx_path) and restore the scene. Returns stats.
    convert_bones: armatures become 3ds Max dummies + Skin (JSON "armatures"/"skins")."""
    t0 = time.perf_counter()
    for o in scope:
        ad = o.animation_data
        if ad is not None and ad.use_tweak_mode:
            raise RuntimeError("'%s' is in NLA tweak mode. Exit tweak mode and try again." % o.name)

    mode_obj, mode_prev = _ensure_object_mode(context)
    before = {o: o.matrix_world.copy() for o in scope}
    state = save_state(context, scope)
    stats = {"objects": len(scope), "warnings": [], "dummies": 0, "skins": 0}
    restore_errors = []
    try:
        context.scene.frame_set(pose_frame)
        plans = plan_rigs(scope, bake_bones) if convert_bones else {}
        for p in plans.values():
            stats["warnings"] += p.warnings
        data = collect_scene_data(context, scope, pose_frame,
                                  os.path.basename(fbx_path) if fbx_path else "", plans)
        if plans:
            data["armatures"] = collect_rig_data(context, plans, pose_frame)
            names = set(data["objects"])
            clash = sorted({b["name"] for a in data["armatures"].values() for b in a["bones"]} & names)
            if clash:
                stats["warnings"].append("Bone and object share a name (3ds Max node names clash): "
                                         + ", ".join(clash[:5]))
        if fbx_path or plans:
            strip_for_fbx(context, state, plans)
        if plans:
            data["skins"] = collect_skin_data(context, plans, scope, stats["warnings"])
        stats["json_bytes"] = write_bridge_json(json_path, data)
        stats["keys"] = sum(len(v) for rec in data["objects"].values()
                            for ch in rec["animation"].values() for v in ch.values())
        stats["animated"] = sum(1 for rec in data["objects"].values()
                                if any(v for ch in rec["animation"].values() for v in ch.values()))
        for a in data.get("armatures", {}).values():
            stats["dummies"] += len(a["bones"])
            for b in a["bones"]:
                n = sum(len(v) for ch in b["animation"].values() for v in ch.values())
                stats["keys"] += n
                stats["animated"] += 1 if n else 0
        stats["skins"] = len(data.get("skins", {}))
        if fbx_path:
            export_fbx(fbx_path, armatures=not plans)
    finally:
        restore_errors = restore_state(context, state)
        _restore_mode(context, mode_obj, mode_prev)

    worst = 0.0
    for o, m in before.items():
        m2 = o.matrix_world
        worst = max(worst, max(abs(m[r][c] - m2[r][c]) for r in range(4) for c in range(4)))
    stats["restore_errors"] = restore_errors
    stats["restore_deviation"] = worst
    stats["seconds"] = time.perf_counter() - t0
    return stats


# ─────────────────────────────────────────────────────────────────────────────
#  Bridge: job file + polling for the 3ds Max result
# ─────────────────────────────────────────────────────────────────────────────

_transfer = {"id": None, "state": "idle", "lines": [], "t0": 0.0, "picked": False}


def _redraw_panels():
    try:
        for win in bpy.context.window_manager.windows:
            for area in win.screen.areas:
                if area.type == 'VIEW_3D':
                    area.tag_redraw()
    except Exception:
        pass


def _set_transfer(state, *lines):
    _transfer["state"] = state
    _transfer["lines"] = [l for l in lines if l]
    for l in _transfer["lines"]:
        print("[Max Bridge]", l)
    _redraw_panels()


def send_job(fbx_path, json_path, replace, objects):
    folder = bridge_dir()
    os.makedirs(folder, exist_ok=True)
    job_id = uuid.uuid4().hex
    job = {
        "format":   JOB_FORMAT,
        "version":  JSON_VERSION,
        "id":       job_id,
        "created":  time.time(),
        "fbx":      fbx_path,
        "json":     json_path,
        "replace":  bool(replace),
        "objects":  objects,
        "blender":  bpy.app.version_string,
        "source":   bpy.data.filepath,
    }
    _write_json_atomic(os.path.join(folder, JOB_FILE), job)
    _transfer.update(id=job_id, t0=time.time(), picked=False)
    if bpy.app.timers.is_registered(_poll_result):
        bpy.app.timers.unregister(_poll_result)
    bpy.app.timers.register(_poll_result, first_interval=0.5)
    return job_id


def _poll_result():
    if _transfer["state"] != "waiting":
        return None
    folder = bridge_dir()
    job_path = os.path.join(folder, JOB_FILE)
    now = time.time()
    waited = now - _transfer["t0"]

    res = _read_json(os.path.join(folder, RESULT_FILE))
    if res and res.get("id") == _transfer["id"]:
        ok = res.get("status") == "ok"
        lines = ["3ds Max: %s" % (res.get("message") or ("done" if ok else "failed"))]
        for w in (res.get("warnings") or [])[:6]:
            lines.append("  ! " + str(w))
        _set_transfer("done" if ok else "error", *lines)
        return None

    job = _read_json(job_path) if os.path.exists(job_path) else None
    still_queued = job is not None and job.get("id") == _transfer["id"]
    if not still_queued:
        if not _transfer["picked"]:
            _transfer["picked"] = True
            _set_transfer("waiting", "3ds Max picked up the job, importing...")
    else:
        alive, _age = listener_status()
        limit = PICKUP_TIMEOUT_ONLINE if alive else PICKUP_TIMEOUT_OFFLINE
        if waited > limit:
            try:
                os.remove(job_path)
            except OSError:
                pass
            _set_transfer("error",
                          "3ds Max did not pick up the job (%.0f s)." % waited,
                          "Run BlenderMaxBridge_v2.3.ms in 3ds Max and press Start listening.",
                          "Files are kept, you can import them manually.")
            return None

    if waited > RESULT_TIMEOUT:
        _set_transfer("error", "No result from 3ds Max after %.0f s." % waited)
        return None
    return 0.5


# ─────────────────────────────────────────────────────────────────────────────
#  Settings
# ─────────────────────────────────────────────────────────────────────────────

class MaxBridgePreferences(bpy.types.AddonPreferences):
    bl_idname = __name__

    bridge_dir: StringProperty(
        name="Bridge folder",
        description="Folder shared with the 3ds Max listener (job, result and heartbeat files). "
                    "Must be the same folder as in the 3ds Max dialog",
        subtype='DIR_PATH',
        default=default_bridge_dir(),
    )

    def draw(self, context):
        self.layout.prop(self, "bridge_dir")
        self.layout.label(text="Default: " + default_bridge_dir(), icon='INFO')


class MaxBridgeSettings(bpy.types.PropertyGroup):
    scope: EnumProperty(
        name="Objects",
        items=(('ALL', "All visible", "All objects visible in the current view layer"),
               ('SELECTED', "Selected", "Only the selected objects")),
        default='ALL',
    )
    pose_frame: IntProperty(
        name="Pose frame",
        description="Frame at which the static pose (FBX transforms and JSON values) is taken. "
                    "3ds Max reads the import at frame 0, so keep 0 unless your rest pose is elsewhere",
        default=0,
    )
    output_dir: StringProperty(
        name="Output folder",
        description="Where the FBX and JSON are written. Empty = next to the .blend file "
                    "(or the bridge folder if the file is not saved)",
        subtype='DIR_PATH',
        default="",
    )
    base_name: StringProperty(
        name="File name",
        description="Base name for the FBX and JSON files. Empty = .blend file name",
        default="",
    )
    replace_in_max: BoolProperty(
        name="Replace same-named objects in 3ds Max",
        description="Before importing, delete 3ds Max objects whose names match the exported objects, "
                    "so re-sending updates the scene instead of duplicating it",
        default=True,
    )
    bones_to_dummies: BoolProperty(
        name="Bones -> Dummies + Skin",
        description="Convert armatures: every deform bone becomes a 3ds Max Dummy (Z forward, Y up) "
                    "with the bone animation, and meshes deformed by the armature get a Skin modifier "
                    "with the painted weights. Off: armatures go into the FBX as before",
        default=True,
    )
    bake_bones: BoolProperty(
        name="Bake bone keys every frame",
        description="Key the dummies on every frame of the scene range (only axes that move). "
                    "Off: keys only where Blender has bone keys; flat, linear and constant curves "
                    "match exactly, other curve shapes follow 3ds Max interpolation between keys. "
                    "Bones with constraints or drivers are always baked",
        default=False,
    )


# ─────────────────────────────────────────────────────────────────────────────
#  Operators
# ─────────────────────────────────────────────────────────────────────────────

def _run(op, context, send):
    s = context.scene.max_bridge
    scope = scope_objects(context, s.scope)
    if not scope:
        op.report({'WARNING'}, "No objects to export (check the 'Objects' setting).")
        return {'CANCELLED'}
    folder, base = _resolve_output(s)
    try:
        os.makedirs(folder, exist_ok=True)
    except OSError as exc:
        op.report({'ERROR'}, "Cannot create output folder: %s" % exc)
        return {'CANCELLED'}
    fbx_path = os.path.join(folder, base + ".fbx")
    json_path = os.path.join(folder, base + ".json")

    if send and _transfer["state"] == "waiting":
        _set_transfer("idle")                     # previous job is replaced

    try:
        stats = export_bundle(context, scope, json_path, fbx_path, s.pose_frame, s.bones_to_dummies, s.bake_bones)
    except Exception as exc:
        op.report({'ERROR'}, "Export failed: %s" % exc)
        _set_transfer("error", "Export failed: %s" % exc)
        return {'CANCELLED'}

    summary = "%d objects (%d animated, %d keys), %.1f s" % (
        stats["objects"], stats["animated"], stats["keys"], stats["seconds"])
    if stats["dummies"]:
        summary += ", %d bones -> dummies, %d skinned" % (stats["dummies"], stats["skins"])
    warn = list(stats["warnings"])
    if stats["restore_errors"]:
        warn.append("Scene restore problems: " + "; ".join(stats["restore_errors"][:3]))
    if stats["restore_deviation"] > 1e-4:
        warn.append("Scene restore check: objects moved by up to %.6f" % stats["restore_deviation"])
    for w in warn:
        op.report({'WARNING'}, w)

    if not send:
        _set_transfer("done", "Exported " + summary, fbx_path, json_path, *warn)
        op.report({'INFO'}, "Exported %s -> %s" % (summary, folder))
        return {'FINISHED'}

    try:
        send_job(fbx_path, json_path, s.replace_in_max, stats["objects"])
    except OSError as exc:
        op.report({'ERROR'}, "Cannot write job file: %s" % exc)
        _set_transfer("error", "Cannot write job file: %s" % exc)
        return {'CANCELLED'}
    alive, _age = listener_status()
    _set_transfer("waiting",
                  "Exported " + summary,
                  "Waiting for 3ds Max..." if alive else
                  "Waiting for 3ds Max (listener looks offline)...",
                  *warn)
    op.report({'INFO'}, "Sent to 3ds Max: " + summary)
    return {'FINISHED'}


class MAXBRIDGE_OT_send(bpy.types.Operator):
    """Export FBX + JSON, restore the scene and import everything in 3ds Max"""
    bl_idname = "max_bridge.send"
    bl_label = "Send to 3ds Max"
    bl_options = {'REGISTER', 'UNDO'}

    def execute(self, context):
        return _run(self, context, send=True)


class MAXBRIDGE_OT_export_files(bpy.types.Operator):
    """Export FBX + JSON with the bridge settings, without notifying 3ds Max"""
    bl_idname = "max_bridge.export_files"
    bl_label = "Export FBX + JSON only"
    bl_options = {'REGISTER', 'UNDO'}

    def execute(self, context):
        return _run(self, context, send=False)


class MAXBRIDGE_OT_open_folder(bpy.types.Operator):
    """Open the output folder"""
    bl_idname = "max_bridge.open_folder"
    bl_label = "Open output folder"

    def execute(self, context):
        folder, _base = _resolve_output(context.scene.max_bridge)
        os.makedirs(folder, exist_ok=True)
        bpy.ops.wm.path_open(filepath=folder)
        return {'FINISHED'}


class EXPORT_OT_blender_max_json(bpy.types.Operator, ExportHelper):
    """Write only the JSON (hierarchy, rotation orders, transforms, animation, collections)"""
    bl_idname = "export_scene.blender_max_json"
    bl_label = "Export Blender JSON"
    bl_options = {'REGISTER', 'UNDO'}

    filename_ext = ".json"
    filter_glob: StringProperty(default="*.json", options={'HIDDEN'})
    use_selection: BoolProperty(name="Selected Objects", default=True)

    def execute(self, context):
        scope = scope_objects(context, 'SELECTED' if self.use_selection else 'ALL')
        if not scope:
            self.report({'WARNING'}, "No objects to export.")
            return {'CANCELLED'}
        try:
            s = context.scene.max_bridge
            stats = export_bundle(context, scope, self.filepath, None, s.pose_frame, s.bones_to_dummies,
                                  s.bake_bones)
        except Exception as exc:
            self.report({'ERROR'}, "Export failed: %s" % exc)
            return {'CANCELLED'}
        self.report({'INFO'}, "Exported %d objects to %s" % (stats["objects"], self.filepath))
        return {'FINISHED'}


# ─────────────────────────────────────────────────────────────────────────────
#  UI
# ─────────────────────────────────────────────────────────────────────────────

class VIEW3D_PT_max_bridge(bpy.types.Panel):
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "Max Bridge"
    bl_label = "Blender -> 3ds Max"

    def draw(self, context):
        layout = self.layout
        s = context.scene.max_bridge

        alive, age = listener_status()
        row = layout.row()
        if alive:
            row.label(text="3ds Max listener: online", icon='CHECKMARK')
        else:
            row.label(text="3ds Max listener: offline", icon='ERROR')

        col = layout.column()
        col.scale_y = 1.6
        col.enabled = _transfer["state"] != "waiting"
        col.operator(MAXBRIDGE_OT_send.bl_idname, icon='EXPORT')

        if _transfer["state"] != "idle":
            box = layout.box()
            icon = {'waiting': 'TIME', 'done': 'CHECKMARK', 'error': 'ERROR'}.get(_transfer["state"], 'INFO')
            for i, line in enumerate(_transfer["lines"]):
                box.label(text=line, icon=icon if i == 0 else 'NONE')

        box = layout.box()
        box.label(text="Settings")
        box.row().prop(s, "scope", expand=True)
        box.prop(s, "pose_frame")
        box.prop(s, "output_dir")
        box.prop(s, "base_name")
        box.prop(s, "replace_in_max")
        box.prop(s, "bones_to_dummies")
        sub = box.row()
        sub.enabled = s.bones_to_dummies
        sub.prop(s, "bake_bones")
        folder, base = _resolve_output(s)
        sub = box.column(align=True)
        sub.scale_y = 0.8
        sub.label(text=os.path.join(folder, base + ".fbx / .json"))

        row = layout.row(align=True)
        row.operator(MAXBRIDGE_OT_export_files.bl_idname, icon='FILE_TICK')
        row.operator(MAXBRIDGE_OT_open_folder.bl_idname, text="", icon='FILE_FOLDER')


def menu_func_export(self, context):
    self.layout.operator(MAXBRIDGE_OT_send.bl_idname, text="Send to 3ds Max (FBX + JSON)")
    self.layout.operator(EXPORT_OT_blender_max_json.bl_idname, text="Blender JSON (.json)")


# ─────────────────────────────────────────────────────────────────────────────
#  Registration
# ─────────────────────────────────────────────────────────────────────────────

classes = (
    MaxBridgePreferences,
    MaxBridgeSettings,
    MAXBRIDGE_OT_send,
    MAXBRIDGE_OT_export_files,
    MAXBRIDGE_OT_open_folder,
    EXPORT_OT_blender_max_json,
    VIEW3D_PT_max_bridge,
)


def register():
    for cls in classes:
        bpy.utils.register_class(cls)
    bpy.types.Scene.max_bridge = PointerProperty(type=MaxBridgeSettings)
    bpy.types.TOPBAR_MT_file_export.append(menu_func_export)


def unregister():
    if bpy.app.timers.is_registered(_poll_result):
        bpy.app.timers.unregister(_poll_result)
    bpy.types.TOPBAR_MT_file_export.remove(menu_func_export)
    del bpy.types.Scene.max_bridge
    for cls in reversed(classes):
        bpy.utils.unregister_class(cls)


if __name__ == "__main__":
    register()
