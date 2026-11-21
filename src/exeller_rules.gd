extends RefCounted
var host: Node
var clones: Dictionary = {}
var next_id := 1
var last_layout := -1


func _init(server: Node):
	host = server


func is_exeller(p: Dictionary) -> bool:
	return p.get("char", -1) == 0 and p.get("exechar", -1) == 3


func reset_player(p: Dictionary):
	for key in ["exeller_ready", "exeller_attack_end", "clone_ready"]:
		p[key] = 0


func reset():
	clones.clear()
	next_id = 1
	last_layout = -1


func valid(p: Dictionary) -> bool:
	return (
		is_exeller(p)
		and host.server_state == host.S.GAMESTART
		and not host.round_ending
		and host.character_rules.valid_action(p, 0)
	)


func slots(p: Dictionary) -> Array:
	var result: Array = [-1, -1]
	for id in clones:
		if clones[id].owner == p.nid:
			result[clones[id].slot] = id
	return result


func reply(p: Dictionary, accepted: bool, action: int):
	var b: StreamPeerBuffer = host._pkt(NetPackets.SERVER_CHARACTER_STATUS)
	b.put_u8(9)
	b.put_u16(int(accepted))
	b.put_u16(maxi(0, p.get("exeller_ready", 0) - host._game_frame))
	b.put_u16(maxi(0, p.get("clone_ready", 0) - host._game_frame))
	for id in slots(p):
		b.put_u16(65535 if id < 0 else id)
	b.put_u8(action)
	host._send(p.peer, b)


func attack(p: Dictionary) -> bool:
	return valid(p) and p.get("exeller_attack_end", 0) > host._game_frame


func can_hit(p: Dictionary, target: Dictionary) -> bool:
	return (
		valid(p)
		and host.character_rules.pos(p).distance_to(host.character_rules.pos(target)) <= 64
		and (attack(p) or p.get("move_state", 0) in [3, 12])
	)


func flags(p: Dictionary, requested: int) -> int:
	var result: int = (
		requested
		& ~(NetPackets.PLAYER_INVIS | NetPackets.PLAYER_SLIME | NetPackets.PLAYER_ATTACKING)
	)
	if attack(p) and requested & NetPackets.PLAYER_ATTACKING:
		result |= NetPackets.PLAYER_ATTACKING
	return result


func packet(id: int, clone: Dictionary) -> StreamPeerBuffer:
	var b: StreamPeerBuffer = host._pkt(NetPackets.SERVER_EXELLERCLONE_STATE)
	b.put_u8(0)
	b.put_u16(id)
	b.put_u16(clone.owner)
	b.put_16(int(clone.at.x))
	b.put_16(int(clone.at.y))
	b.put_8(clone.dir)
	b.put_u8(clone.slot)
	return b


func snapshot(peer: ENetPacketPeer):
	for id in clones:
		host._send(peer, packet(id, clones[id]))


func safe_position(at: Vector2) -> Vector2:
	if host.chosen_map != 6:
		return at
	# Original Draw_76 pushes embedded clones upward after a layout change.
	# Jump straight past intersecting floor bounds, with a bounded failure case.
	for attempts in 128:
		var body := Rect2(at - Vector2(7, 20), Vector2(15, 39))
		var next_y := at.y
		for floor in host.character_rules.geometry.get("6", []):
			if floor.group == "floor" and floor.bounds.intersects(body):
				next_y = minf(next_y, floor.bounds.position.y - 19)
		if next_y == at.y:
			return at
		if at.y - next_y > 4096:
			return Vector2(INF, INF)
		at.y = next_y
	return Vector2(INF, INF)


func handle(p, type: int, b: StreamPeerBuffer) -> bool:
	if (
		type
		not in [
			NetPackets.CLIENT_EXELLER_ATTACK,
			NetPackets.CLIENT_EXELLER_SPAWN_CLONE,
			NetPackets.CLIENT_EXELLER_TELEPORT_CLONE
		]
	):
		return false
	if p == null or not is_exeller(p):
		return true
	var action: int = {
		NetPackets.CLIENT_EXELLER_ATTACK: 0,
		NetPackets.CLIENT_EXELLER_SPAWN_CLONE: 1,
		NetPackets.CLIENT_EXELLER_TELEPORT_CLONE: 2
	}[type]
	var accepted := false
	var now: int = host._game_frame
	if valid(p):
		match action:
			0:
				if b.get_available_bytes() >= 1:
					var air := b.get_u8()
					if (
						air in [0, 1]
						and p.get("exeller_ready", 0) <= now
						and (air == 0) == host.character_rules.grounded(p)
					):
						p.exeller_ready = now + (60 if air == 0 else 120)
						p.exeller_attack_end = now + (16 if air == 0 else 20)
						accepted = true
			1:
				if b.get_available_bytes() >= 5:
					var at := Vector2(b.get_16(), b.get_16())
					var facing := b.get_8()
					var occupied := slots(p)
					var slot := occupied.find(-1)
					if (
						slot >= 0
						and p.get("clone_ready", 0) <= now
						and at.distance_to(host.character_rules.pos(p)) <= 32
						and facing in [-1, 1]
						and next_id < 65535
					):
						at = safe_position(host.character_rules.pos(p))
						if at.is_finite():
							var clone: Dictionary = {
								"owner": p.nid, "at": at, "dir": facing, "slot": slot
							}
							clones[next_id] = clone
							p.clone_ready = now + 180
							host._broadcast(packet(next_id, clone))
							next_id += 1
							accepted = true
			2:
				if b.get_available_bytes() >= 2:
					var id := b.get_u16()
					if clones.has(id) and clones[id].owner == p.nid:
						host.profile_rules.event(p, "clone")
						var clone: Dictionary = clones[id]
						var at := safe_position(clone.at)
						if at.is_finite():
							clones.erase(id)
							p.last_x = int(at.x)
							p.last_y = int(at.y)
							p.clone_ready = now + 1800
							var consume: StreamPeerBuffer = host._pkt(
								NetPackets.SERVER_EXELLERCLONE_STATE
							)
							consume.put_u8(1)
							consume.put_u16(id)
							consume.put_u16(p.nid)
							consume.put_16(p.last_x)
							consume.put_16(p.last_y)
							consume.put_u8(clone.slot)
							host._broadcast(consume)
							accepted = true
	reply(p, accepted, action)
	return true


func tick():
	for p in host.players.values():
		if is_exeller(p) and not valid(p) and p.get("exeller_attack_end", 0) > host._game_frame:
			p.exeller_attack_end = 0
			p.attacking = false
			reply(p, false, 0)
	if host.chosen_map == 6 and last_layout != host.active_map.np_state:
		last_layout = host.active_map.np_state
		for id in clones:
			var at := safe_position(clones[id].at)
			if at.is_finite() and at != clones[id].at:
				clones[id].at = at
				var b: StreamPeerBuffer = host._pkt(NetPackets.SERVER_EXELLERCLONE_STATE)
				b.put_u8(2)
				b.put_u16(id)
				b.put_16(int(at.x))
				b.put_16(int(at.y))
				host._broadcast(b)
