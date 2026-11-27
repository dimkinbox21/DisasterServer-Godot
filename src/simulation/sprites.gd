class_name SimulationSprites
extends RefCounted
const C_WHITE := Color.WHITE
const C_GRAY := Color.GRAY
const C_DKGRAY := Color("404040")
var sprites: Dictionary = JSON.parse_string(
	FileAccess.get_file_as_string("res://src/simulation/generated/sprites.json")
)


func sprite_meta(name: String) -> Dictionary:
	return sprites.get(
		name,
		{
			"w": 32,
			"h": 40,
			"xorigin": 16,
			"yorigin": 20,
			"bboxMode": 1,
			"count": 1,
			"playbackMode": 1,
			"playbackSpeed": 60,
			"playbackSpeedType": 0
		}
	)


func sprite_count(name: String) -> int:
	return int(sprite_meta(name).count)
