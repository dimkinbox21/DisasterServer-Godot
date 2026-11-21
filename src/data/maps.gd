extends RefCounted
## Stable map IDs and paths shared by game flow, map loading and server UI.
static var _maps: Dictionary = {}


static func entry(id: int) -> Dictionary:
	if _maps.is_empty():
		_maps = JSON.parse_string(FileAccess.get_file_as_string("res://assets/maps/catalog.json"))
	return _maps.get(str(id), {})


static func rules_path(id: int, server: bool = false) -> String:
	var data = entry(id)
	if data.is_empty():
		return ""
	return ("res://src/maps/" if server else "res://src/game/maps/") + data.folder + "/rules.gd"


static func hud_path(id: int) -> String:
	return "res://src/game/maps/" + entry(id).folder + "/hud.gd"


static func duration_seconds(id: int, survivors: int) -> int:
	var data = entry(id)
	return (
		int(data.get("base_seconds", 300))
		+ int(data.get("seconds_per_survivor", 0)) * maxi(0, survivors)
	)


static func playable_ids() -> Array:
	var ids = []
	for id in range(21):
		if entry(id).get("playable", false):
			ids.append(id)
	return ids


static func names() -> Array:
	var result = []
	for id in range(21):
		result.append(entry(id).get("name", ""))
	return result


static var _worlds: Dictionary = {}


static func world_data(id: int) -> Dictionary:
	if not _worlds.has(id):
		var path = "res://assets/maps/" + entry(id).folder + "/world.json"
		_worlds[id] = JSON.parse_string(FileAccess.get_file_as_string(path))
	return _worlds[id]


static func table(key: String) -> Dictionary:
	var result = {}
	for id in range(21):
		result[str(id)] = world_data(id).get(key)
	return result
