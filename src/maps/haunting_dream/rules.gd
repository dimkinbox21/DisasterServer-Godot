extends "res://src/maps/shared/rules.gd"
## Haunting Dream: authoritative map mechanics.
# Source objects + BetterServer DTTailsDoll/DTAss/DTBall/HDDoor state machines.
var age := 0
var door_open := false
var door_cd := 0
var doors: Dictionary = {}
var events: Array = []
var pending := false


func alive(p: Dictionary) -> bool:
	return host.character_rules.alive(p) and p.get("position_ready", false)


func reset():
	super.reset()
	age = 0
	door_open = false
	door_cd = 0
	doors.clear()

	events.clear()

	pending = true

	for i in objects("obj_hd_door") + objects("obj_hd_door2"):
		doors[i.name] = {"x": float(i.position[0]), "y": float(i.position[1])}


func event(kind: String, at := Vector2.ZERO, owner := -1):
	events.append({"kind": kind, "x": at.x, "y": at.y, "owner": owner})
	pending = true


func door_bounds(i: Dictionary) -> Rect2:
	var box := rect(i)
	if doors.has(i.name):
		box.position += Vector2(doors[i.name].x - i.position[0], doors[i.name].y - i.position[1])
	return box


func floor_at(at: Vector2) -> bool:
	for i in objects("obj_hd_door") + objects("obj_hd_door2"):
		if door_bounds(i).has_point(at):
			return true
	return false


func snapshot(peer: ENetPacketPeer = null) -> void:
	var data = {
		"map": host.chosen_map,
		"age": age,
		"open": door_open,
		"cooldown": door_cd,
		"doors": doors,
		"events": events if peer == null else []
	}
	var packet = host._pkt(NetPackets.SERVER_TOWER_STATE)
	packet.put_data(JSON.stringify(data).to_utf8_buffer())
	if peer != null:
		host._send(peer, packet)
	else:
		host._broadcast(packet)


func handle(p, type: int, b: StreamPeerBuffer) -> bool:
	if (
		type
		not in [
			NetPackets.CLIENT_HDDOOR_TOGGLE,
			NetPackets.CLIENT_DTASS_ACTIVATE,
			NetPackets.CLIENT_TOWER_INTERACT
		]
	):
		return false
	if p == null or host.server_state != host.S.GAMESTART or host.round_ending:
		return true
	if not alive(p):
		return true
	if type == NetPackets.CLIENT_HDDOOR_TOGGLE:
		if door_cd > 0:
			return true
		for i in objects("obj_hd_crystal"):
			if body(p).intersects(rect(i).grow(2)):
				door_open = not door_open
				door_cd = 600
				event("door")
				break
	# Stalactite landing is server simulated; never trust a remote destroy request.
	return true


func apply_damage(p: Dictionary, amount: int, mode: int):
	var hp: int = p.hp
	var rings: int = p.rings
	host._apply_survivor_damage(p, amount)
	host.active_map.owner_stats(p, mode)
	if p.hp >= hp:
		return
	var sound = host._pkt(NetPackets.CLIENT_SOUND_EMIT, true)
	sound.put_u16(p.nid)
	sound.put_u8(2 if p.hp <= 0 else 6 if rings > 0 else 9)
	sound.put_u8(0)
	host._broadcast(sound, p.nid)


func tick():
	if host.round_ending:
		return
	age += 1
	tick_doors()
	if pending or age % 6 == 0:
		snapshot()
		events.clear()
		pending = false


func tick_doors():
	if door_cd > 0:
		door_cd -= 1
		if door_cd == 0:
			event("crystal_ready")
	for i in objects("obj_hd_door") + objects("obj_hd_door2"):
		var door: Dictionary = doors[i.name]
		var horizontal: bool = i.object == "obj_hd_door2"
		var origin := Vector2(i.position[0], i.position[1])
		var box := rect(i)
		var target := (
			origin - (Vector2(box.size.x, 0) if horizontal else Vector2(0, box.size.y))
			if door_open
			else origin
		)
		var previous := Vector2(door.x, door.y)
		door.x = move_toward(door.x, target.x, 1)
		door.y = move_toward(door.y, target.y, 1)
		for p in host.players.values():
			if (
				not p.get("position_ready", false)
				or not p.get("is_dead", false)
				or not body(p).intersects(door_bounds(i))
			):
				continue
			host.active_map.teleport(p, Vector2(door_bounds(i).end.x + 9, p.last_y))
		if door_open or previous == Vector2(door.x, door.y):
			continue
		var current := door_bounds(i)
		var edge := (
			Rect2(current.end.x + 1, current.position.y + 2, 1, maxf(1, current.size.y - 4))
			if horizontal
			else Rect2(current.position.x, current.end.y + 1, current.size.x, 1)
		)
		for p in host.players.values():
			if not alive(p) or not body(p).intersects(edge):
				continue
			if host.character_rules.hunter(p):
				var best := Vector2(p.last_x, p.last_y)
				var distance := INF
				for point in objects("obj_deathtp_point"):
					var at := Vector2(point.position[0], point.position[1])
					var d := at.distance_squared_to(Vector2(p.last_x, p.last_y))
					if d < distance:
						distance = d
						best = at
				host.active_map.teleport(p, best)
			else:
				p.hurttime = 0
				p.sally_shield_end = 0
				apply_damage(p, p.hp, 1)


func sync_simulation(world):
	for name in world.dynamic:
		var door: Dictionary = doors.get(name, {})
		if not door.is_empty():
			world.dynamic[name].position = Vector2(door.x, door.y)


func simulation_interactions(world, p: Dictionary, actor):
	super.simulation_interactions(world, p, actor)
	simulation_requests(world, p, {"obj_hd_crystal": NetPackets.CLIENT_HDDOOR_TOGGLE})
