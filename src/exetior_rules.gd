extends RefCounted
## Server-owned Exetior melee/stomp windows, ground waves and black rings.
var host: Node
var rings: Dictionary = {}
var waves: Array = []
var next_ring := 1
var springs: Dictionary = {}
var survivor_hitboxes: Dictionary = {}


func _init(server: Node):
	host = server
	springs = preload("res://src/data/maps.gd").table("springs")
	if FileAccess.file_exists("res://assets/survivor_hitboxes.json"):
		survivor_hitboxes = JSON.parse_string(
			FileAccess.get_file_as_string("res://assets/survivor_hitboxes.json")
		)


func is_exetior(p: Dictionary) -> bool:
	return p.get("char", -1) == 0 and p.get("exechar", -1) == 2


func reset_player(p: Dictionary):
	for key in [
		"exetior_ready",
		"exetior_attack_end",
		"exetior_ring_ready",
		"exetior_stomp",
		"exetior_land_end"
	]:
		p[key] = 0


func reset():
	rings.clear()
	waves.clear()
	next_ring = 1


func valid(p: Dictionary, allow_zipline := false) -> bool:
	return (
		is_exetior(p)
		and host.server_state == host.S.GAMESTART
		and not host.round_ending
		and host.character_rules.valid_action(p, 0)
		and (allow_zipline or p.get("move_state", 0) != 19)
	)


func attack(p: Dictionary) -> bool:
	return valid(p) and p.get("exetior_attack_end", 0) > host._game_frame


func can_hit(p: Dictionary, target: Dictionary) -> bool:
	return (
		valid(p)
		and host.character_rules.pos(p).distance_to(host.character_rules.pos(target)) <= 64
		and (attack(p) or p.get("move_state", 0) in [3, 12])
	)


func reply(p: Dictionary, accepted: bool):
	var b: StreamPeerBuffer = host._pkt(NetPackets.SERVER_CHARACTER_STATUS)
	b.put_u8(8)
	b.put_u16(int(accepted))
	b.put_u16(maxi(0, p.get("exetior_ready", 0) - host._game_frame))
	b.put_u16(maxi(0, p.get("exetior_ring_ready", 0) - host._game_frame))
	host._send(p.peer, b)


func ring_packet(id: int, ring: Dictionary) -> StreamPeerBuffer:
	var b: StreamPeerBuffer = host._pkt(NetPackets.SERVER_ERECTOR_BRING_SPAWN)
	b.put_u16(id)
	b.put_16(int(ring.at.x))
	b.put_16(int(ring.at.y))
	b.put_u8(int(ring.get("purple", false)))
	return b


func wave_packet(wave: Dictionary) -> StreamPeerBuffer:
	var b: StreamPeerBuffer = host._pkt(NetPackets.SERVER_EXETIOR_WAVES)
	b.put_u16(wave.owner)
	b.put_16(int(wave.at.x))
	b.put_16(int(wave.at.y))
	b.put_u8(maxi(0, host._game_frame - wave.born))
	return b


func snapshot(peer: ENetPacketPeer):
	for id in rings:
		host._send(peer, ring_packet(id, rings[id]))
	for wave in waves:
		host._send(peer, wave_packet(wave))


func ring_allowed(at: Vector2) -> bool:
	var body := Rect2(at - Vector2(8, 18), Vector2(16, 37))
	for ring in rings.values():
		var box := Rect2(ring.at + Vector2(7, 7), Vector2(16, 16))
		var gap := Vector2(
			maxf(0, maxf(body.position.x - box.end.x, box.position.x - body.end.x)),
			maxf(0, maxf(body.position.y - box.end.y, box.position.y - body.end.y))
		)
		if gap.length() < 100:
			return false
	return true


func handle(p, type: int, b: StreamPeerBuffer) -> bool:
	if (
		type
		not in [
			NetPackets.CLIENT_EXETIOR_ACTION,
			NetPackets.CLIENT_ERECTOR_BALLS,
			NetPackets.CLIENT_ERECTOR_BRING_SPAWN,
			NetPackets.CLIENT_BRING_COLLECTED
		]
	):
		return false
	if p == null or host.server_state != host.S.GAMESTART or host.round_ending:
		return true
	# Legacy effect/spawn packets cannot bypass ability validation.
	if type == NetPackets.CLIENT_BRING_COLLECTED:
		if b.get_available_bytes() >= 2:
			collect(p, b.get_u16())
		return true
	if type != NetPackets.CLIENT_EXETIOR_ACTION or b.get_available_bytes() < 5:
		return true
	var action := b.get_u8()
	var at := Vector2(b.get_16(), b.get_16())
	var accepted := false
	var now: int = host._game_frame
	var purple: bool = action == 4 and b.get_available_bytes() > 0 and b.get_u8() != 0
	if (
		action == 5
		and is_exetior(p)
		and at.distance_to(host.character_rules.pos(p)) <= 64
		and (p.get("exetior_stomp", 0) == 1 or p.get("exetior_land_end", 0) > now)
	):
		var cooldown := 240
		if p.get("exetior_stomp", 0) == 1:
			for point in springs.get(str(host.chosen_map), []):
				if at.distance_to(Vector2(point[0], point[1])) <= 36:
					cooldown = 60 if host.character_rules.grounded(p) else 120
					break
		p.exetior_ready = now + cooldown
		p.exetior_attack_end = 0
		p.exetior_stomp = 0
		p.exetior_land_end = 0
		reply(p, true)
		return true
	if valid(p, action == 4) and at.distance_to(host.character_rules.pos(p)) <= 64:
		var ground: bool = host.character_rules.grounded(p)
		match action:
			0, 1, 2:
				if p.get("exetior_ready", 0) <= now and ground == (action == 0):
					p.exetior_attack_end = now + ([16, 19, 600][action])
					p.exetior_ready = now + ([60, 180, 840][action])
					p.exetior_stomp = int(action == 2)
					accepted = true
			3:
				if (
					p.get("exetior_stomp", 0) == 1
					and p.get("exetior_attack_end", 0) > now
					and ground
				):
					p.exetior_stomp = 0
					p.exetior_attack_end = 0
					p.exetior_ready = now + 272
					p.exetior_land_end = now + 32
					accepted = true
					var wave: Dictionary = {
						"owner": p.nid,
						"at": host.character_rules.pos(p),
						"born": now,
						"stopped": {}
					}
					waves.append(wave)
					host.profile_rules.event(p, "wave_start")
					host._broadcast(wave_packet(wave))
			4:
				if (
					p.get("exetior_ring_ready", 0) <= now
					and ring_allowed(host.character_rules.pos(p))
					and next_ring <= 65535
				):
					p.exetior_ring_ready = now + 2520
					var ring: Dictionary = {
						"owner": p.nid,
						"at": host.character_rules.pos(p) - Vector2(15, 15),
						"born": now,
						"purple": purple
					}
					rings[next_ring] = ring
					host._broadcast(ring_packet(next_ring, ring))
					next_ring += 1
					accepted = true
	if is_exetior(p):
		reply(p, accepted)
	return true


func collect(p: Dictionary, id: int):
	if (
		not rings.has(id)
		or not host.character_rules.alive(p)
		or host.character_rules.hunter(p)
		or not p.get("position_ready", false)
	):
		return
	var ring: Dictionary = rings[id]
	if host._game_frame - ring.born < 30:
		return
	if not Rect2(ring.at + Vector2(7, 7), Vector2(16, 16)).intersects(pickup_body(p)):
		return
	rings.erase(id)
	host._stat(p, "black_rings", 1)
	var b: StreamPeerBuffer = host._pkt(NetPackets.SERVER_BRING_STATE)
	b.put_u8(1)
	b.put_u16(id)
	host._broadcast(b)
	# This original cost bypasses hurt invulnerability/shields and preserves
	# fewer than five rings. It is not a melee hit or an attacker damage stat.
	if p.rings >= 5:
		p.rings -= 5
	else:
		p.hp = maxi(0, p.hp - 1)
		host._stat(p, "taken", 1)
		if p.hp == 0:
			p.is_dead = true
			p.dead_timer = 1860
			p.death_near = -1
			p.rings = 0
	host.active_map.owner_stats(p, 3)


func pickup_body(p: Dictionary) -> Rect2:
	var boxes: Array = survivor_hitboxes.get(str(p.char), [])
	var state: int = p.get("move_state", 0)
	if state < 0 or state >= boxes.size():
		return Rect2(host.character_rules.pos(p) - Vector2(8, 18), Vector2(16, 37))
	var box: Array = boxes[state]
	var left: float = -box[0] - box[2] if p.get("facing", 1) < 0 else box[0]
	return Rect2(host.character_rules.pos(p) + Vector2(left, box[1]), Vector2(box[2], box[3]))


func supported(at: Vector2, dir: int) -> bool:
	for x in [at.x - 3, at.x + 7, at.x + 18] if dir > 0 else [at.x - 18, at.x - 7, at.x + 3]:
		for y in [at.y - 14, at.y - 4, at.y + 5]:
			if host.character_rules.floor_at(Vector2(x, y)):
				return true
	return false


func flags(p: Dictionary, requested: int) -> int:
	var result: int = (
		requested
		& ~(NetPackets.PLAYER_INVIS | NetPackets.PLAYER_SLIME | NetPackets.PLAYER_ATTACKING)
	)
	if attack(p) and requested & NetPackets.PLAYER_ATTACKING:
		result |= NetPackets.PLAYER_ATTACKING
	return result


func tick():
	for p in host.players.values():
		if (
			is_exetior(p)
			and not valid(p)
			and (
				p.get("exetior_attack_end", 0) > host._game_frame
				or p.get("exetior_land_end", 0) > host._game_frame
			)
		):
			if p.get("exetior_stomp", 0) == 1 or p.get("exetior_land_end", 0) > host._game_frame:
				p.exetior_ready = host._game_frame + 240
			p.exetior_attack_end = 0
			p.exetior_stomp = 0
			p.exetior_land_end = 0
			p.attacking = false
			reply(p, false)
	for wave in waves.duplicate():
		var age: int = host._game_frame - wave.born
		if age >= 20:
			waves.erase(wave)
			continue
		for dir in [-1, 1]:
			if wave.stopped.has(dir):
				continue
			var at: Vector2 = wave.at + Vector2(dir * (25 if age < 10 else 50), 19)
			if not supported(at, dir):
				wave.stopped[dir] = true
				continue
			var body := Rect2(at + Vector2(-3 if dir > 0 else -18, -14), Vector2(22, 20))
			for p in host.players.values():
				if (
					not host.character_rules.alive(p)
					or host.character_rules.hunter(p)
					or p.hurttime > 0
					or not p.get("position_ready", false)
				):
					continue
				if body.intersects(
					Rect2(host.character_rules.pos(p) - Vector2(8, 18), Vector2(16, 37))
				):
					host._apply_survivor_damage(p, 1, wave.owner)
					if host.players.has(wave.owner):
						host.profile_rules.event(host.players[wave.owner], "bonus", 7)
					var b: StreamPeerBuffer = host._pkt(NetPackets.SERVER_MAP_DAMAGE)
					b.put_u8(4)
					b.put_8(p.hp)
					b.put_16(p.rings)
					b.put_u16(p.hurttime)
					b.put_u8(int(p.is_dead))
					b.put_8(dir)
					host._send(p.peer, b)
