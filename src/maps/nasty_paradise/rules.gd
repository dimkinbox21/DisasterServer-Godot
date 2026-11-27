extends "res://src/maps/shared/rules.gd"
## Nasty Paradise: authoritative map mechanics.
var ice: Dictionary = {}
var balls: Dictionary = {}


func reset():
	super.reset()
	ice.clear()
	balls.clear()

	for p in host.players.values():
		p.boosted = false
		p.map_ray_until = 0
	for i in objects(9, "obj_nap_snowball_waypoint"):
		var id := int(i.properties.get("nid", 0))
		if not balls.has(id):
			balls[id] = {
				"timer": 0,
				"active": false,
				"waypoint": 0,
				"progress": 0.0,
				"frame": 0.0,
				"growth": 0.0
			}


func emit(type: int, bytes: Array, peer: ENetPacketPeer = null):
	var b = host._pkt(type)
	for v in bytes:
		b.put_u8(v)
	if peer != null:
		host._send(peer, b)
	else:
		host._broadcast(b)


func snapshot(peer: ENetPacketPeer = null) -> void:
	for id in ice:
		emit(NetPackets.SERVER_NAPICE_STATE, [0, id], peer)
	for id in balls:
		if balls[id].active:
			emit(NetPackets.SERVER_NAPBALL_STATE, [0, id, 255 if id in [1, 4] else 1], peer)
			ball_packet(id, peer)


func handle(p, type: int, b: StreamPeerBuffer) -> bool:
	if type not in [NetPackets.CLIENT_KAFMONITOR_ACTIVATE, NetPackets.CLIENT_NAPICE_ACTIVATE]:
		return false
	if (
		host.server_state != host.S.GAMESTART
		or p == null
		or host.round_ending
		or not host.character_rules.alive(p)
		or not p.get("position_ready", false)
		or b.get_available_bytes() < 1
	):
		return true
	var id := b.get_u8()
	if type == NetPackets.CLIENT_NAPICE_ACTIVATE:
		for i in objects(9, "obj_nap_iceblock"):
			if int(i.properties.get("nid", 0)) != id or ice.has(id):
				continue
			var top_contact: bool = (
				p.last_y + 19 >= rect(i).position.y - 4 and p.last_y + 19 <= rect(i).position.y + 12
			)
			var impact: bool = (
				top_contact
				or p.get("attacking", false)
				or (p.char == 2 and p.get("move_state", 0) == 16)
			)
			if (impact and body(p).grow(8).intersects(rect(i))) or projectile_near(p, rect(i)):
				ice[id] = 900
				emit(NetPackets.SERVER_NAPICE_STATE, [0, id])
	return true


func projectile_near(p: Dictionary, area: Rect2) -> bool:
	if p.get("map_ray_until", 0) > host._game_frame:
		for elapsed in range(0, host._game_frame - int(p.map_ray_start) + 1):
			var at: Vector2 = p.map_ray_origin + Vector2(p.map_ray_dir * 14 * elapsed, 0)
			if area.grow(16).has_point(at):
				return true
			if host.character_rules.floor_at(at):
				return false
	return false


func ball_path(id: int) -> Array:
	var points := objects(9, "obj_nap_snowball_waypoint").filter(
		func(i): return int(i.properties.get("nid", 0)) == id
	)
	points.sort_custom(
		func(a, b): return int(a.properties.get("wid", 0)) < int(b.properties.get("wid", 0))
	)
	return points


func ball_packet(id: int, peer: ENetPacketPeer = null):
	var a: Dictionary = balls[id]
	var b = host._pkt(NetPackets.SERVER_NAPBALL_STATE)
	b.put_u8(1)
	b.put_u8(id)
	b.put_u8(a.waypoint)
	b.put_u8(int(a.frame))
	b.put_double(a.progress)
	if peer != null:
		host._send(peer, b)
	else:
		host._broadcast(b)


func hazard(p: Dictionary):
	if p.hurttime > 0:
		return
	if host.character_rules.hunter(p):
		p.hurttime = 180
	else:
		host._apply_survivor_damage(p, 1)
	host.active_map.owner_stats(p, 2)


func tick():
	if host.round_ending:
		return
	for id in ice.keys():
		ice[id] -= 1
		if ice[id] <= 0:
			ice.erase(id)
			emit(NetPackets.SERVER_NAPICE_STATE, [1, id])
	for id in balls:
		var a: Dictionary = balls[id]
		a.timer += 1
		if a.timer >= 1200:
			a.active = true
			a.timer = 0
			a.waypoint = 0
			a.progress = 0.0
			a.frame = 0.0
			a.growth = 0.0
			emit(NetPackets.SERVER_NAPBALL_STATE, [0, id, 255 if id in [1, 4] else 1])
		if not a.active:
			continue
		var path := ball_path(id)
		if path.size() < 2:
			continue
		a.growth += 0.016
		var rates: Array = rooms["9"].ball_rates.get(str(id), {}).get(str(a.waypoint), [0.05, 0.35])
		a.progress += rates[0] if a.growth > 1 else 0.05 * a.growth
		a.frame += (rates[1] if a.growth > 1 else a.growth * 0.45)
		if a.frame >= 32:
			a.frame = 16.0
		if a.progress >= 1:
			a.progress = 0.0
			a.waypoint += 1
		if a.waypoint >= path.size() - 1:
			a.active = false
			emit(NetPackets.SERVER_NAPBALL_STATE, [2, id])
			continue
		var first: Dictionary = path[a.waypoint]
		var next: Dictionary = path[a.waypoint + 1]
		var at := (
			Vector2(first.position[0], first.position[1]).lerp(
				Vector2(next.position[0], next.position[1]), a.progress
			)
			+ Vector2(32, 64)
		)
		ball_packet(id)
		if a.frame >= 8:
			for p in host.players.values():
				if (
					host.character_rules.alive(p)
					and p.get("position_ready", false)
					and body(p).intersects(Rect2(at - Vector2(40, 82), Vector2(81, 82)))
				):
					hazard(p)


func sync_simulation(world):
	for n in world.dynamic.values():
		n.collision_active = not ice.has(int(n.properties.get("nid", 0)))


func simulation_interactions(world, p: Dictionary, actor):
	super.simulation_interactions(world, p, actor)
	simulation_requests(world, p, {"obj_nap_iceblock": NetPackets.CLIENT_NAPICE_ACTIVATE})
