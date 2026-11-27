extends SimulationFloor
## Keep moving masks in the grid across their full travel envelope.
var origin := Vector2.ZERO


func _ready():
	origin = position
	gm_static = false
	canStuck = gm_name == "obj_act9_wall"
	super._ready()


func cached_bbox() -> Rect2:
	return bbox_rect()


func grid_bbox() -> Rect2:
	return bbox_rect().grow(2048)


func set_spike_frame(frame: int):
	image_index = frame
	collision_active = frame > 0 and frame < 5
	sprite_name = "moving_spike_mask"
	GM.sprites[sprite_name] = {
		"w": 32, "h": 32, "xorigin": 0, "yorigin": 0, "bboxMode": 1, "count": 1
	}
	_mcached = false
