extends RefCounted
## Survivor entities and accepted ability windows. The client simulates
## movement; the server owns teams, cooldowns, shield hits and ring identities.
var host: Node
var traps := {}
var next_trap := 0
var sally_bursts: Array = []
var geometry: Dictionary = {}
var strip_grid: Dictionary = {}


func _init(server: Node) -> void:
	host = server
	geometry = preload("res://src/data/maps.gd").table("geometry")
	for map_id in geometry:
		for g in geometry[map_id]:
			var low := Vector2(INF, INF)
			var high := Vector2(-INF, -INF)
			for x in [g.l, g.l + g.w]:
				for y in [g.t, g.t + g.h]:
					var corner := (
						Vector2(g.x, g.y) + (Vector2(x, y) * Vector2(g.sx, g.sy)).rotated(g.rot)
					)
					low = low.min(corner)
					high = high.max(corner)
			g.bounds = Rect2(low, high - low)


func reset() -> void:
	traps.clear()
	sally_bursts.clear()
	next_trap = 0
	for p in host.players.values():
		reset_player(p)


func reset_player(p: Dictionary) -> void:
	host.chaos_rules.reset_player(p)
	host.exetior_rules.reset_player(p)
	host.exeller_rules.reset_player(p)
	p.egg_shield_end = 0
	p.egg_shield_ready = 0
	p.tracker_ready = 0
	p.cream_ready = 0
	p.knux_ready = 0
	p.knux_attack_end = 0
	p.knux_reported_attack = false
	p.melee_ready = 0
	p.melee_end = 0
	p.melee_reported = false
	p.amy_jump_ready = 0
	p.amy_jump_end = 0
	p.amy_jump_reported = false
	p.sally_shield_end = 0
	p.sally_ready = 0
	p.sally_expired = false


func melee_flags(p: Dictionary, requested: bool) -> bool:
	if p.char == 2:
		return knux_flags(p, requested)
	if p.char not in [4, 6]:
		return false
	if p.char == 4:
		var high: bool = p.get("move_state", 0) == 15
		if (
			high
			and not p.get("amy_jump_reported", false)
			and valid_action(p, 4)
			and p.get("amy_jump_ready", 0) <= host._game_frame
		):
			p.amy_jump_end = host._game_frame + 21
			p.amy_jump_ready = host._game_frame + 540
		p.amy_jump_reported = high
		if high:
			return requested and melee_attacking(p)
	if (
		requested
		and not p.get("melee_reported", false)
		and valid_action(p, p.char)
		and p.get("move_state", 0) == 14
		and p.get("melee_ready", 0) <= host._game_frame
	):
		p.melee_ready = (
			host._game_frame
			+ ({4: 300, 6: 240}[p.char] if hunter(p) else {4: 1200, 6: 900}[p.char])
		)
		p.melee_end = host._game_frame + (24 if p.char == 4 else 20)
		if p.char == 4:
			for i in 4:
				effect(
					10 if hunter(p) else 9,
					pos(p) + Vector2(2 + i * 10 * p.get("facing", 1), -4 + randi_range(-3, 3)),
					Vector2(0, -1),
					0.5,
					p.nid
				)
	p.melee_reported = requested
	return requested and melee_attacking(p)


func melee_attacking(p: Dictionary) -> bool:
	if p.char == 2:
		return knux_attacking(p)
	if p.char not in [4, 6] or not valid_action(p, p.char):
		return false
	if p.char == 4 and p.get("move_state", 0) == 15:
		return p.get("amy_jump_end", 0) > host._game_frame and p.get("move_frame", 99) < 3
	return p.get("move_state", 0) == 14 and p.get("melee_end", 0) > host._game_frame


func sally_shield(p: Dictionary) -> bool:
	return alive(p) and p.char == 6 and p.get("sally_shield_end", 0) > host._game_frame


func effect(id: int, at: Vector2, motion := Vector2.ZERO, speed := 1.0, except_nid := -1) -> void:
	var b: StreamPeerBuffer = host._pkt(NetPackets.CLIENT_SPAWN_EFFECT)
	b.put_u16(int(at.x))
	b.put_u16(int(at.y))
	b.put_u8(0)
	b.put_8(1)
	b.put_u8(id)
	b.put_8(int(motion.x))
	b.put_8(int(motion.y))
	b.put_float(speed)
	host._broadcast(b, except_nid)


func break_sally_shield(p: Dictionary, impulse := Vector2.ZERO) -> bool:
	if not sally_shield(p):
		return false
	host.profile_rules.event(p, "shield")
	p.sally_shield_end = 0
	p.sally_expired = true
	p.hurttime = 60
	p.sally_ready = host._game_frame + (900 if hunter(p) else 1800)
	var b: StreamPeerBuffer = host._pkt(NetPackets.SERVER_CHARACTER_STATUS)
	b.put_u8(6)
	b.put_u16(60)
	b.put_8(int(impulse.x))
	b.put_8(int(impulse.y))
	host._send(p.peer, b)
	shield_burst(p, p.nid)
	return true


func shield_burst(p: Dictionary, except_nid := -1) -> void:
	effect(12 if hunter(p) else 6, pos(p), Vector2.ZERO, 1, except_nid)
	var sound: StreamPeerBuffer = host._pkt(NetPackets.CLIENT_SOUND_EMIT, true)
	sound.put_u16(p.nid)
	sound.put_u8(24)
	sound.put_u8(0)
	host._broadcast(sound, except_nid)
	if hunter(p):
		sally_bursts.append({"at": pos(p), "end": host._game_frame + 12, "owner": p.nid})


func knux_flags(p: Dictionary, requested: bool) -> bool:
	# The original sprites finish after ~15/16 ticks. A bounded 20-tick
	# server window tolerates packet timing, while enforcing 20s/5s recharge.
	if (
		requested
		and not p.get("knux_reported_attack", false)
		and valid_action(p, 2)
		and p.get("move_state", 0) in [14, 15]
		and p.get("knux_ready", 0) <= host._game_frame
	):
		p.knux_ready = host._game_frame + (300 if hunter(p) else 1200)
		p.knux_attack_end = host._game_frame + 20
	p.knux_reported_attack = requested
	return requested and knux_attacking(p)


func knux_attacking(p: Dictionary) -> bool:
	return (
		valid_action(p, 2)
		and p.get("move_state", 0) in [14, 15]
		and p.get("knux_attack_end", 0) > host._game_frame
	)


func knux_stun(victim: Dictionary, attacker: Dictionary) -> void:
	var b: StreamPeerBuffer = host._pkt(NetPackets.SERVER_CHARACTER_STATUS)
	b.put_u8(3)
	b.put_u16(180)
	b.put_8(int(-signf(pos(attacker).x - pos(victim).x) * 4))
	host._send(victim.peer, b)


func try_parry(a: Dictionary, b: Dictionary) -> bool:
	if not alive(a) or not alive(b) or hunter(a) == hunter(b):
		return false
	var human: Dictionary = b if hunter(a) else a
	var demon: Dictionary = a if hunter(a) else b
	if (
		human.char not in [2, 6]
		or demon.char in [3, 4]
		or not human.get("attacking", false)
		or not demon.get("attacking", false)
		or not melee_attacking(human)
	):
		return false
	for p in [human, demon]:
		if (
			not p.get("position_ready", false)
			or p.get("hurttime", 0) > 0
			or p.get("stunned_ticks", 0) > 0
			or (p.char == 0 and p.get("invisible", false))
		):
			return false
	var delta := pos(human) - pos(demon)
	if absf(delta.x) > 24 or absf(delta.y) > 32:
		return false
	var direction := signf(delta.x)
	if direction == 0:
		direction = -signf(demon.get("facing", 1))
	if direction == 0:
		direction = 1
	for p in [human, demon]:
		p.hurttime = 60
		p.stunned_ticks = 0
		p.attacking = false
		if p.char == 2:
			p.knux_attack_end = 0
		if p.char in [4, 6]:
			p.melee_end = 0
		var packet: StreamPeerBuffer = host._pkt(NetPackets.SERVER_CHARACTER_STATUS)
		packet.put_u8(4)
		packet.put_u16(60)
		packet.put_8(int(direction * (3 if p.nid == human.nid else -2)))
		host._send(p.peer, packet)
	# The two owners play their predicted/confirmed sound locally. Spectators
	# receive one positional sound, without echoing either owner's prediction.
	var sound: StreamPeerBuffer = host._pkt(NetPackets.CLIENT_SOUND_EMIT, true)
	sound.put_u16(human.nid)
	sound.put_u8(11)
	sound.put_u8(0)
	for observer in host.players.values():
		if observer.nid not in [human.nid, demon.nid] and observer.get("in_round", false):
			host._send(observer.peer, sound)
	return true


func alive(p: Dictionary) -> bool:
	return p.get("in_round", false) and not p.get("is_dead", true) and p.get("hp", 0) > 0


func hunter(p: Dictionary) -> bool:
	return p.char == 0 or p.get("revival", 0) >= 2


func pos(p: Dictionary) -> Vector2:
	return Vector2(p.get("last_x", 0), p.get("last_y", 0))


func shield(p: Dictionary) -> bool:
	return (
		alive(p)
		and p.char == 3
		and p.get("egg_shield_end", 0) > host._game_frame
		and p.get("move_state", 0) not in [5, 6]
		and p.get("red_ring", 0) <= 0
	)


func valid_action(p: Dictionary, char_id: int) -> bool:
	return (
		alive(p)
		and p.char == char_id
		and p.get("position_ready", false)
		and p.get("stunned_ticks", 0) <= 0
		and p.get("move_state", 0) not in [5, 6]
		and p.get("red_ring", 0) <= 0
	)


func status(p: Dictionary, kind: int, ticks: int) -> void:
	var b: StreamPeerBuffer = host._pkt(NetPackets.SERVER_CHARACTER_STATUS)
	b.put_u8(kind)
	b.put_u16(ticks)
	host._send(p.peer, b)


func floor_at(at: Vector2, group := "floor") -> bool:
	if group == "floor" and host.chosen_map == 20 and host.active_map.spike_index in [1, 2, 3, 4]:
		for item in host.active_map.objects("obj_movingspike"):
			if Rect2(item.position[0], item.position[1], 32, 32).has_point(at):
				return true
	if group == "floor" and host.chosen_map == 19 and host.active_map.floor_at(at):
		return true
	if group == "floor" and host.chosen_map == 17 and host.active_map.floor_at(at):
		return true
	if group == "floor" and host.chosen_map == 4 and host.active_map.spike in [1, 2, 3, 4]:
		for item in host.active_map.objects("obj_movingspike"):
			if Rect2(item.position[0], item.position[1], 32, 32).has_point(at):
				return true
	if group == "floor" and host.chosen_map == 9:
		for block in host.active_map.objects(9, "obj_nap_iceblock"):
			if (
				not host.active_map.ice.has(int(block.properties.get("nid", 0)))
				and host.active_map.rect(block).has_point(at)
			):
				return true
	for g in geometry.get(str(host.chosen_map), []):
		if g.group != group:
			continue
		if mask_contains(g, at):
			return true
	return false


func mask_contains(g: Dictionary, at: Vector2) -> bool:
	if not g.bounds.has_point(at):
		return false
	var local := (at - Vector2(g.x, g.y)).rotated(-g.rot) / Vector2(g.sx, g.sy)
	return Rect2(g.l, g.t, g.w, g.h).has_point(local)


func floor_strip(area: Rect2) -> bool:
	var key := str(host.chosen_map)
	var items: Array = geometry.get(key, [])
	if not strip_grid.has(key):
		var table: Dictionary = {}
		for index in items.size():
			var g: Dictionary = items[index]
			if g.group != "floor":
				continue
			var box: Rect2 = g.bounds
			for xx in range(floori(box.position.x / 256), floori(box.end.x / 256) + 1):
				for yy in range(floori(box.position.y / 256), floori(box.end.y / 256) + 1):
					var cell := Vector2i(xx, yy)
					if not table.has(cell):
						table[cell] = []
					table[cell].append(index)
		strip_grid[key] = table
	var seen: Dictionary = {}
	for cx in range(floori(area.position.x / 256), floori(area.end.x / 256) + 1):
		for cy in range(floori(area.position.y / 256), floori(area.end.y / 256) + 1):
			for index in strip_grid[key].get(Vector2i(cx, cy), []):
				if seen.has(index):
					continue
				seen[index] = true
				var g: Dictionary = items[index]
				if not g.bounds.intersects(area):
					continue
				var overlap: Rect2 = g.bounds.intersection(area)
				for yy in range(ceili(overlap.position.y), ceili(overlap.end.y)):
					for xx in range(ceili(overlap.position.x), ceili(overlap.end.x)):
						if mask_contains(g, Vector2(xx, yy)):
							return true
	return false


func cream_clear(center: Vector2) -> bool:
	if host.chosen_map == 19:
		var platform: Rect2 = host.active_map.platform_bounds()
		if (
			platform.has_area()
			and center.distance_squared_to(center.clamp(platform.position, platform.end)) <= 1024
		):
			return false
	if host.chosen_map == 17:
		for door in (
			host.active_map.objects("obj_hd_door") + host.active_map.objects("obj_hd_door2")
		):
			var box: Rect2 = host.active_map.door_bounds(door)
			if center.distance_squared_to(center.clamp(box.position, box.end)) <= 1024:
				return false
	if host.chosen_map == 9:
		for block in host.active_map.objects(9, "obj_nap_iceblock"):
			if host.active_map.ice.has(int(block.properties.get("nid", 0))):
				continue
			var box: Rect2 = host.active_map.rect(block)
			if center.distance_squared_to(center.clamp(box.position, box.end)) <= 1024:
				return false
	# Same integer mask samples as the client; only visit floors that overlap
	# the circle's bounds instead of searching the whole map for every pixel.
	var circle_box := Rect2(center - Vector2(32, 32), Vector2(65, 65))
	for g in geometry.get(str(host.chosen_map), []):
		if g.group != "floor":
			continue
		var rect: Rect2 = g.bounds.intersection(circle_box)
		if not rect.has_area():
			continue
		for yy in range(ceili(rect.position.y), ceili(rect.end.y)):
			var dy := yy - center.y
			if absf(dy) > 32:
				continue
			var width := sqrt(maxf(0, 1024 - dy * dy))
			for xx in range(
				ceili(maxf(rect.position.x, center.x - width)),
				floori(minf(rect.end.x - 1, center.x + width)) + 1
			):
				if mask_contains(g, Vector2(xx, yy)):
					return false
	return true


func grounded(p: Dictionary) -> bool:
	# collision_check_bottom snaps a supported sensor to player.y+18, at
	# ceil(player.x) +/-7. Sampling +19 misses subpixel-thin one-way floors.
	# Wire coordinates truncate x, so both possible ceil(x) values are valid.
	for rounding in [0, 1]:
		for side in [-7, 7]:
			if floor_at(pos(p) + Vector2(side + rounding, 18)):
				return true
	return false


func handle(p: Variant, nps: int, rb: StreamPeerBuffer) -> bool:
	if (
		nps
		not in [
			NetPackets.CLIENT_EGG_SHIELD,
			NetPackets.CLIENT_ETRACKER,
			NetPackets.CLIENT_ETRACKER_ACTIVATED,
			NetPackets.CLIENT_CREAM_SPAWN_RINGS,
			NetPackets.CLIENT_SOUND_EMIT,
			NetPackets.CLIENT_PLAYER_PARRY,
			NetPackets.CLIENT_SALLY_SHIELD
		]
	):
		return false
	if p == null or host.server_state != host.S.GAMESTART or host.round_ending:
		return true
	match nps:
		NetPackets.CLIENT_SALLY_SHIELD:
			if rb.get_available_bytes() < 1 or p.char != 6:
				return true
			var activate := rb.get_u8() != 0
			if not activate:
				if sally_shield(p):
					p.sally_ready = host._game_frame + (900 if hunter(p) else 1800)
				p.sally_shield_end = 0
				return true
			if valid_action(p, 6) and p.get("sally_ready", 0) <= host._game_frame:
				p.sally_shield_end = host._game_frame + 300
				p.sally_expired = false
				p.sally_ready = p.sally_shield_end + (900 if hunter(p) else 1800)
			var b: StreamPeerBuffer = host._pkt(NetPackets.SERVER_CHARACTER_STATUS)
			b.put_u8(5)
			b.put_u16(maxi(0, p.get("sally_shield_end", 0) - host._game_frame))
			b.put_u16(
				maxi(
					0,
					p.get("sally_ready", 0) - maxi(host._game_frame, p.get("sally_shield_end", 0))
				)
			)
			host._send(p.peer, b)
		NetPackets.CLIENT_PLAYER_PARRY:
			if rb.get_available_bytes() < 2:
				return true
			var other := rb.get_u16()
			if host.players.has(other):
				try_parry(p, host.players[other])
		NetPackets.CLIENT_EGG_SHIELD:
			if not valid_action(p, 3) or p.get("egg_shield_ready", 0) > host._game_frame:
				if p.char == 3:
					status(p, 2, clampi(p.get("egg_shield_ready", 0) - host._game_frame, 0, 65535))
				return true
			p.egg_shield_end = host._game_frame + 89
			p.egg_shield_ready = p.egg_shield_end + (420 if hunter(p) else 1200) - 1
		NetPackets.CLIENT_ETRACKER:
			if (
				rb.get_available_bytes() < 4
				or not valid_action(p, 3)
				or p.get("tracker_ready", 0) > host._game_frame
				or p.get("move_state", 0) != 8
			):
				return true
			var at := Vector2(rb.get_u16(), rb.get_u16())
			if at.distance_to(pos(p) + Vector2(0, 18)) > 8:
				return true
			if not grounded(p) or floor_at(pos(p), "angle"):
				return true
			var foot: Vector2 = pos(p) + Vector2(12 * p.get("facing", 1), 18)
			if not floor_at(foot) and not floor_at(foot + Vector2(0, 1)):
				return true
			p.tracker_ready = host._game_frame + 1800
			next_trap = (next_trap + 1) % 65536
			traps[next_trap] = {"id": next_trap, "owner": p.nid, "at": at, "demon": hunter(p)}
			broadcast_trap(traps[next_trap])
		NetPackets.CLIENT_ETRACKER_ACTIVATED:
			# The server checks contacts every tick. A report merely requests
			# an immediate check; it cannot choose another victim or trap owner.
			if rb.get_available_bytes() < 2:
				return true
			var id := rb.get_u16()
			if traps.has(id):
				try_trap(traps[id], p)
		NetPackets.CLIENT_CREAM_SPAWN_RINGS:
			if (
				rb.get_available_bytes() < 5
				or not valid_action(p, 5)
				or p.get("cream_ready", 0) > host._game_frame
				or p.get("move_state", 0) != 15
			):
				return true
			var center := Vector2(rb.get_u16(), rb.get_u16())
			rb.get_u8()  # demon status is always server-authored
			if (
				center.distance_to(
					pos(p) + Vector2(-12 + (7 if p.get("facing", 1) < 0 else 0), -16)
				)
				> 8
			):
				return true
			if not grounded(p) or not cream_clear(center) or floor_at(pos(p), "angle"):
				return true
			var demon := hunter(p)
			if demon:
				for ring in host.ring_states:
					if (
						ring.timer == 0
						and ring.red
						and ring.has("at")
						and pos(p).distance_to(ring.at) <= 130
					):
						return true
			p.cream_ready = host._game_frame + 1500  # BetterServer: shared 25s lower bound; client recharges 40s/30s.
			var offsets := (
				[Vector2(25, 0), Vector2(-27, 0)]
				if demon
				else [Vector2(26, 0), Vector2(0, -26), Vector2(-27, 0)]
			)
			for offset in offsets:
				spawn_ring(center + offset, demon)
		NetPackets.CLIENT_SOUND_EMIT:
			if rb.get_available_bytes() < 4 or not alive(p):
				return true
			rb.get_u16()
			var sound := rb.get_u8()
			rb.get_u8()
			var allowed: Array = (
				{2: [1, 37], 3: [18, 19, 29], 4: [1, 4], 5: [21, 26], 6: [1, 22, 23]}
				. get(p.char, [])
			)
			if host.chaos_rules.is_chaos(p):
				allowed = [40, 41, 42, 43]
			if host.exetior_rules.is_exetior(p):
				allowed = [1, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54]
			if host.exeller_rules.is_exeller(p):
				allowed = [1, 55, 56, 57, 58, 59, 60, 61]
			if sound != 11 and sound not in allowed:
				return true
			if host.exetior_rules.is_exetior(p) or host.exeller_rules.is_exeller(p):
				if not p.has("sound_frames"):
					p.sound_frames = {}
				if p.sound_frames.get(sound, -30) + 8 > host._game_frame:
					return true
				p.sound_frames[sound] = host._game_frame
			else:
				if p.get("sound_frame", -30) + 8 > host._game_frame:
					return true
				p.sound_frame = host._game_frame
			var b: StreamPeerBuffer = host._pkt(NetPackets.CLIENT_SOUND_EMIT, true)
			b.put_u16(p.nid)
			b.put_u8(sound)
			b.put_u8(0)
			host._broadcast(b, p.nid)
	return true


func broadcast_trap(trap: Dictionary, peer: ENetPacketPeer = null) -> void:
	var b: StreamPeerBuffer = host._pkt(NetPackets.SERVER_ETRACKER_STATE)
	b.put_u8(0)
	b.put_u16(trap.id)
	b.put_u16(int(trap.at.x))
	b.put_u16(int(trap.at.y))
	b.put_u16(trap.owner)
	b.put_u8(int(trap.demon))
	if peer:
		host._send(peer, b)
	else:
		host._broadcast(b)


func try_trap(trap: Dictionary, p: Dictionary) -> void:
	if host.players.has(trap.owner):
		trap.demon = hunter(host.players[trap.owner])
	if not alive(p) or p.char == 3 or hunter(p) == trap.demon or not p.get("position_ready", false):
		return
	# Original spr_eggtrack mask: (-12,-6)..(12,0), against the player body.
	if not Rect2(trap.at - Vector2(12, 6), Vector2(24, 6)).intersects(
		Rect2(pos(p) - Vector2(8, 18), Vector2(16, 37))
	):
		return
	traps.erase(trap.id)
	if host.players.has(trap.owner):
		host.profile_rules.event(host.players[trap.owner], "tracker")
	status(p, 0, 180)
	var b: StreamPeerBuffer = host._pkt(NetPackets.SERVER_ETRACKER_STATE)
	b.put_u8(1)
	b.put_u16(trap.id)
	b.put_u16(p.nid)
	host._broadcast(b)


func tick() -> void:
	for p in host.players.values():
		if (
			p.char == 4
			and p.get("amy_jump_ready", 0) > host._game_frame
			and p.get("move_state", 0) in [3, 4, 15]
		):
			p.amy_jump_ready += 1
		if p.char == 6 and p.get("sally_shield_end", 0) > 0:
			if not alive(p):
				p.sally_shield_end = 0
			elif p.sally_shield_end <= host._game_frame and not p.get("sally_expired", false):
				p.sally_expired = true
				if hunter(p):
					shield_burst(p, p.nid)
	for burst in sally_bursts.duplicate():
		if burst.end <= host._game_frame:
			sally_bursts.erase(burst)
			continue
		var mask := Rect2(burst.at + Vector2(-34, -40), Vector2(72, 78))
		for p in host.players.values():
			if p.char == 6 or hunter(p) or not alive(p) or not p.get("position_ready", false):
				continue
			if p.hurttime <= 0 and mask.intersects(Rect2(pos(p) - Vector2(8, 18), Vector2(16, 37))):
				host._apply_survivor_damage(p, 1, burst.owner)
				if host.players.has(burst.owner):
					host.profile_rules.event(host.players[burst.owner], "bonus", 5)
	for trap in traps.values():
		for p in host.players.values():
			if not traps.has(trap.id):
				break
			try_trap(trap, p)


func snapshot(peer: ENetPacketPeer) -> void:
	host.exetior_rules.snapshot(peer)
	host.exeller_rules.snapshot(peer)
	for trap in traps.values():
		broadcast_trap(trap, peer)


func spawn_ring(at: Vector2, red: bool) -> void:
	var iid := -1
	for i in host.ring_states.size():
		if host.ring_states[i].get("dynamic", false) and host.ring_states[i].timer < 0:
			iid = i
			break
	if iid < 0:
		if host.ring_states.size() >= 256:
			return
		iid = host.ring_states.size()
		host.ring_states.append({})
	host.next_ring_uid = (host.next_ring_uid + 1) % 65536
	var ring := {
		"timer": 0,
		"uid": host.next_ring_uid,
		"red": red,
		"dynamic": true,
		"at": at,
		"born": host._game_frame
	}
	host.ring_states[iid] = ring
	var b: StreamPeerBuffer = ring_packet(iid, ring)
	host._broadcast(b)


func ring_packet(iid: int, ring: Dictionary) -> StreamPeerBuffer:
	var b: StreamPeerBuffer = host._pkt(NetPackets.SERVER_RING_STATE)
	b.put_u8(2)
	b.put_16(int(ring.at.x))
	b.put_16(int(ring.at.y))
	b.put_u8(iid)
	b.put_u16(ring.uid)
	b.put_u8(int(ring.red))
	return b
