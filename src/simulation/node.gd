class_name SimulationNode
extends Node2D
## Non-rendering actor/object adapter. Each actor has its own input and identity.
var GM: SimulationSprites
var Globals: SimulationGlobals
var Net: SimulationNetwork
var GameAudio := SimulationAudio.new()
var Unlockables := SimulationUnlockables.new()
var sprite_name := ""
var image_index := 0.0
var image_speed := 1.0
var image_blend := Color.WHITE
var image_alpha := 1.0
var image_xscale := 1.0
var image_yscale := 1.0
var sprite_rotation := 0.0
var gm_name := ""
var gm_static := true
var gm_visible := false
var depth := 0.0
var pixel_snap := false
var _anim_accum := 0.0
var properties: Dictionary = {}
var motion := Vector2.ZERO
var pcharacter := -1
var isInactive := false
var pstate: int:
	get:
		return int(get("state"))


func _ready():
	set_physics_process(false)
	if not gm_name.is_empty():
		add_to_group(gm_name)


func kd(key: int) -> bool:
	return Net.held & (1 << key) != 0


func kp(key: int) -> bool:
	return Net.pressed & (1 << key) != 0


func kr(key: int) -> bool:
	return Net.released & (1 << key) != 0


func draw_self():
	pass


func _gm_step():
	pass


func _gm_animation_end():
	pass


func _physics_process(_delta: float):
	pass


func advance_animation():
	if sprite_name.is_empty():
		return
	var m := GM.sprite_meta(sprite_name)
	var speed := (
		image_speed * float(m.playbackSpeed) / (60.0 if int(m.playbackSpeedType) == 0 else 1.0)
	)
	var count := GM.sprite_count(sprite_name)
	if count <= 0 or speed == 0 or int(m.playbackMode) == 0:
		return
	_anim_accum += speed
	if _anim_accum >= 1 or _anim_accum <= -1:
		image_index += floorf(_anim_accum)
		_anim_accum = fmod(_anim_accum, 1)
		if int(m.playbackMode) == 1:
			var finished := image_index >= count or image_index < 0
			image_index = wrapf(image_index, 0, count)
			if finished:
				_gm_animation_end()
		else:
			image_index = clampf(image_index, 0, count - 1)


static func all_of(group: String) -> Array:
	return (Engine.get_main_loop() as SceneTree).get_nodes_in_group(group)


func bbox_rect() -> Rect2:
	if sprite_name == "":
		return Rect2(position.x, position.y, 0, 0)
	var m := GM.sprite_meta(sprite_name)
	var bm: int = int(m.get("bboxMode", 1))
	var l: float
	var t: float
	var r: float
	var b: float
	if bm == 1:
		l = 0
		t = 0
		r = float(m["w"]) - 1
		b = float(m["h"]) - 1
	else:
		l = float(m["bbox"][0])
		t = float(m["bbox"][1])
		r = float(m["bbox"][2])
		b = float(m["bbox"][3])
	# GM: bbox in room space = x - xoffset + bbox_left (origin-aware)
	var ox := float(m["xorigin"]) * image_xscale
	var oy := float(m["yorigin"]) * image_yscale
	var x0 := position.x - ox + l * image_xscale
	var y0 := position.y - oy + t * image_yscale
	var x1 := position.x - ox + (r + 1) * image_xscale
	var y1 := position.y - oy + (b + 1) * image_yscale
	if sprite_rotation == 0.0:
		return Rect2(minf(x0, x1), minf(y0, y1), absf(x1 - x0), absf(y1 - y0))
	# rotated instance: GM collision uses the AABB of the mask rotated around
	# the origin — rotate the four corners and take the bounding box
	var rad := deg_to_rad(sprite_rotation)
	var cs := cos(rad)
	var sn := sin(rad)
	var pmin := Vector2(INF, INF)
	var pmax := Vector2(-INF, -INF)
	for cx: float in [x0, x1]:
		for cy: float in [y0, y1]:
			# corner relative to the origin point (position), rotated
			var dx: float = cx - position.x
			var dy: float = cy - position.y
			var px: float = position.x + dx * cs - dy * sn
			var py: float = position.y + dx * sn + dy * cs
			pmin.x = minf(pmin.x, px)
			pmin.y = minf(pmin.y, py)
			pmax.x = maxf(pmax.x, px)
			pmax.y = maxf(pmax.y, py)
	return Rect2(pmin, pmax - pmin)


## position_meeting(mouse_x, mouse_y, self) port — point vs bbox
func position_meeting(px: float, py: float) -> bool:
	return bbox_rect().has_point(Vector2(px, py))


## GM point-vs-mask for ROTATED instances: the mask rectangle rotates with the
## sprite (OBB), not its AABB — this is what makes rotated solid blocks
## walkable ramps. Unrotated instances = plain bbox test.
func point_in_mask(px: float, py: float) -> bool:
	if sprite_name == "":
		return false
	var m := GM.sprite_meta(sprite_name)
	var bm: int = int(m.get("bboxMode", 1))
	var l: float
	var t: float
	var r: float
	var b: float
	if bm == 1:
		l = 0
		t = 0
		r = float(m["w"]) - 1
		b = float(m["h"]) - 1
	else:
		l = float(m["bbox"][0])
		t = float(m["bbox"][1])
		r = float(m["bbox"][2])
		b = float(m["bbox"][3])
	var lx: float = px - position.x
	var ly: float = py - position.y
	if sprite_rotation != 0.0:
		var rad := deg_to_rad(sprite_rotation)
		var cs := cos(rad)
		var sn := sin(rad)
		var rx := lx * cs + ly * sn
		var ry := -lx * sn + ly * cs
		lx = rx
		ly = ry
	var ox := float(m["xorigin"])
	var oy := float(m["yorigin"])
	lx = lx / image_xscale + ox
	ly = ly / image_yscale + oy
	return lx >= l and lx < r + 1.0 and ly >= t and ly < b + 1.0
