extends RefCounted
## Canonical health snapshots are independent from movement and client reports.
var host: Node
var revision := 0
var sent := {}
var impacts := {}


func _init(server: Node):
	host = server


func reset():
	sent.clear()
	impacts.clear()


func impact(p: Dictionary, attacker: int, blood: int):
	var push := -float(p.get("facing", 1)) * 4.0
	if host.players.has(attacker):
		push = signf(float(p.last_x) - float(host.players[attacker].last_x)) * 3.0
	impacts[p.nid] = [
		2 if blood == 4 else 3 if attacker >= 0 else 1, push, -3.0 if attacker >= 0 else -6.0
	]
	p.motion_impact = impacts[p.nid].duplicate()


func packet(p: Dictionary, feedback := false) -> StreamPeerBuffer:
	revision += 1
	p.health_revision = revision
	var b: StreamPeerBuffer = host._pkt(NetPackets.SERVER_PLAYER_HEALTH)
	b.put_u32(host.round_id)
	b.put_u32(revision)
	b.put_u16(p.nid)
	b.put_u8(clampi(p.hp, 0, 5))
	b.put_u8(clampi(p.revival, 0, 2))
	b.put_u16(clampi(p.rings, 0, 65535))
	b.put_u8(int(p.is_dead))
	b.put_u16(clampi(p.get("hurttime", 0), 0, 65535))
	b.put_u16(clampi(p.get("dead_timer", 0), 0, 65535))
	b.put_u8(int(p.get("death_near", 0) == 1))
	b.put_u16(clampi(p.get("red_ring", 0), 0, 65535))
	var hit: Array = impacts.get(p.nid, [0, 0.0, 0.0]) if feedback else [0, 0.0, 0.0]
	b.put_u8(hit[0])
	b.put_float(hit[1])
	b.put_float(hit[2])
	return b


func snapshot(peer: ENetPacketPeer):
	for p in host.players.values():
		if p.get("in_round", false):
			host._send(peer, packet(p))


func sync(force := false):
	if host.server_state != host.S.GAMESTART:
		return
	for p in host.players.values():
		if not p.get("in_round", false):
			continue
		var signature := [
			p.hp,
			p.revival,
			p.rings,
			p.is_dead,
			p.get("dead_final", false),
			p.get("red_ring", 0) > 0,
			p.get("hurttime", 0) > 0,
			p.get("stunned_ticks", 0) > 0,
			p.get("death_near", 0)
		]
		if force or sent.get(p.nid) != signature or impacts.has(p.nid):
			host._broadcast(packet(p, true))
			sent[p.nid] = signature
			impacts.erase(p.nid)


func tick():
	if host.round_ending:
		return
	var data: Dictionary = preload("res://src/data/maps.gd").world_data(host.chosen_map).get(
		"hazards", {}
	)
	for p in host.players.values():
		check_player(p, data)


func check_player(p: Dictionary, data: Dictionary = {}):
	if host.round_ending:
		return
	if data.is_empty():
		data = preload("res://src/data/maps.gd").world_data(host.chosen_map).get("hazards", {})
	if (
		not p.get("in_round", false)
		or not p.get("position_ready", false)
		or p.get("escaped", false)
	):
		return
	var at := Vector2(p.last_x, p.last_y)
	var target := Vector2.INF
	var stun := false
	if at.y - 30 >= float(data.get("height", INF)):
		target = closest(data.get("items", []), "obj_deathtp_point", at)
		if target != Vector2.INF:
			target.y = landing_y(target, float(data.height))
			stun = true
	for item in data.get("items", []):
		if item.type == "obj_abyss" and rect(item).has_point(at):
			target = closest(data.items, "obj_abyss_target", at)
			stun = item.stun
			break
	if target != Vector2.INF:
		hazard_damage(p)
		host.active_map.teleport(p, target)
		if stun and host.character_rules.hunter(p):
			host.character_rules.status(p, 1, 30)
		return
	if p.get("is_dead", false) or p.get("hurttime", 0) > 0:
		return
	var feet := Rect2(at + Vector2(-6, 18), Vector2(12, 3))
	var lower := Rect2(at + Vector2(-12, 0), Vector2(24, 20))
	for item in data.get("items", []):
		var box := rect(item)
		if item.type == "obj_damage" and lower.intersects(box):
			hazard_damage(p)
			break
		if item.type == "obj_spike" and feet.intersects(box):
			hazard_damage(p)
			break
		if item.type == "obj_movingspike" and moving_spike_active() and feet.intersects(box):
			hazard_damage(p)
			break


func rect(item: Dictionary) -> Rect2:
	return Rect2(item.bounds[0], item.bounds[1], item.bounds[2], item.bounds[3])


func hazard_damage(p: Dictionary):
	if host.character_rules.hunter(p):
		if p.get("invisible", false):
			return
		if p.get("hurttime", 0) > 0 or host.character_rules.break_sally_shield(p):
			return
		p.hurttime = 60 if host.game_ticks < 3600 else 180
		impact(p, -1, 2)
	else:
		host._apply_survivor_damage(p, 1)


func closest(items: Array, type: String, at: Vector2) -> Vector2:
	var target := Vector2.INF
	var distance := INF
	for item in items:
		if item.type != type:
			continue
		var point := Vector2(item.x, item.y)
		if at.distance_squared_to(point) < distance:
			distance = at.distance_squared_to(point)
			target = point
	return target


func landing_y(at: Vector2, height: float) -> float:
	var result := INF
	for g in host.character_rules.geometry.get(str(host.chosen_map), []):
		if g.group != "floor" or g.bounds.end.y < at.y - 16:
			continue
		for x in [at.x - 7, at.x + 7]:
			if x < g.bounds.position.x or x >= g.bounds.end.x:
				continue
			for y in range(
				ceili(maxf(g.bounds.position.y, at.y - 16)),
				ceili(minf(g.bounds.end.y, minf(height + 64, result)))
			):
				if host.character_rules.mask_contains(g, Vector2(x, y)):
					result = minf(result, y)
					break
	return at.y - 18 if result == INF else result - 18


func moving_spike_active() -> bool:
	return host.active_map.moving_spike_frame() in [1, 2, 3, 4]
