extends RefCounted
## Shared server map API; each level owns its own state machine.
var host: Node
var rooms: Dictionary
var total_ticks := 18000


func _init(server: Node):
	host = server
	rooms = preload("res://src/data/maps.gd").table("mechanics")


func reset():
	total_ticks = maxi(1, host.game_ticks)


func snapshot(_peer: ENetPacketPeer = null) -> void:
	pass


func handle(_player, _type: int, _buffer: StreamPeerBuffer) -> bool:
	return false


func tick():
	pass


func drop(_player: Dictionary):
	pass


func release(_player: Dictionary):
	pass


func can_escape() -> bool:
	return true


func floor_at(_at: Vector2) -> bool:
	return false


func objects(type_or_id, object_type: String = "") -> Array:
	var id = host.chosen_map if object_type.is_empty() else int(type_or_id)
	var type = str(type_or_id) if object_type.is_empty() else object_type
	return rooms.get(str(id), {}).get("instances", []).filter(
		func(record): return record.object == type
	)


func alive(p: Dictionary) -> bool:
	return host.character_rules.alive(p) and p.get("position_ready", false)


func living(p: Dictionary) -> bool:
	return alive(p) and not host.character_rules.hunter(p)


func human(p: Dictionary) -> bool:
	return living(p)


func body(p: Dictionary) -> Rect2:
	return Rect2(Vector2(p.last_x, p.last_y) - Vector2(8, 18), Vector2(16, 37))


func rect(i: Dictionary) -> Rect2:
	return Rect2(i.bounds[0], i.bounds[1], i.bounds[2], i.bounds[3])


func projectile_near(p: Dictionary, area: Rect2) -> bool:
	if p.get("map_ray_until", 0) > host._game_frame:
		for elapsed in range(0, host._game_frame - int(p.map_ray_start) + 1):
			var at: Vector2 = p.map_ray_origin + Vector2(p.map_ray_dir * 14 * elapsed, 0)
			if area.grow(16).has_point(at):
				return true
			if host.character_rules.floor_at(at):
				return false
	return false


func owner_stats(p: Dictionary, mode := 0) -> void:
	var b: StreamPeerBuffer = host._pkt(NetPackets.SERVER_MAP_DAMAGE)
	b.put_u8(mode)
	b.put_8(p.hp)
	b.put_16(p.rings)
	b.put_u16(p.hurttime)
	b.put_u8(int(p.is_dead))
	host._send(p.peer, b)


func teleport(p: Dictionary, at: Vector2) -> void:
	host.motion.warp(p, at)
	var b: StreamPeerBuffer = host._pkt(NetPackets.SERVER_PLAYER_BACKTRACK)
	b.put_u16(p.last_x)
	b.put_u16(p.last_y)
	host._send(p.peer, b)


static func duration_seconds(map_id: int, survivors: int) -> int:
	return preload("res://src/data/maps.gd").duration_seconds(map_id, survivors)


func sync_simulation(_world):
	pass


func before_actor(_actor, _p: Dictionary):
	pass


func after_actor(_actor, _p: Dictionary):
	pass


func before_collision(_actor):
	pass


func simulation_state(_actor, _p: Dictionary):
	pass


func input_buttons(_p: Dictionary, held: int) -> int:
	return held


func moving_spike_frame() -> int:
	return -1


func simulation_interactions(world, p: Dictionary, actor):
	if host.exit_ready and actor.position.distance_to(host.exit_position) < 28:
		world.request(p, NetPackets.CLIENT_PLAYER_ESCAPED)


func simulation_requests(world, p: Dictionary, bindings: Dictionary):
	for type in bindings:
		for i in objects(type):
			if i.has("bounds") and body(p).grow(8).intersects(rect(i)):
				world.request(p, bindings[type], int(i.properties.get("nid", 0)))
