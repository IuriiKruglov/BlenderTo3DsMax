-- ============================================================
--  Blender JSON Importer for 3ds Max
--  Version 1.1
--
--  Created by Claude (Anthropic)
--  under the leadership of Kruglov Iurii
-- ============================================================
--
--  ROTATION / POSITION FORMULA
--    W = R1(a1)*R2(a2)*R3(a3)   (rotation_mode order, from JSON radians)
--    L = W * inverse(parent_W)
--    decomposeEuler(L, mode) -> sub-controller degrees
--    Location keys: lPos = worldPos * inverse(parent.transform)
-- ============================================================

struct BlenderJSON_Importer_Struct (

	-- ── Minimal JSON parser ─────────────────────────────────────────────
	fn skipWS src pos = (
		while pos <= src.count and \
			(src[pos]==" " or src[pos]=="\t" or src[pos]=="\n" or src[pos]=="\r") do
			pos += 1
		pos
	),
	fn parseString src pos = (
		pos += 1; local sb = ""; local esc = false
		while pos <= src.count do (
			local c = src[pos]
			if esc then (
				case c of (
					"n":  sb += "\n"
					"t":  sb += "\t"
					"r":  sb += "\r"
					"\\": sb += "\\"
					"\"": sb += "\""
					default: sb += c
				)
				esc = false
			) else if c == "\\" then (esc = true
			) else if c == "\"" then (pos += 1; return #(sb, pos)
			) else sb += c
			pos += 1
		)
		#(sb, pos)
	),
	fn parseNumber src pos = (
		local s = pos
		if src[pos] == "-" do pos += 1
		while pos <= src.count and src[pos] >= "0" and src[pos] <= "9" do pos += 1
		if pos <= src.count and src[pos] == "." do (
			pos += 1
			while pos <= src.count and src[pos] >= "0" and src[pos] <= "9" do pos += 1
		)
		if pos <= src.count and (src[pos]=="e" or src[pos]=="E") do (
			pos += 1
			if pos <= src.count and (src[pos]=="+" or src[pos]=="-") do pos += 1
			while pos <= src.count and src[pos] >= "0" and src[pos] <= "9" do pos += 1
		)
		#(execute (substring src s (pos-s)), pos)
	),
	fn parseValue src pos = #(undefined, pos),
	fn parseArray src pos = (
		pos += 1; local arr = #()
		pos = skipWS src pos
		if pos <= src.count and src[pos] == "]" do return #(arr, pos+1)
		local run = true
		while run do (
			pos = skipWS src pos
			local r = parseValue src pos; append arr r[1]; pos = r[2]
			pos = skipWS src pos
			if pos <= src.count and src[pos]=="," then pos+=1 else run=false
		)
		pos = skipWS src pos
		if pos <= src.count and src[pos]=="]" do pos += 1
		#(arr, pos)
	),
	fn parseObject src pos = (
		pos += 1; local d = Dictionary #string
		pos = skipWS src pos
		if pos <= src.count and src[pos]=="}" do return #(d, pos+1)
		local run = true
		while run do (
			pos = skipWS src pos
			local kr = parseString src pos; local k=kr[1]; pos=kr[2]
			pos = skipWS src pos
			if pos <= src.count and src[pos]==":" do pos += 1
			pos = skipWS src pos
			local vr = parseValue src pos; d[k]=vr[1]; pos=vr[2]
			pos = skipWS src pos
			if pos <= src.count and src[pos]=="," then pos+=1 else run=false
		)
		pos = skipWS src pos
		if pos <= src.count and src[pos]=="}" do pos += 1
		#(d, pos)
	),
	fn parseValue src pos = (
		pos = skipWS src pos
		if pos > src.count do return #(undefined, pos)
		local c = src[pos]
		if      c=="\"" then parseString src pos
		else if c=="{"  then parseObject src pos
		else if c=="["  then parseArray  src pos
		else if c=="t"  then #(true,      pos+4)
		else if c=="f"  then #(false,     pos+5)
		else if c=="n"  then #(undefined, pos+4)
		else                 parseNumber src pos
	),

	-- ── Helpers ─────────────────────────────────────────────────────────
	fn r2d v = v * (180.0 / pi),

	fn dictHasKey d k = (
		local f = false
		for x in d.Keys do if x == k do f = true
		f
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

	fn collectFrames arr frames = (
		for kf in arr do (
			local fi = kf["frame"] as integer
			if findItem frames fi == 0 do append frames fi
		)
	),
	fn buildMap arr = (
		local d = Dictionary #string
		for kf in arr do d[(kf["frame"] as integer) as string] = kf["value"]
		d
	),
	fn mapGet d fr fb = (
		local k = fr as string
		for x in d.Keys do if x == k do return d[x]
		fb
	),

	-- ── Topological sort ────────────────────────────────────────────────
	fn topoSort jsonRoot = (
		local all = #(); for k in jsonRoot.Keys do append all k
		local sorted = #(); local visited = Dictionary #string
		for startName in all do (
			local already = false
			for k in visited.Keys do if k == startName do already = true
			if already do continue
			local stack = #(#(startName, 0))
			while stack.count > 0 do (
				local top = stack[stack.count]; deleteItem stack stack.count
				local tn = top[1]; local ph = top[2]
				if ph == 1 then (
					append sorted tn
				) else (
					local v = false
					for k in visited.Keys do if k == tn do v = true
					if v do continue
					visited[tn] = true
					append stack #(tn, 1)
					local jo = jsonRoot[tn]
					if jo != undefined and (dictHasKey jo "parent") do (
						local pn = jo["parent"]
						if pn != undefined and pn != "" do (
							local pv = false
							for k in visited.Keys do if k == pn do pv = true
							if not pv do append stack #(pn, 0)
						)
					)
				)
			)
		)
		sorted
	),

	fn readFileText jsonPath = (
		local f = openFile jsonPath mode:"r"
		if f == undefined do return undefined
		local raw = ""
		while not eof f do raw += (readLine f) + "\n"
		close f
		raw
	),

	-- ── Layer helpers ────────────────────────────────────────────────────
	-- Get existing layer by name or create a new one.
	fn getOrCreateLayer layerName = (
		local lyr = LayerManager.getLayerFromName layerName
		if lyr == undefined do lyr = LayerManager.NewLayerFromName layerName
		lyr
	),

	-- ── Main import ─────────────────────────────────────────────────────
	fn ImportFromFile jsonPath = (
		-- Go to frame 0 before touching any transforms.
		sliderTime = 0f

		-- ── Read JSON ──────────────────────────────────────────────────
		local raw = readFileText jsonPath
		if raw == undefined do (messageBox ("Cannot open:\n"+jsonPath) title:"Error"; return false)
		local pr = parseValue raw 1
		local jsonRoot = pr[1]
		if classOf jsonRoot != Dictionary do (
		messageBox "JSON root must be an object." title:"Error"
		return false
		)

		local U = 100.0
		local sorted = topoSort (jsonRoot["objects"])

		-- Pre-compute world rotation matrix for each object
		local worldMats = Dictionary #string
		for objName in sorted do (
			local jo = (jsonRoot["objects"])[objName]
			if jo == undefined do continue
			local re = jo["rotation_euler"]
			local md = if dictHasKey jo "rotation_mode" then jo["rotation_mode"] else "XYZ"
			worldMats[objName] = buildWorldRot (r2d re[1]) (r2d re[2]) (r2d re[3]) md
		)
		fn getParentW wm jo = (
			local pn = jo["parent"]
			if pn == undefined or pn == "" do return (matrix3 1)
			local pw = wm[pn]; if pw == undefined do return (matrix3 1); pw
		)

		-- ── Pass 1a: rotation ORDER ───────────────────────────────────
		for objName in sorted do (
			local node = getNodeByName objName exact:true
			if node == undefined do continue
			local jo = (jsonRoot["objects"])[objName]; if jo == undefined do continue
			local modeStr = if dictHasKey jo "rotation_mode" then jo["rotation_mode"] else "XYZ"
			node.rotation.controller.axisOrder = blenderOrderToMax modeStr
		)

		-- ── Pass 1b: rotation VALUES (all unparented -> local == world) ──
		for objName in sorted do (
			local node = getNodeByName objName exact:true
			if node == undefined do continue
			local jo = (jsonRoot["objects"])[objName]; if jo == undefined do continue
			local modeStr = if dictHasKey jo "rotation_mode" then jo["rotation_mode"] else "XYZ"
			local W  = worldMats[objName]
			local le = decomposeEuler W modeStr
			local rc = node.rotation.controller
			rc.X_Rotation.controller.value = le[1]
			rc.Y_Rotation.controller.value = le[2]
			rc.Z_Rotation.controller.value = le[3]
		)

		-- ── Pass 1c: scale ────────────────────────────────────────────
		for objName in sorted do (
			local node = getNodeByName objName exact:true
			if node == undefined do continue
			local jo = (jsonRoot["objects"])[objName]; if jo == undefined do continue
			local js = jo["scale"]
			node.scale = [js[1], js[2], js[3]]
		)

		-- ── Pass 1d: parent objects ───────────────────────────────────
		for objName in sorted do (
			local node = getNodeByName objName exact:true
			if node == undefined do continue
			local jo = (jsonRoot["objects"])[objName]; if jo == undefined do continue
			local pn = jo["parent"]
			if pn != undefined and pn != "" do (
			local pNode = getNodeByName pn exact:true
			if pNode != undefined do node.parent = pNode
			)
		)

		-- ── Pass 2: rotation & scale animation keys ────────────────────────
		for objName in sorted do (
			local node = getNodeByName objName exact:true
			if node == undefined do continue
			local jo = (jsonRoot["objects"])[objName]; if jo == undefined do continue
			if not (dictHasKey jo "animation") do continue
			local anim = jo["animation"]

			local modeStr = if dictHasKey jo "rotation_mode" then jo["rotation_mode"] else "XYZ"
			local iPW = inverse (getParentW worldMats jo)

			-- Rotation keys
			if dictHasKey anim "rotation_euler" do (
				local ra = anim["rotation_euler"]
				local kX = ra["X"]; local kY = ra["Y"]; local kZ = ra["Z"]
				if kX.count > 0 or kY.count > 0 or kZ.count > 0 do (
					local frames = #()
					collectFrames kX frames; collectFrames kY frames; collectFrames kZ frames
					local xM = buildMap kX; local yM = buildMap kY; local zM = buildMap kZ
					local jre = jo["rotation_euler"]
					local rc = node.rotation.controller
					for fr in frames do (
						local rx = r2d (mapGet xM fr jre[1])
						local ry = r2d (mapGet yM fr jre[2])
						local rz = r2d (mapGet zM fr jre[3])
						local W  = buildWorldRot rx ry rz modeStr
						local L  = W * iPW
						local le = decomposeEuler L modeStr
						local kiX = addNewKey rc.X_Rotation.controller (fr as time)
						kiX.value = le[1]
						local kiY = addNewKey rc.Y_Rotation.controller (fr as time)
						kiY.value = le[2]
						local kiZ = addNewKey rc.Z_Rotation.controller (fr as time)
						kiZ.value = le[3]
					)
				)
			)

			-- Scale keys
			if dictHasKey anim "scale" do (
				local sa = anim["scale"]
				local kX = sa["X"]; local kY = sa["Y"]; local kZ = sa["Z"]
				if kX.count > 0 or kY.count > 0 or kZ.count > 0 do (
					local frames = #()
					collectFrames kX frames; collectFrames kY frames; collectFrames kZ frames
					local xM = buildMap kX; local yM = buildMap kY; local zM = buildMap kZ
					local js = jo["scale"]
					for fr in frames do (
						local sx = (mapGet xM fr js[1])
						local sy = (mapGet yM fr js[2])
						local sz = (mapGet zM fr js[3])
						local ki = addNewKey node.scale.controller (fr as time)
						ki.value = [sx, sy, sz]
					)
				)
			)
		)

		-- ── Pass 3: location animation keys ─────────────────────────────────
		-- Separate pass AFTER all rotations are fully keyed.
		for objName in sorted do (
			local node = getNodeByName objName exact:true
			if node == undefined do continue
			local jo = (jsonRoot["objects"])[objName]; if jo == undefined do continue
			if not (dictHasKey jo "animation") do continue
			local anim = jo["animation"]
			if not (dictHasKey anim "location") do continue

			local la = anim["location"]
			local kX = la["X"]; local kY = la["Y"]; local kZ = la["Z"]
			if kX.count == 0 and kY.count == 0 and kZ.count == 0 do continue

			local frames = #()
			collectFrames kX frames; collectFrames kY frames; collectFrames kZ frames
			local xM = buildMap kX; local yM = buildMap kY; local zM = buildMap kZ
			local jl = jo["location"]

			local savedWorldPos = copy node.pos
			node.pos.controller = Bezier_Position()
			node.transform.pos = savedWorldPos

			local parentTMInv = if node.parent != undefined \
				then inverse(node.parent.transform) \
				else undefined

			for fr in frames do (
				local wx = (mapGet xM fr jl[1]) * U
				local wy = (mapGet yM fr jl[2]) * U
				local wz = (mapGet zM fr jl[3]) * U
				local wPos = [wx, wy, wz]
				local lPos = if parentTMInv != undefined then (wPos * parentTMInv) else wPos
				local ki = addNewKey node.pos.controller (fr as time)
				ki.value = lPos
			)
		)

				-- ── Pass 4: layers (from Blender collections) ─────────────────
		-- JSON structure (from add-on v0.0.4):
		--   "collections": {
		--     "layers":  { "ChildCol": "ParentCol", "RootCol": "" },
		--     "objects": { "ObjectName": "CollectionName" }
		--   }
		if dictHasKey jsonRoot "collections" do (
			local cols = jsonRoot["collections"]

			-- 4a: create all layers
			local layerDict = Dictionary #string
			if dictHasKey cols "layers" do (
			local lyrs = cols["layers"]
			for layerName in lyrs.Keys do (
				local lyr = getOrCreateLayer layerName
				layerDict[layerName] = lyr
			)

			-- 4b: parent layers to each other
			for layerName in lyrs.Keys do (
				local parentLayerName = lyrs[layerName]
				if parentLayerName != undefined and parentLayerName != "" do (
				local childLyr  = layerDict[layerName]
				local parentLyr = layerDict[parentLayerName]
				if childLyr != undefined and parentLyr != undefined do
					childLyr.setParent parentLyr
				)
			)
			)

			-- 4c: assign objects to layers
			if dictHasKey cols "objects" do (
			local objCols = cols["objects"]
			for objName in objCols.Keys do (
				local node = getNodeByName objName exact:true
				if node == undefined do continue
				local layerName = objCols[objName]
				local lyr = layerDict[layerName]
				if lyr == undefined do lyr = getOrCreateLayer layerName
				lyr.addNode node
			)
			)
		)

		messageBox "Import complete!" title:"Blender JSON Importer"
		true
	)
)

global gBJI = BlenderJSON_Importer_Struct()

rollout BlenderImportRollout "Blender JSON Importer" width:340 height:110 (
	label   lblFile   "No file selected." align:#left across:1
	button  btnBrowse "Browse..."         width:90 align:#right
	button  btnImport "Import"            width:120 align:#center enabled:false
	label   lblStatus ""                  align:#left
	local selectedFile = ""
	on btnBrowse pressed do (
		local f = getOpenFileName caption:"Select Blender JSON export" \
			types:"JSON Files (*.json)|*.json|All Files (*.*)|*.*|"
		if f != undefined and f != "" do (
			selectedFile = f
			lblFile.text = filenameFromPath f
			btnImport.enabled = true
			lblStatus.text = ""
		)
	)
	on btnImport pressed do (
		lblStatus.text = "Importing..."
		if gBJI.ImportFromFile selectedFile then lblStatus.text = "Done."
		else lblStatus.text = "Failed - check Listener."
	)
)
try (destroyDialog BlenderImportRollout) catch ()
createDialog BlenderImportRollout style:#(#style_titlebar, #style_sysmenu)
