extends RefCounted
## BetterServer's eight map presets. IDs match assets/maps/catalog.json.

const NAMES := [
	"DEFAULT",
	"CLASSIC",
	"EASY",
	"MEDIUM",
	"HARD",
	"MADNESS",
	"NIGHTMARE UNIVERSE",
	"SPIRITS OF HELL"
]
const MAPS := [
	[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19],
	[2, 4, 6, 7, 8, 12, 14],
	[0, 2, 16, 17, 19],
	[1, 3, 4, 7, 11, 12, 14],
	[5, 6, 9, 15, 18],
	[8, 10, 13],
	[1, 3, 9, 10],
	[0, 5, 11, 13],
]

# Presets shipped while only part of the map pool had been ported.
const LEGACY_MAPS := [
	[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19],
	[2],
	[0, 2],
	[3],
	[],
	[],
	[3],
	[0]
]
const LEGACY_INITIAL := [[2, 3], [2], [2], [3], [], [], [3], []]
const LEGACY_DEFAULTS := [
	[2, 3],
	[0, 2, 3],
	[0, 2, 3, 6, 8, 14, 15],
	[0, 2, 3, 6, 7, 8, 9, 12, 14, 15],
	[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 14, 15],
	[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 13, 14, 15, 16, 17]
]


static func same_pool(actual: Array, expected: Array) -> bool:
	if actual.size() != expected.size():
		return false
	for id in expected:
		if not actual.has(id):
			return false
	return true


static func upgrade(config: Dictionary) -> void:
	if not config.get("maps") is Array:
		config.maps = MAPS[0].duplicate()
		config.map_set = 0
		return
	var value = config.get("map_set", 0)
	if typeof(value) not in [TYPE_INT, TYPE_FLOAT] or value != int(value):
		config.map_set = -1
		return
	var index := int(value)
	if index < 0 or index >= MAPS.size():
		config.map_set = -1
		return
	var actual: Array = config.maps
	var matches := (
		same_pool(actual, MAPS[index])
		or same_pool(actual, LEGACY_MAPS[index])
		or same_pool(actual, LEGACY_INITIAL[index])
	)
	if index == 0:
		for previous in LEGACY_DEFAULTS:
			matches = matches or same_pool(actual, previous)
	if matches:
		config.maps = MAPS[index].duplicate()
		config.map_set = index
	else:
		# A manually edited pool must not be replaced by the named preset.
		config.map_set = -1
