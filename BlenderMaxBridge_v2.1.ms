-- ============================================================
--  Blender -> 3ds Max Bridge  (3ds Max side)
--  Version 2.1
--
--  Created by Claude (Anthropic)
--  under the leadership of Kruglov Iurii
-- ============================================================
--
--  Pairs with the Blender add-on blender_max_bridge.py (v2.1).
--  Replaces BlenderJSON_Importer_v1.1.1.ms (same results).
--
--  LISTENER
--    "Start listening" polls the bridge folder twice a second
--    (Windows Forms timer, runs on the UI thread). When Blender
--    drops job.json it: imports the FBX, replaces same-named
--    objects from the previous send (optional; they are deleted
--    only if the import succeeded), applies the JSON, writes
--    result.json and keeps listener.json fresh so Blender can
--    show "online".
--    Optional: start the listener automatically with 3ds Max.
--
--  MANUAL IMPORT
--    "Import JSON..." works without Blender: imports the FBX named
--    in the JSON (or applies to objects already in the scene).
--
--  BONES -> DUMMIES + SKIN  (new in 2.1, JSON v3)
--    Every converted Blender bone becomes a Dummy with the bone's
--    name: Z forward, Y up (bone axes turned +90 deg about bone X),
--    scale 100 %, bone hierarchy kept, root bones under the object
--    the armature was parented to. Each mesh deformed by the
--    armature gets a Skin modifier bound to the dummies in the
--    bind (rest) pose, with Blender's normalized vertex weights.
--    Then the dummies get the pose and the bone keys (tangents
--    follow Blender: flat / linear / step, otherwise auto).
--
--  ROTATION / POSITION MATH  (unchanged from v1.1.1)
--    W = R1(a1)*R2(a2)*R3(a3)   (rotation_mode order, from JSON radians)
--    L = W * inverse(parent_W)
--    decomposeEuler(L, mode) -> sub-controller degrees
--    Location keys: lPos = worldPos * inverse(parent.transform)
--
--  SPEED-UPS vs v1.1.1 (results are the same)
--    - file read in one call (was: string += per line, quadratic)
--    - iterative JSON parser, numbers via "as float"
--      (was: execute per number, recursion, return per string)
--    - Dictionary lookups (HasDictValue) instead of key scans
--    - name -> node table built once (was: getNodeByName per pass)
--    - no return / continue / exit in loops (MAXScript implements
--      them with exceptions, which is slow)
--    - undo off, animate off and scene redraw off while applying
--    - per-phase timing printed to the Listener
--
--  FIXES vs v1.1.1
--    - scale keys work (v1.1.1 used X_Scale on a Bezier_Scale
--      controller, which does not exist)
--    - "animate off" guard: a user's Auto Key no longer adds keys
--    - sub-frame keys keep their sub-frame
--    - positions follow the 3ds Max system unit, and are checked
--      against the imported FBX (location keys always match the
--      scale the FBX importer used, so nothing flies away)
--
--  Compatible with 3ds Max 2022 - 2026.
-- ============================================================

global BlenderMaxBridge
global BlenderMaxBridgeStruct
global BlenderMaxBridgeRollout
global BlenderMaxBridge_Timer
global BlenderMaxBridge_onTick
global BlenderMaxBridge_AutoStart
global BlenderMaxBridge_Resume = (BlenderMaxBridge_Timer != undefined)

-- Stop the timer of a previous run of this script.
if BlenderMaxBridge_Timer != undefined do (
	try (BlenderMaxBridge_Timer.Stop()) catch ()
	try (dotNet.removeAllEventHandlers BlenderMaxBridge_Timer) catch ()
	try (BlenderMaxBridge_Timer.Dispose()) catch ()
	BlenderMaxBridge_Timer = undefined
)

struct BlenderMaxBridgeStruct (
	bridgeVersion = "2.1",
	bridgeDir = "",
	scriptFile = "",
	listening = false,
	busy = false,
	lastBeat = 0,
	lastLine1 = "-",
	lastLine2 = "",
	lastJobId = "",
	warnings = #(),

	-- ── Logging ─────────────────────────────────────────────────────────
	fn logLine msg = (
		format "[Blender->Max Bridge] %\n" msg
	),
	fn warn msg = (
		if warnings.count < 100 do append warnings msg
		logLine ("WARNING: " + msg)
	),

	-- ── Files (.NET, available in every 3ds Max version) ───────────────
	fn readText fp = (
		(dotNetClass "System.IO.File").ReadAllText fp
	),
	fn writeText fp txt = (
		(dotNetClass "System.IO.File").WriteAllText fp txt
	),
	fn fileExists fp = (
		(dotNetClass "System.IO.File").Exists fp
	),
	fn deleteFileSafe fp = (
		try ((dotNetClass "System.IO.File").Delete fp) catch ()
	),
	-- Blender may be reading the file for a moment: retry for up to 1 s.
	fn deleteFileRetry fp = (
		local n = 0
		while (fileExists fp) and n < 20 do (
			deleteFileSafe fp
			if fileExists fp do sleep 0.05
			n += 1
		)
		not (fileExists fp)
	),
	fn writeTextAtomic fp txt = (
		local tmp = fp + ".tmp"
		writeText tmp txt
		local done = false
		local n = 0
		while not done and n < 40 do (
			try (
				if fileExists fp do (dotNetClass "System.IO.File").Delete fp
				(dotNetClass "System.IO.File").Move tmp fp
				done = true
			) catch (
				sleep 0.05
				n += 1
			)
		)
		if not done do (
			writeText fp txt
			deleteFileSafe tmp
		)
	),
	fn ensureDir dir = (
		if not ((dotNetClass "System.IO.Directory").Exists dir) do (
			try ((dotNetClass "System.IO.Directory").CreateDirectory dir) catch ()
		)
		(dotNetClass "System.IO.Directory").Exists dir
	),
	-- Seconds since the file was written (double precision, from .NET).
	fn fileAgeSeconds fp = (
		local wt = (dotNetClass "System.IO.File").GetLastWriteTimeUtc fp
		((dotNetClass "System.DateTime").UtcNow.Subtract wt).TotalSeconds
	),

	-- ── Settings ────────────────────────────────────────────────────────
	fn iniFile = (
		pathConfig.appendPath (getDir #plugcfg) "BlenderMaxBridge.ini"
	),
	fn defaultBridgeDir = (
		local base = systemTools.getEnvVariable "LOCALAPPDATA"
		if base == undefined or base == "" do base = (dotNetClass "System.IO.Path").GetTempPath()
		pathConfig.appendPath base "BlenderMaxBridge"
	),
	fn loadSettings = (
		local d = getINISetting (iniFile()) "Bridge" "Folder"
		bridgeDir = if d != "" then d else (defaultBridgeDir())
	),
	fn saveSettings = (
		setINISetting (iniFile()) "Bridge" "Folder" bridgeDir
	),

	-- ── JSON ────────────────────────────────────────────────────────────
	fn jsonEsc s = (
		local r = substituteString (s as string) "\\" "\\\\"
		r = substituteString r "\"" "\\\""
		r = substituteString r "\n" "\\n"
		r = substituteString r "\r" "\\r"
		r = substituteString r "\t" "\\t"
		r
	),
	fn jsonUnescape s = (
		local outStr = ""
		local i = 1
		local n = s.count
		while i <= n do (
			local c = s[i]
			if c == "\\" and i < n then (
				local e2 = s[i + 1]
				i += 2
				case e2 of (
					"n": outStr += "\n"
					"t": outStr += "\t"
					"r": outStr += "\r"
					"b": outStr += (bit.intAsChar 8)
					"f": outStr += (bit.intAsChar 12)
					"u": (
						outStr += (bit.intAsChar (bit.hexAsInt (substring s i 4)))
						i += 4
					)
					default: outStr += e2
				)
			) else (
				outStr += c
				i += 1
			)
		)
		outStr
	),
	fn parseNum s = (
		local ePos = findString s "e"
		if ePos == undefined do ePos = findString s "E"
		if ePos == undefined then (s as float) else (
			local mant = (substring s 1 (ePos - 1)) as float
			local ex = substring s (ePos + 1) -1
			if ex.count > 0 and ex[1] == "+" do ex = substring ex 2 -1
			mant * (10.0 ^ (ex as integer))
		)
	),
	-- Iterative parser: objects -> Dictionary #string, arrays -> Array,
	-- numbers -> Float, true/false, null -> undefined.
	fn parseJSON src = (
		local n = src.count
		local i = 1
		local root = undefined
		local stack = #()
		local isObj = #()
		local depth = 0
		local curKey = ""
		local expectKey = false
		local numChars = "0123456789+-.eE"
		while i <= n do (
			local c = src[i]
			if c == "{" or c == "[" then (
				local cont = if c == "{" then (Dictionary #string) else #()
				if depth == 0 then root = cont
				else if isObj[depth] then stack[depth][curKey] = cont
				else append stack[depth] cont
				depth += 1
				stack[depth] = cont
				isObj[depth] = (c == "{")
				expectKey = (c == "{")
				i += 1
			) else if c == "}" or c == "]" then (
				depth -= 1
				expectKey = false
				i += 1
			) else if c == "\"" then (
				local j = i + 1
				local esc = false
				while j <= n and src[j] != "\"" do (
					if src[j] == "\\" then (
						esc = true
						j += 2
					) else j += 1
				)
				local s = substring src (i + 1) (j - i - 1)
				if esc do s = jsonUnescape s
				i = j + 1
				if depth > 0 and isObj[depth] and expectKey then (
					curKey = s
					expectKey = false
				) else (
					if depth == 0 then root = s
					else if isObj[depth] then stack[depth][curKey] = s
					else append stack[depth] s
				)
			) else if c == "," then (
				if depth > 0 and isObj[depth] do expectKey = true
				i += 1
			) else if c == ":" or c == " " or c == "\n" or c == "\r" or c == "\t" then (
				i += 1
			) else (
				local v = undefined
				if c == "t" then (
					v = true
					i += 4
				) else if c == "f" then (
					v = false
					i += 5
				) else if c == "n" then (
					i += 4
				) else (
					local j = i + 1
					while j <= n and (findString numChars src[j]) != undefined do j += 1
					v = parseNum (substring src i (j - i))
					i = j
				)
				if depth == 0 then root = v
				else if isObj[depth] then stack[depth][curKey] = v
				else append stack[depth] v
			)
		)
		root
	),

	-- ── Math (identical to v1.1.1) ──────────────────────────────────────
	fn r2d v = v * (180.0 / pi),

	fn dget d k fb = (
		local v = d[k]
		if v == undefined then fb else v
	),

	fn blenderOrderToMax s = (
		case s of (
			"XYZ": 1
			"XZY": 2
			"YZX": 3
			"YXZ": 4
			"ZXY": 5
			"ZYX": 6
			default: 1
		)
	),

	fn buildWorldRot xDeg yDeg zDeg modeStr = (
		local mX = rotateXMatrix xDeg
		local mY = rotateYMatrix yDeg
		local mZ = rotateZMatrix zDeg
		case modeStr of (
			"XYZ": mX * mY * mZ
			"YZX": mY * mZ * mX
			"ZXY": mZ * mX * mY
			"XZY": mX * mZ * mY
			"YXZ": mY * mX * mZ
			"ZYX": mZ * mY * mX
			default: mX * mY * mZ
		)
	),

	fn safeAsin v = (
		local c = v
		if c >  1.0 do c =  1.0
		if c < -1.0 do c = -1.0
		asin c
	),

	fn decomposeEuler L modeStr = (
		local x=0.0; local y=0.0; local z=0.0
		local eps = 1e-6
		if modeStr == "XYZ" do (
			local sy = safeAsin (-(L[1][3]))
			local cy = cos sy
			if (abs cy) > eps then (
				x = atan2 ( L[2][3]/cy) (L[3][3]/cy)
				z = atan2 ( L[1][2]/cy) (L[1][1]/cy)
			) else ( x = atan2 (-(L[2][1])) L[2][2]; z = 0 )
			y = sy
		)
		if modeStr == "YZX" do (
			local sz = safeAsin (-(L[2][1]))
			local cz = cos sz
			if (abs cz) > eps then (
				y = atan2 ( L[3][1]/cz) (L[1][1]/cz)
				x = atan2 ( L[2][3]/cz) (L[2][2]/cz)
			) else ( y = atan2 (-(L[3][2])) L[3][3]; x = 0 )
			z = sz
		)
		if modeStr == "ZXY" do (
			local sx = safeAsin (-(L[3][2]))
			local cx = cos sx
			if (abs cx) > eps then (
				z = atan2 ( L[1][2]/cx) (L[2][2]/cx)
				y = atan2 ( L[3][1]/cx) (L[3][3]/cx)
			) else ( z = atan2 (-(L[1][3])) L[1][1]; y = 0 )
			x = sx
		)
		if modeStr == "XZY" do (
			local sz = safeAsin L[1][2]
			local cz = cos sz
			if (abs cz) > eps then (
				x = atan2 (-(L[3][2]/cz)) (L[2][2]/cz)
				y = atan2 (-(L[1][3]/cz)) (L[1][1]/cz)
			) else ( x = atan2 L[3][1] L[3][3]; y = 0 )
			z = sz
		)
		if modeStr == "YXZ" do (
			local sx = safeAsin L[2][3]
			local cx = cos sx
			if (abs cx) > eps then (
				y = atan2 (-(L[1][3]/cx)) (L[3][3]/cx)
				z = atan2 (-(L[2][1]/cx)) (L[2][2]/cx)
			) else ( y = atan2 L[1][2] L[1][1]; z = 0 )
			x = sx
		)
		if modeStr == "ZYX" do (
			local sy = safeAsin L[3][1]
			local cy = cos sy
			if (abs cy) > eps then (
				z = atan2 (-(L[2][1]/cy)) (L[1][1]/cy)
				x = atan2 (-(L[3][2]/cy)) (L[3][3]/cy)
			) else ( z = 0; x = atan2 L[2][3] L[2][2] )
			y = sy
		)
		#(x, y, z)
	),

	fn getParentW wm rec = (
		local pn = dget rec "parent" ""
		local pw = if pn != "" then wm[pn] else undefined
		if pw == undefined then (matrix3 1) else pw
	),

	-- ── Keyframe tables (O(1) lookups) ──────────────────────────────────
	fn frameKey f = ((floor (f * 1000.0 + 0.5)) as integer),

	fn frameTime f = (
		if f == (floor f) then ((f as integer) as time) else (f as time)
	),

	fn keyMap arr = (
		local m = Dictionary #integer
		for kf in arr do m[frameKey kf["frame"]] = kf["value"]
		m
	),

	fn frameSetOf arr = (
		local m = Dictionary #integer
		for kf in arr do m[frameKey kf["frame"]] = true
		m
	),

	fn addFrames arr frameSet frameList = (
		for kf in arr do (
			local f = kf["frame"]
			local k = frameKey f
			if not (hasDictValue frameSet k) do (
				frameSet[k] = true
				append frameList f
			)
		)
	),

	fn mapGet m k fb = (
		local v = m[k]
		if v == undefined then fb else v
	),

	-- ── Scene helpers ───────────────────────────────────────────────────
	-- Parents before children (iterative, no recursion).
	fn topoSort objs = (
		local sorted = #()
		local state = Dictionary #string
		for start in objs.keys do (
			if not (hasDictValue state start) do (
				local stack = #(start)
				while stack.count > 0 do (
					local nm = stack[stack.count]
					if hasDictValue state nm then (
						deleteItem stack stack.count
						if state[nm] == 1 do (
							state[nm] = 2
							append sorted nm
						)
					) else (
						state[nm] = 1
						local pn = dget objs[nm] "parent" ""
						if pn != "" and (hasDictValue objs pn) and not (hasDictValue state pn) do append stack pn
					)
				)
			)
		)
		sorted
	),

	fn buildLookup nodeArr = (
		local m = Dictionary #string
		for o in nodeArr do (
			if not (hasDictValue m o.name) do m[o.name] = o
		)
		m
	),

	fn getOrCreateLayer layerName = (
		local lyr = LayerManager.getLayerFromName layerName
		if lyr == undefined do lyr = LayerManager.newLayerFromName layerName
		lyr
	),

	-- 3ds Max system units per centimetre.
	fn cmToSystem = (
		local cmPerType = case units.SystemType of (
			#inches: 2.54
			#feet: 30.48
			#miles: 160934.4
			#millimeters: 0.1
			#centimeters: 1.0
			#meters: 100.0
			#kilometers: 100000.0
			default: 1.0
		)
		1.0 / (cmPerType * units.SystemScale)
	),

	-- Scale the FBX importer really used (imported position / Blender
	-- location). Returns undefined unless at least 3 objects agree within
	-- 0.5 % (objects whose location is relative to a moved parent are outliers).
	fn measureUnitFactor objs nodes = (
		local ratios = #()
		for nm in nodes.keys do (
			local loc = dget objs[nm] "location" undefined
			if loc != undefined do (
				local bl = length [loc[1], loc[2], loc[3]]
				if bl > 0.001 do append ratios ((length nodes[nm].pos) / bl)
			)
		)
		local result = undefined
		if ratios.count >= 3 do (
			sort ratios
			local med = ratios[(ratios.count + 1) / 2]
			if med > 1e-9 do (
				local inliers = 0
				for r in ratios where (abs (r / med - 1.0)) < 0.005 do inliers += 1
				if inliers * 10 >= ratios.count * 6 do result = med
			)
		)
		result
	),

	-- Node for a name: the one just imported from the FBX, else any scene node.
	fn findNode nm lookup = (
		local nd = lookup[nm]
		if nd != undefined and not (isValidNode nd) do nd = undefined
		if nd == undefined do nd = getNodeByName nm exact:true
		nd
	),

	-- Returns #(nodes Dictionary, missing names)
	fn findObjectNodes objs names lookup = (
		local nodes = Dictionary #string
		local missing = #()
		for nm in names do (
			local nd = findNode nm lookup
			if nd == undefined then append missing nm else nodes[nm] = nd
		)
		#(nodes, missing)
	),

	-- Blender units -> 3ds Max system units. Right after an FBX import the
	-- factor is checked on the imported objects, so location keys and bone
	-- dummies always match the scale the FBX importer used.
	fn resolveUnitFactor root lookup measure = (
		local U = (dget root "unit_to_cm" 100.0) * (cmToSystem())
		if measure do (
			local objs = root["objects"]
			local found = findObjectNodes objs objs.keys lookup
			local mU = measureUnitFactor objs found[1]
			if mU != undefined and (abs (mU / U - 1.0)) > 0.01 do (
				warn ("FBX was imported at " + (mU as string) + " units per Blender unit (expected " + \
					(U as string) + "); location keys follow the FBX. Check the FBX importer Units setting.")
				U = mU
			)
		)
		U
	),

	-- ── Armatures -> dummies + Skin (JSON v3) ───────────────────────────
	-- Blender computes every value (bind pose, pose, keys) as the local
	-- transform of the dummy relative to its 3ds Max parent:
	-- position (Blender units), Euler XYZ (radians), scale.
	fn tangentType s = (
		case s of (
			"flat": #flat
			"linear": #linear
			"step": #step
			default: #auto
		)
	),

	fn setKeyTangents k kf = (
		if kf != undefined do (
			local tin = kf["ti"]
			local tout = kf["to"]
			if tin != undefined do k.inTangentType = tangentType tin
			if tout != undefined do k.outTangentType = tangentType tout
		)
	),

	fn makeDummy nm size = (
		local d = Dummy name:nm
		d.boxsize = [size, size, size]
		if classOf d.pos.controller != Position_XYZ do d.pos.controller = Position_XYZ()
		if classOf d.rotation.controller != Euler_XYZ do d.rotation.controller = Euler_XYZ()
		if classOf d.scale.controller != Bezier_Scale do d.scale.controller = Bezier_Scale()
		d.rotation.controller.axisOrder = 1
		d
	),

	-- Local position / rotation / scale (relative to the parent node).
	fn setLocalPRS nd prs U = (
		local p = prs["location"]
		local r = prs["rotation"]
		local s = prs["scale"]
		local pc = nd.pos.controller
		pc.X_Position.controller.value = p[1] * U
		pc.Y_Position.controller.value = p[2] * U
		pc.Z_Position.controller.value = p[3] * U
		local rc = nd.rotation.controller
		rc.X_Rotation.controller.value = r2d r[1]
		rc.Y_Rotation.controller.value = r2d r[2]
		rc.Z_Rotation.controller.value = r2d r[3]
		nd.scale.controller.value = [s[1], s[2], s[3]]
	),

	-- Dummies in the bind pose. Returns #(dummies Dictionary, world rotation Dictionary).
	fn createBoneDummies root lookup U = (
		local dummies = Dictionary #string
		local boneW = Dictionary #string
		local arms = root["armatures"]
		if arms != undefined do (
			-- every node first: a parent may belong to another armature
			for an in arms.keys do (
				local a = arms[an]
				if (dget a "node" false) == true do (
					local maxLen = 0.0
					for b in a["bones"] do maxLen = amax maxLen (dget b "length" 0.0)
					local ad = makeDummy an (amax (maxLen * U * 0.2) 1.0)
					setLocalPRS ad a["world"] U
					dummies[an] = ad
				)
				for b in a["bones"] do (
					local bn = b["name"]
					dummies[bn] = makeDummy bn (amax ((dget b "length" 0.0) * U * 0.1) 0.5)
				)
			)
			-- hierarchy and bind pose
			for an in arms.keys do (
				for b in arms[an]["bones"] do (
					local d = dummies[b["name"]]
					local pn = dget b "parent" ""
					local pNode = if pn != "" then dummies[pn] else undefined
					if pNode == undefined and pn != "" do pNode = findNode pn lookup
					if pNode != undefined do d.parent = pNode
					setLocalPRS d b["rest"] U
					local wr = b["world_rotation"]
					boneW[b["name"]] = buildWorldRot (r2d wr[1]) (r2d wr[2]) (r2d wr[3]) "XYZ"
				)
			)
		)
		#(dummies, boneW)
	),

	-- Skin modifiers bound to the dummies in their bind pose.
	-- skinOps needs the Skin modifier shown in the Modify panel.
	fn applySkins root dummies lookup U = (
		local skins = root["skins"]
		local made = 0
		if skins != undefined and skins.count > 0 do (
			try (cui.commandPanelOpen = true) catch ()
			max modify mode
			for mn in skins.keys do (
				local srec = skins[mn]
				local nd = findNode mn lookup
				local bnodes = #()
				local missingB = 0
				for bn in srec["bones"] do (
					local d = dummies[bn]
					if d == undefined then missingB += 1 else append bnodes d
				)
				if nd == undefined then warn ("Skin: mesh '" + mn + "' not found.")
				else if missingB > 0 then warn ("Skin: dummies missing for '" + mn + "', skin skipped.")
				else (
					local weights = srec["weights"]
					local needStatic = false
					for w in weights where w.count == 0 do needStatic = true
					local staticId = 0
					if needStatic do (
						-- Blender leaves unweighted vertices in place: they follow the mesh.
						local sd = makeDummy (mn + "__SkinStatic") (amax (U * 0.05) 0.5)
						sd.parent = nd
						sd.transform = nd.transform
						try (nd.layer.addNode sd) catch ()
						append bnodes sd
						staticId = bnodes.count
						dummies[sd.name] = sd
					)
					local sk = Skin()
					addModifier nd sk
					select nd
					modPanel.setCurrentObject sk
					for i = 1 to bnodes.count do skinOps.addBone sk bnodes[i] (if i == bnodes.count then 1 else 0)
					classOf nd
					local nv = skinOps.GetNumberVertices sk
					if nv == 0 do (
						modPanel.setCurrentObject sk
						classOf nd
						nv = skinOps.GetNumberVertices sk
					)
					if nv != weights.count do
						warn (mn + ": Skin has " + (nv as string) + " vertices, Blender " + (weights.count as string) + ".")
					-- Skin bone ids, matched by name (normally the order of addBone)
					local ids = #()
					local nb = skinOps.GetNumberBones sk
					for i = 1 to bnodes.count do (
						local found = 0
						for j = 1 to nb while found == 0 do (
							if (skinOps.GetBoneName sk j 0) == bnodes[i].name do found = j
						)
						ids[i] = if found > 0 then found else i
					)
					local n = amin nv weights.count
					for vi = 1 to n do (
						local w = weights[vi]
						if w.count == 0 then skinOps.ReplaceVertexWeights sk vi ids[staticId] 1.0
						else (
							local bIds = #()
							local bWs = #()
							local k = 1
							while k < w.count do (
								append bIds ids[(w[k] as integer) + 1]
								append bWs w[k + 1]
								k += 2
							)
							skinOps.ReplaceVertexWeights sk vi bIds bWs
						)
					)
					made += 1
				)
			)
			max create mode
		)
		made
	),

	fn keyFloatTrack ctrl keys mult = (
		for kf in keys do (
			local k = addNewKey ctrl (frameTime kf["frame"])
			k.value = kf["value"] * mult
			setKeyTangents k kf
		)
	),

	-- Keys for one dummy. Returns true if any key was made.
	fn keyDummy d anim U = (
		local made = false
		local la = dget anim "location" undefined
		if la != undefined do (
			local pc = d.pos.controller
			local kX = dget la "X" #()
			local kY = dget la "Y" #()
			local kZ = dget la "Z" #()
			if kX.count > 0 do keyFloatTrack pc.X_Position.controller kX U
			if kY.count > 0 do keyFloatTrack pc.Y_Position.controller kY U
			if kZ.count > 0 do keyFloatTrack pc.Z_Position.controller kZ U
			if (kX.count + kY.count + kZ.count) > 0 do made = true
		)
		local ra = dget anim "rotation" undefined
		if ra != undefined do (
			local rc = d.rotation.controller
			local mult = 180.0 / pi
			local kX = dget ra "X" #()
			local kY = dget ra "Y" #()
			local kZ = dget ra "Z" #()
			if kX.count > 0 do keyFloatTrack rc.X_Rotation.controller kX mult
			if kY.count > 0 do keyFloatTrack rc.Y_Rotation.controller kY mult
			if kZ.count > 0 do keyFloatTrack rc.Z_Rotation.controller kZ mult
			if (kX.count + kY.count + kZ.count) > 0 do made = true
		)
		-- Bezier_Scale keeps X/Y/Z in one key: all keys are created first,
		-- then filled at their own time (no extra frame-0 key).
		local sa = dget anim "scale" undefined
		if sa != undefined do (
			local kX = dget sa "X" #()
			local kY = dget sa "Y" #()
			local kZ = dget sa "Z" #()
			if (kX.count + kY.count + kZ.count) > 0 do (
				local allSet = Dictionary #integer
				local allFrames = #()
				addFrames kX allSet allFrames
				addFrames kY allSet allFrames
				addFrames kZ allSet allFrames
				local hints = Dictionary #integer
				for arr in #(kX, kY, kZ) do (
					for kf in arr do (
						local hk = frameKey kf["frame"]
						if not (hasDictValue hints hk) do hints[hk] = kf
					)
				)
				local xM = keyMap kX
				local yM = keyMap kY
				local zM = keyMap kZ
				local sc = d.scale.controller
				local cur = sc.value
				for f in allFrames do addNewKey sc (frameTime f)
				with animate on (
					for f in allFrames do (
						local k = frameKey f
						local sv = [mapGet xM k cur.x, mapGet yM k cur.y, mapGet zM k cur.z]
						at time (frameTime f) (sc.value = sv)
					)
				)
				for f in allFrames do (
					local idx = getKeyIndex sc (frameTime f)
					if idx > 0 do setKeyTangents (getKey sc idx) hints[frameKey f]
				)
				made = true
			)
		)
		made
	),

	-- After the Skin bind: pose values (unkeyed channels), then keys.
	-- Returns the number of animated dummies.
	fn animateDummies root dummies U = (
		local arms = root["armatures"]
		local animated = 0
		if arms != undefined do (
			for an in arms.keys do (
				for b in arms[an]["bones"] do (
					local d = dummies[b["name"]]
					if d != undefined do (
						setLocalPRS d b["pose"] U
						local anim = dget b "animation" undefined
						if anim != undefined and (keyDummy d anim U) do animated += 1
					)
				)
			)
		)
		animated
	),

	-- Bone dummies go to the layer of their armature's collection.
	fn layerDummies root dummies = (
		local cols = root["collections"]
		local objCols = if cols != undefined then cols["objects"] else undefined
		local arms = root["armatures"]
		if objCols != undefined and arms != undefined do (
			for an in arms.keys do (
				local ln = objCols[an]
				if ln != undefined do (
					local lyr = getOrCreateLayer ln
					if dummies[an] != undefined do lyr.addNode dummies[an]
					for b in arms[an]["bones"] do (
						local d = dummies[b["name"]]
						if d != undefined do lyr.addNode d
					)
				)
			)
		)
	),

	-- ── Apply JSON (passes and math as v1.1.1) ──────────────────────────
	-- U: Blender units -> system units (resolveUnitFactor).
	-- boneW: world rotations of the bone dummies (parents of objects).
	-- Returns #(appliedCount, animatedCount, timingText)
	fn applyData root lookup U boneW = (
		local objs = root["objects"]
		local sorted = topoSort objs

		local found = findObjectNodes objs sorted lookup
		local nodes = found[1]
		local missing = found[2]
		if missing.count > 0 do (
			local shown = ""
			for i = 1 to (amin missing.count 5) do shown += (if i > 1 then ", " else "") + missing[i]
			warn ((missing.count as string) + " object(s) not found in the scene: " + shown)
		)

		local bfps = dget root "fps" undefined
		if bfps != undefined and (abs (bfps - frameRate)) > 0.01 do
			warn ("Blender fps " + (bfps as string) + " differs from 3ds Max fps " + (frameRate as string) + "; keys keep their frame numbers.")

		-- Extend (never shrink) the time line to Blender's frame range.
		local fs = dget root "frame_start" undefined
		local fe = dget root "frame_end" undefined
		if fs != undefined and fe != undefined and fe > fs do (
			local r0 = amin (animationRange.start.frame as float) fs
			local r1 = amax (animationRange.end.frame as float) fe
			if r0 < animationRange.start.frame or r1 > animationRange.end.frame do
				animationRange = interval (frameTime r0) (frameTime r1)
		)

		local worldMats = Dictionary #string
		for nm in sorted do (
			local rec = objs[nm]
			local re = dget rec "rotation_euler" #(0.0, 0.0, 0.0)
			worldMats[nm] = buildWorldRot (r2d re[1]) (r2d re[2]) (r2d re[3]) (dget rec "rotation_mode" "XYZ")
		)
		-- objects parented to a bone dummy use the dummy's world rotation
		for bn in boneW.keys where not (hasDictValue worldMats bn) do worldMats[bn] = boneW[bn]

		local animated = 0
		local tA = timeStamp()

		-- Pass 1a: rotation ORDER
		for nm in sorted do (
			local nd = nodes[nm]
			if nd != undefined do (
				local rc = nd.rotation.controller
				if classOf rc != Euler_XYZ do (
					nd.rotation.controller = Euler_XYZ()
					rc = nd.rotation.controller
				)
				rc.axisOrder = blenderOrderToMax (dget objs[nm] "rotation_mode" "XYZ")
			)
		)

		-- Pass 1b: rotation VALUES (unparented -> local == world)
		for nm in sorted do (
			local nd = nodes[nm]
			if nd != undefined do (
				local le = decomposeEuler worldMats[nm] (dget objs[nm] "rotation_mode" "XYZ")
				local rc = nd.rotation.controller
				rc.X_Rotation.controller.value = le[1]
				rc.Y_Rotation.controller.value = le[2]
				rc.Z_Rotation.controller.value = le[3]
			)
		)

		-- Pass 1c: scale
		for nm in sorted do (
			local nd = nodes[nm]
			local js = if nd != undefined then objs[nm]["scale"] else undefined
			if js != undefined do nd.scale = [js[1], js[2], js[3]]
		)

		-- Pass 1d: parent objects (3ds Max keeps world transforms)
		for nm in sorted do (
			local nd = nodes[nm]
			local pn = if nd != undefined then (dget objs[nm] "parent" "") else ""
			if pn != "" do (
				local pNode = nodes[pn]
				if pNode == undefined do pNode = getNodeByName pn exact:true
				if pNode != undefined do nd.parent = pNode
			)
		)
		local tB = timeStamp()

		-- Pass 2: rotation & scale animation keys
		for nm in sorted do (
			local nd = nodes[nm]
			local rec = objs[nm]
			local anim = if nd != undefined then rec["animation"] else undefined
			if anim != undefined do (
				local modeStr = dget rec "rotation_mode" "XYZ"
				local iPW = inverse (getParentW worldMats rec)
				local hasKeys = false

				-- Rotation keys: W from all three axes, a key only where Blender had one.
				local ra = anim["rotation_euler"]
				if ra != undefined do (
					local kX = dget ra "X" #()
					local kY = dget ra "Y" #()
					local kZ = dget ra "Z" #()
					if (kX.count + kY.count + kZ.count) > 0 do (
						hasKeys = true
						local fsX = frameSetOf kX
						local fsY = frameSetOf kY
						local fsZ = frameSetOf kZ
						local allSet = Dictionary #integer
						local allFrames = #()
						addFrames kX allSet allFrames
						addFrames kY allSet allFrames
						addFrames kZ allSet allFrames
						local xM = keyMap kX
						local yM = keyMap kY
						local zM = keyMap kZ
						local jre = dget rec "rotation_euler" #(0.0, 0.0, 0.0)
						local rc = nd.rotation.controller
						for f in allFrames do (
							local k = frameKey f
							local rx = r2d (mapGet xM k jre[1])
							local ry = r2d (mapGet yM k jre[2])
							local rz = r2d (mapGet zM k jre[3])
							local L = (buildWorldRot rx ry rz modeStr) * iPW
							local le = decomposeEuler L modeStr
							local tt = frameTime f
							if hasDictValue fsX k do (
								local kiX = addNewKey rc.X_Rotation.controller tt
								kiX.value = le[1]
							)
							if hasDictValue fsY k do (
								local kiY = addNewKey rc.Y_Rotation.controller tt
								kiY.value = le[2]
							)
							if hasDictValue fsZ k do (
								local kiZ = addNewKey rc.Z_Rotation.controller tt
								kiZ.value = le[3]
							)
						)
					)
				)

				-- Scale keys: Bezier_Scale keeps X/Y/Z in one key. All keys are
				-- created first, then their values are set at their own time, so no
				-- extra frame-0 key can appear. Same rule as location keys: Blender
				-- values are relative to the parent's pose at frame 0.
				local sa = anim["scale"]
				if sa != undefined do (
					local kX = dget sa "X" #()
					local kY = dget sa "Y" #()
					local kZ = dget sa "Z" #()
					if (kX.count + kY.count + kZ.count) > 0 do (
						hasKeys = true
						local allSet = Dictionary #integer
						local allFrames = #()
						addFrames kX allSet allFrames
						addFrames kY allSet allFrames
						addFrames kZ allSet allFrames
						local xM = keyMap kX
						local yM = keyMap kY
						local zM = keyMap kZ
						local js = dget rec "scale" #(1.0, 1.0, 1.0)
						local pS = if nd.parent != undefined then nd.parent.transform.scale else [1.0, 1.0, 1.0]
						if (abs pS.x) < 1e-6 do pS.x = 1.0
						if (abs pS.y) < 1e-6 do pS.y = 1.0
						if (abs pS.z) < 1e-6 do pS.z = 1.0
						if classOf nd.scale.controller != Bezier_Scale do nd.scale.controller = Bezier_Scale()
						local sc = nd.scale.controller
						for f in allFrames do addNewKey sc (frameTime f)
						with animate on (
							for f in allFrames do (
								local k = frameKey f
								local sv = [(mapGet xM k js[1]) / pS.x, (mapGet yM k js[2]) / pS.y, (mapGet zM k js[3]) / pS.z]
								at time (frameTime f) (sc.value = sv)
							)
						)
					)
				)
				if hasKeys do animated += 1
			)
		)
		local tC = timeStamp()

		-- Pass 3: location animation keys (after all rotations are keyed)
		for nm in sorted do (
			local nd = nodes[nm]
			local rec = objs[nm]
			local anim = if nd != undefined then rec["animation"] else undefined
			local la = if anim != undefined then anim["location"] else undefined
			if la != undefined do (
				local kX = dget la "X" #()
				local kY = dget la "Y" #()
				local kZ = dget la "Z" #()
				if (kX.count + kY.count + kZ.count) > 0 do (
					if (dget anim "rotation_euler" undefined) == undefined do animated += 1
					local fsX = frameSetOf kX
					local fsY = frameSetOf kY
					local fsZ = frameSetOf kZ
					local allSet = Dictionary #integer
					local allFrames = #()
					addFrames kX allSet allFrames
					addFrames kY allSet allFrames
					addFrames kZ allSet allFrames
					local xM = keyMap kX
					local yM = keyMap kY
					local zM = keyMap kZ
					local jl = dget rec "location" #(0.0, 0.0, 0.0)

					-- Position_XYZ: each axis has its own Bezier sub-controller.
					local savedWorldPos = copy nd.pos
					nd.pos.controller = Position_XYZ()
					nd.transform.pos = savedWorldPos

					local pc = nd.pos.controller
					local parentTMInv = if nd.parent != undefined then (inverse nd.parent.transform) else undefined

					for f in allFrames do (
						local k = frameKey f
						local wPos = [(mapGet xM k jl[1]) * U, (mapGet yM k jl[2]) * U, (mapGet zM k jl[3]) * U]
						local lPos = if parentTMInv != undefined then (wPos * parentTMInv) else wPos
						local tt = frameTime f
						if hasDictValue fsX k do (
							local kiX = addNewKey pc.X_Position.controller tt
							kiX.value = lPos.x
						)
						if hasDictValue fsY k do (
							local kiY = addNewKey pc.Y_Position.controller tt
							kiY.value = lPos.y
						)
						if hasDictValue fsZ k do (
							local kiZ = addNewKey pc.Z_Position.controller tt
							kiZ.value = lPos.z
						)
					)
				)
			)
		)
		local tD = timeStamp()

		-- Pass 4: layers from Blender collections
		local cols = root["collections"]
		if cols != undefined do (
			local layerDict = Dictionary #string
			local lyrs = cols["layers"]
			if lyrs != undefined do (
				for ln in lyrs.keys do layerDict[ln] = getOrCreateLayer ln
				for ln in lyrs.keys do (
					local pln = lyrs[ln]
					if pln != undefined and pln != "" do (
						local childLyr = layerDict[ln]
						local parentLyr = layerDict[pln]
						if childLyr != undefined and parentLyr != undefined do childLyr.setParent parentLyr
					)
				)
			)
			local objCols = cols["objects"]
			if objCols != undefined do (
				for onm in objCols.keys do (
					local nd = nodes[onm]
					if nd != undefined do (
						local ln = objCols[onm]
						local lyr = layerDict[ln]
						if lyr == undefined do lyr = getOrCreateLayer ln
						lyr.addNode nd
					)
				)
			)
		)
		local tE = timeStamp()

		local timing = "transforms " + (((tB - tA) / 1000.0) as string) + " s, rotation/scale keys " + \
			(((tC - tB) / 1000.0) as string) + " s, location keys " + (((tD - tC) / 1000.0) as string) + \
			" s, layers " + (((tE - tD) / 1000.0) as string) + " s"
		#(nodes.count, animated, timing)
	),

	-- ── FBX import ──────────────────────────────────────────────────────
	-- Returns #(success, newNodes)
	fn importFBX fbxPath = (
		try (pluginManager.loadClass FbxImporter) catch ()
		local beforeSet = Dictionary #integer
		for o in objects do beforeSet[o.inode.handle] = true
		local pushed = true
		try (FBXImporterSetParam "PushSettings") catch (pushed = false)
		try (FBXImporterSetParam "Mode" #create) catch ()
		try (FBXImporterSetParam "Animation" false) catch ()
		try (FBXImporterSetParam "UpAxis" "Z") catch ()
		local imp = try (FBXIMP) catch (undefined)
		local success = false
		try (
			success = if imp != undefined then (importFile fbxPath #noPrompt using:imp) else (importFile fbxPath #noPrompt)
		) catch (
			warn ("FBX import error: " + (getCurrentException()))
			success = false
		)
		if pushed do (try (FBXImporterSetParam "PopSettings") catch ())
		local newNodes = for o in objects where not (hasDictValue beforeSet o.inode.handle) collect o
		#((success == true), newNodes)
	),

	-- ── One import: JSON (+ FBX) ────────────────────────────────────────
	-- fbxPath: full path, "" = apply to objects already in the scene,
	-- "<auto>" = the FBX named in the JSON, next to it.
	-- Returns #(ok, message, objectCount)
	fn runImport jsonPath fbxPath doReplace = (
		local t0 = timeStamp()
		local root = undefined
		local msg = ""
		try (root = parseJSON (readText jsonPath)) catch (msg = "Cannot read JSON: " + (getCurrentException()))
		local objs = if root != undefined and (classOf root) == Dictionary then root["objects"] else undefined
		if objs == undefined or (classOf objs) != Dictionary then (
			if msg == "" do msg = "Not a Blender bridge JSON (no 'objects'): " + jsonPath
			#(false, msg, 0)
		) else (
			local t1 = timeStamp()
			if fbxPath == "<auto>" do (
				local nm = dget root "fbx" ""
				local cand = if nm != "" then (pathConfig.appendPath (getFilenamePath jsonPath) nm) else ""
				fbxPath = if cand != "" and (fileExists cand) then cand else ""
				if fbxPath == "" do (
					if nm == "" then warn "The JSON names no FBX; applying to objects already in the scene."
					else warn ("FBX not found next to the JSON (" + nm + "); applying to objects already in the scene.")
				)
			)
			sliderTime = 0f
			local deleted = 0
			local lookup = undefined
			local newNodes = #()
			local fbxOk = true
			-- Bone dummies (and their Skin helpers) of a previous send are replaced too.
			local arms = dget root "armatures" undefined
			local rigNames = Dictionary #string
			if arms != undefined do (
				for an in arms.keys do (
					rigNames[an] = true
					for b in arms[an]["bones"] do rigNames[b["name"]] = true
				)
			)
			local skinRecs = dget root "skins" undefined
			if skinRecs != undefined do (
				for mn in skinRecs.keys do rigNames[mn + "__SkinStatic"] = true
			)
			if fbxPath != "" then (
				-- Replace: same-named objects are renamed out of the way, then
				-- deleted only if the FBX import succeeded (names restored if not).
				local oldNodes = #()
				local oldNames = #()
				if doReplace do (
					oldNodes = for o in objects where (hasDictValue objs o.name) or (hasDictValue rigNames o.name) collect o
					for o in oldNodes do (
						append oldNames o.name
						o.name = o.name + "__BlenderBridgeOld"
					)
				)
				local r = importFBX fbxPath
				fbxOk = r[1]
				newNodes = r[2]
				if fbxOk then (
					local doomed = for o in oldNodes where (isValidNode o) collect o
					deleted = doomed.count
					if doomed.count > 0 do delete doomed
				) else (
					for i = 1 to oldNodes.count where (isValidNode oldNodes[i]) do oldNodes[i].name = oldNames[i]
				)
				lookup = buildLookup newNodes
			) else (
				lookup = buildLookup (objects as array)
			)
			local t2 = timeStamp()
			if not fbxOk then (
				#(false, "FBX import failed: " + fbxPath, 0)
			) else (
				local res = undefined
				local applyErr = ""
				local doRigs = fbxPath != "" and arms != undefined
				if arms != undefined and not doRigs do
					warn "Bones -> dummies + Skin are built only together with the FBX import; skipped."
				local dummies = Dictionary #string
				local boneW = Dictionary #string
				local nSkins = 0
				local nRigAnim = 0
				sliderTime = 0f
				-- Nothing selected and Create panel: no command panel refresh per change.
				clearSelection()
				try (setCommandPanelTaskMode #create) catch ()
				local U = resolveUnitFactor root lookup (fbxPath != "")
				disableSceneRedraw()
				try (
					with undo off (
						with animate off (
							if doRigs do (
								local rig = createBoneDummies root lookup U
								dummies = rig[1]
								boneW = rig[2]
							)
							res = applyData root lookup U boneW
						)
					)
				) catch (
					applyErr = getCurrentException()
				)
				enableSceneRedraw()
				local t3 = timeStamp()
				-- Skin (bind pose = dummies as created), then the dummy animation.
				if applyErr == "" and doRigs do (
					try (
						with undo off (
							with animate off (
								nSkins = applySkins root dummies lookup U
							)
						)
						clearSelection()
						disableSceneRedraw()
						with undo off (
							with animate off (
								nRigAnim = animateDummies root dummies U
								layerDummies root dummies
							)
						)
						enableSceneRedraw()
					) catch (
						enableSceneRedraw()
						applyErr = "bones/skin: " + (getCurrentException())
					)
				)
				try (setCommandPanelTaskMode #create) catch ()
				clearSelection()
				local sel = for o in newNodes where (isValidNode o) collect o
				for k in dummies.keys where (isValidNode dummies[k]) do append sel dummies[k]
				if sel.count > 0 do select sel
				redrawViews()
				local t4 = timeStamp()
				if applyErr != "" then (
					logLine ("Apply error: " + applyErr)
					#(false, "Error while applying the JSON: " + applyErr, 0)
				) else (
					local secs = (t4 - t0) / 1000.0
					msg = (res[1] as string) + " objects (" + ((res[2] + nRigAnim) as string) + " animated) in " + (secs as string) + " s"
					if dummies.count > 0 do msg += ", " + (dummies.count as string) + " dummies, " + (nSkins as string) + " skinned"
					if deleted > 0 do msg += ", replaced " + (deleted as string)
					logLine ("Done: " + msg)
					logLine ("  read+parse JSON " + (((t1 - t0) / 1000.0) as string) + " s, FBX " + \
						(((t2 - t1) / 1000.0) as string) + " s, apply " + (((t3 - t2) / 1000.0) as string) + \
						" s, bones/skin " + (((t4 - t3) / 1000.0) as string) + " s")
					logLine ("  apply: " + res[3])
					#(true, msg, res[1])
				)
			)
		)
	),

	-- ── Bridge jobs ─────────────────────────────────────────────────────
	fn writeResult jobId jobStatus msg secs objCount = (
		local w = ""
		for i = 1 to warnings.count do (
			if i > 1 do w += ","
			w += "\"" + (jsonEsc warnings[i]) + "\""
		)
		local txt = "{\"id\":\"" + (jsonEsc jobId) + "\",\"status\":\"" + jobStatus + "\",\"message\":\"" + \
			(jsonEsc msg) + "\",\"seconds\":" + (secs as string) + ",\"objects\":" + (objCount as string) + \
			",\"warnings\":[" + w + "]}"
		try (writeTextAtomic (pathConfig.appendPath bridgeDir "result.json") txt) catch (logLine "Cannot write result.json")
	),

	fn processJob jobPath = (
		local t0 = timeStamp()
		local age = try (fileAgeSeconds jobPath) catch (0.0)
		local job = undefined
		try (job = parseJSON (readText jobPath)) catch ()
		deleteFileRetry jobPath
		local isJob = job != undefined and (classOf job) == Dictionary
		local jobId = if isJob then (dget job "id" "") else ""
		if jobId != "" and jobId == lastJobId then (
			logLine "Job already processed, ignored."
		) else (
			lastJobId = jobId
			warnings = #()
			local jobStatus = "error"
			local msg = ""
			local objCount = 0
			if not isJob then (
				msg = "Unreadable job file."
			) else (
				local jsonPath = dget job "json" ""
				local fbxPath = dget job "fbx" ""
				if age > 900.0 then (
					msg = "Job expired (" + ((age as integer) as string) + " s old), ignored."
				) else if not (fileExists jsonPath) then (
					msg = "JSON not found: " + jsonPath
				) else if fbxPath != "" and not (fileExists fbxPath) then (
					msg = "FBX not found: " + fbxPath
				) else (
					logLine ("Job from Blender: " + jsonPath)
					local r = try (runImport jsonPath fbxPath (dget job "replace" true)) catch (#(false, "3ds Max error: " + (getCurrentException()), 0))
					jobStatus = if r[1] then "ok" else "error"
					msg = r[2]
					objCount = r[3]
				)
			)
			if jobStatus != "ok" do logLine ("Job failed: " + msg)
			lastLine1 = (if jobStatus == "ok" then "OK: " else "ERROR: ") + msg
			lastLine2 = if warnings.count > 0 then ((warnings.count as string) + " warning(s), see Listener") else ""
			writeResult jobId jobStatus msg ((timeStamp() - t0) / 1000.0) objCount
		)
	),

	fn writeHeartbeat = (
		try (
			if ensureDir bridgeDir do (
				local txt = "{\"app\":\"3ds Max\",\"max_version\":" + ((maxVersion())[1] as string) + \
					",\"bridge\":\"" + bridgeVersion + "\",\"listening\":true}"
				writeText (pathConfig.appendPath bridgeDir "listener.json") txt
			)
		) catch ()
	),

	fn updateUI = (
		if BlenderMaxBridgeRollout != undefined and BlenderMaxBridgeRollout.open do (
			try (BlenderMaxBridgeRollout.refreshState()) catch ()
		)
	),

	fn stopListening = (
		if BlenderMaxBridge_Timer != undefined do (
			try (BlenderMaxBridge_Timer.Stop()) catch ()
			try (dotNet.removeAllEventHandlers BlenderMaxBridge_Timer) catch ()
			try (BlenderMaxBridge_Timer.Dispose()) catch ()
			BlenderMaxBridge_Timer = undefined
		)
		if listening do (
			deleteFileSafe (pathConfig.appendPath bridgeDir "listener.json")
			logLine "Listener stopped."
		)
		listening = false
	),

	fn startListening = (
		stopListening()
		if not (ensureDir bridgeDir) then (
			logLine ("Cannot create the bridge folder: " + bridgeDir)
			false
		) else (
			BlenderMaxBridge_Timer = dotNetObject "System.Windows.Forms.Timer"
			BlenderMaxBridge_Timer.Interval = 500
			dotNet.addEventHandler BlenderMaxBridge_Timer "Tick" BlenderMaxBridge_onTick
			dotNet.setLifetimeControl BlenderMaxBridge_Timer #dotnet
			listening = true
			busy = false
			lastBeat = 0
			writeHeartbeat()
			BlenderMaxBridge_Timer.Start()
			logLine ("Listening for Blender in " + bridgeDir)
			true
		)
	),

	fn tick = (
		if listening and not busy do (
			local now = timeStamp()
			if (now - lastBeat) > 2000 or now < lastBeat do (
				lastBeat = now
				writeHeartbeat()
			)
			local jobPath = pathConfig.appendPath bridgeDir "job.json"
			if fileExists jobPath do (
				busy = true
				try (BlenderMaxBridge_Timer.Stop()) catch ()
				try (processJob jobPath) catch (logLine ("Job crashed: " + (getCurrentException())))
				busy = false
				lastBeat = 0
				if listening and BlenderMaxBridge_Timer != undefined do (try (BlenderMaxBridge_Timer.Start()) catch ())
				updateUI()
			)
		)
	),

	-- ── Start with 3ds Max ──────────────────────────────────────────────
	fn autoStartFile = (
		pathConfig.appendPath (getDir #userStartupScripts) "BlenderMaxBridge_AutoStart.ms"
	),
	fn autoStartEnabled = (
		fileExists (autoStartFile())
	),
	fn setAutoStart doEnable = (
		local f = autoStartFile()
		if doEnable then (
			if scriptFile == "" or not (fileExists scriptFile) then (
				messageBox "Run this script from a saved .ms file first (Scripting > Run Script)." title:"Blender -> 3ds Max Bridge"
				false
			) else (
				local txt = "-- Auto-generated by Blender -> 3ds Max Bridge " + bridgeVersion + "\n" + \
					"global BlenderMaxBridge_AutoStart = true\n" + \
					"try (fileIn @\"" + scriptFile + "\") catch (format \"Blender->Max Bridge autostart failed: %\\n\" (getCurrentException()))\n"
				try (
					writeText f txt
					logLine ("Autostart enabled: " + f)
					true
				) catch (
					logLine ("Cannot write " + f)
					false
				)
			)
		) else (
			deleteFileSafe f
			logLine "Autostart disabled."
			true
		)
	),

	-- ── Entry points ────────────────────────────────────────────────────
	fn setup srcFile = (
		scriptFile = if srcFile != undefined then srcFile else ""
		loadSettings()
		-- After an update (new script file), point the autostart at this script.
		if scriptFile != "" and (autoStartEnabled()) do (
			local stub = try (readText (autoStartFile())) catch ("")
			if (findString stub scriptFile) == undefined do setAutoStart true
		)
	),

	fn setBridgeDir d = (
		local wasOn = listening
		if wasOn do stopListening()
		bridgeDir = d
		saveSettings()
		if wasOn do startListening()
	),

	fn manualImport jsonPath withFbx doReplace = (
		warnings = #()
		local r = runImport jsonPath (if withFbx then "<auto>" else "") (doReplace and withFbx)
		lastLine1 = (if r[1] then "OK: " else "ERROR: ") + r[2]
		lastLine2 = if warnings.count > 0 then ((warnings.count as string) + " warning(s), see Listener") else ""
		local txt = r[2]
		for w in warnings do txt += "\n- " + w
		messageBox txt title:"Blender -> 3ds Max Bridge"
		r[1]
	)
)

-- Timer callback. An unexpected error stops the listener instead of
-- repeating every 0.5 s.
fn BlenderMaxBridge_onTick sender evt = (
	try (
		if BlenderMaxBridge != undefined do BlenderMaxBridge.tick()
	) catch (
		format "[Blender->Max Bridge] Listener error, listener stopped: %\n" (getCurrentException())
		try (BlenderMaxBridge.busy = false) catch ()
		try (BlenderMaxBridge.stopListening()) catch ()
		try (BlenderMaxBridge.updateUI()) catch ()
	)
)

rollout BlenderMaxBridgeRollout "Blender -> 3ds Max Bridge  v2.1" width:380 (
	group "Bridge folder (same as in the Blender add-on preferences)" (
		edittext etDir "" width:322 align:#left across:2
		button btnDir "..." width:28 height:18 align:#right
	)
	checkbutton cbListen "Start listening" width:356 height:34 align:#center
	label lblState "Listener: stopped" align:#left width:356
	checkbox chkAuto "Start the listener automatically when 3ds Max starts" align:#left
	group "Last import" (
		label lblLast1 "-" align:#left width:350
		label lblLast2 "" align:#left width:350
	)
	group "Manual import (without Blender)" (
		button btnImport "Import JSON..." width:120 align:#left across:2
		checkbox chkFbx "Import the FBX named in the JSON" checked:true align:#left offset:[-50,4]
		checkbox chkReplace "Replace same-named objects (with FBX only)" checked:true align:#left
	)

	fn refreshState = (
		local b = BlenderMaxBridge
		cbListen.checked = b.listening
		cbListen.text = if b.listening then "Listening...  (click to stop)" else "Start listening"
		lblState.text = if b.listening then "Listener: waiting for Blender" else "Listener: stopped"
		etDir.text = b.bridgeDir
		lblLast1.text = b.lastLine1
		lblLast2.text = b.lastLine2
		chkAuto.checked = b.autoStartEnabled()
	)

	on BlenderMaxBridgeRollout open do refreshState()

	on btnDir pressed do (
		local d = getSavePath caption:"Bridge folder" initialDir:BlenderMaxBridge.bridgeDir
		if d != undefined do (
			BlenderMaxBridge.setBridgeDir d
			refreshState()
		)
	)

	on etDir entered txt do (
		if txt != "" do BlenderMaxBridge.setBridgeDir txt
		refreshState()
	)

	on cbListen changed state do (
		if state then BlenderMaxBridge.startListening() else BlenderMaxBridge.stopListening()
		refreshState()
	)

	on chkAuto changed state do (
		BlenderMaxBridge.setAutoStart state
		refreshState()
	)

	on btnImport pressed do (
		local f = getOpenFileName caption:"Select the Blender JSON" types:"JSON (*.json)|*.json|All files (*.*)|*.*|"
		if f != undefined do (
			BlenderMaxBridge.manualImport f chkFbx.checked chkReplace.checked
			refreshState()
		)
	)
)

BlenderMaxBridge = BlenderMaxBridgeStruct()
BlenderMaxBridge.setup (getSourceFileName())

if BlenderMaxBridge_AutoStart == true then (
	BlenderMaxBridge_AutoStart = false
	BlenderMaxBridge.startListening()
) else (
	if BlenderMaxBridge_Resume do BlenderMaxBridge.startListening()
	try (destroyDialog BlenderMaxBridgeRollout) catch ()
	createDialog BlenderMaxBridgeRollout
)
