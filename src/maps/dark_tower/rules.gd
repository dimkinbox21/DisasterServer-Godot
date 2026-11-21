extends "res://src/maps/shared/rules.gd"
## Dark Tower: authoritative map mechanics.
# Source objects + BetterServer DTTailsDoll/DTAss/DTBall/HDDoor state machines.
const DOLL_POINTS := [
	[177, 944],
	[1953, 544],
	[3279, 224],
	[4101, 544],
	[4060, 1264],
	[3805, 1824],
	[2562, 1584],
	[515, 1824],
	[2115, 1056],
	[984, 1184],
	[1498, 1504]
]
const STAL_POINTS := [
	[1744, 224],
	[1840, 224],
	[1936, 224],
	[2032, 224],
	[2128, 224],
	[1824, 784],
	[1920, 784],
	[2016, 784],
	[2112, 784],
	[2208, 784],
	[2464, 1384],
	[2592, 1384],
	[3032, 64],
	[3088, 64]
]
var age := 0
var doll: Dictionary = {}
var stals: Dictionary = {}
var ball := 0.0
var ball_dir := -1.0
var events: Array = []
var pending := false


func alive(p: Dictionary) -> bool:
	return host.character_rules.alive(p) and p.get("position_ready", false)


func hiding(p: Dictionary) -> bool:
	if p.get("move_state", 0) != 8:
		return false
	for i in rooms.get(str(host.chosen_map), {}).get("instances", []):
		if "obj_hiding_parent" in i.parents and body(p).intersects(rect(i)):
			return true
	return false


func living(p: Dictionary) -> bool:
	return alive(p) and not host.character_rules.hunter(p)


func reset():
	super.reset()
	age = 0

	stals.clear()
	events.clear()
	ball = 0
	ball_dir = -1
	pending = true
	doll = {"x": 177.0, "y": 944.0, "state": 0, "target": -1, "timer": 0, "vx": 0.0, "vy": 0.0}
	place_doll()
	for id in STAL_POINTS.size():
		var at: Array = STAL_POINTS[id]
		stals[str(id)] = {
			"x": float(at[0]),
			"y": float(at[1]),
			"sy": float(at[1]),
			"state": 1,
			"timer": 0,
			"vy": 0.0
		}


func event(kind: String, at := Vector2.ZERO, owner := -1):
	events.append({"kind": kind, "x": at.x, "y": at.y, "owner": owner})
	pending = true


func place_doll():
	var candidates: Array = []
	for point in DOLL_POINTS:
		var at := Vector2(point[0], point[1])
		var clear := true
		for p in host.players.values():
			if alive(p) and at.distance_to(Vector2(p.last_x, p.last_y)) < 480:
				clear = false
				break
		if clear:
			candidates.append(point)
	var point: Array = (
		candidates.pick_random() if not candidates.is_empty() else DOLL_POINTS.pick_random()
	)
	doll.x = float(point[0])
	doll.y = float(point[1])
	doll.vx = 0.0
	doll.vy = 0.0
	doll.target = -1
	doll.state = 0
	pending = true


func snapshot(peer: ENetPacketPeer = null) -> void:
	var data = {
		"map": host.chosen_map,
		"age": age,
		"doll": doll,
		"stals": stals,
		"ball": ball,
		"ball_dir": ball_dir,
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
		return true
	# Stalactite landing is server simulated; never trust a remote destroy request.
	return true


func damage(p: Dictionary):
	if not living(p) or p.hurttime > 0:
		return
	apply_damage(p, 1, 2)


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
	tick_tower()
	if pending or age % 6 == 0:
		snapshot()
		events.clear()
		pending = false


func tick_tower():
	ball += 0.015 * ball_dir
	if ball >= 1:
		ball = 1
		ball_dir = -1
	elif ball <= -1:
		ball = -1
		ball_dir = 1
	for p in host.players.values():
		if not living(p):
			continue
		for i in objects("obj_darktower_ball"):
			var box := rect(i)
			box.position.y += (
				ball * float(i.properties.get("dir", 1)) * float(i.properties.get("dist", 100))
			)
			if body(p).intersects(box):
				damage(p)
	var target: Dictionary = host.players.get(int(doll.target), {})
	if int(doll.state) == 0 or int(doll.state) == 2:
		# The original retargets the first visible survivor within 130px each tick.
		for p in host.players.values():
			if (
				living(p)
				and not hiding(p)
				and Vector2(p.last_x, p.last_y).distance_to(Vector2(doll.x, doll.y)) < 130
			):
				target = p
				doll.target = p.nid
				break
	if int(doll.state) == 0:
		if not target.is_empty() and living(target):
			doll.state = 1
			doll.timer = 60 + 30 * randi_range(0, 1)
			event("doll_notice", Vector2(doll.x, doll.y), target.nid)
	elif int(doll.state) == 1:
		doll.timer -= 1
		if doll.timer <= 0:
			doll.state = 2
			event("doll_chase", Vector2(doll.x, doll.y), int(doll.target))
	elif int(doll.state) == 2:
		if target.is_empty() or not living(target) or hiding(target):
			doll.state = 3
		else:
			if absf(target.last_x - doll.x) >= 4:
				doll.vx = clampf(doll.vx + signf(target.last_x - doll.x) * 0.512, -5, 5)
			if absf(target.last_y - doll.y) >= 5:
				doll.vy = clampf(doll.vy + signf(target.last_y - doll.y) * 0.48, -5, 5)
			doll.x += doll.vx
			doll.y += doll.vy
			if Vector2(target.last_x, target.last_y).distance_to(Vector2(doll.x, doll.y)) < 12:
				host.character_rules.status(target, 0, 180)
				event("jumpscare", Vector2(doll.x, doll.y), target.nid)
				doll.state = 3
	else:
		place_doll()
	for id in stals:
		var s: Dictionary = stals[id]
		if s.state == 0:
			s.timer = maxi(0, s.timer - 1)
			if s.timer <= 60:
				s.state = 1
				pending = true
		elif s.state == 1:
			s.timer = maxi(0, s.timer - 1)
			if s.timer <= 0:
				for p in host.players.values():
					if (
						alive(p)
						and not hiding(p)
						and p.last_x >= s.x
						and p.last_x <= s.x + 80
						and p.last_y > s.y
						and p.last_y <= s.y + 336
					):
						s.state = 2
						s.vy = 0.0
						event("stal_notice", Vector2(s.x, s.y))
						break
		else:
			s.vy += 0.164
			# Swept checks prevent tunneling through a thin platform at high speed.
			var landed := false
			for step in ceili(s.vy):
				if host.character_rules.floor_strip(Rect2(s.x + 19, s.y + 18, 41, 3)):
					landed = true
					break
				s.y += minf(1, s.vy - step)
				for p in host.players.values():
					if living(p) and body(p).intersects(Rect2(s.x + 19, s.y + 10, 41, 63)):
						damage(p)
			if landed or s.y > 2000:
				event("stal_break", Vector2(s.x, s.y))
				s.state = 0
				s.y = s.sy
				s.vy = 0.0
				s.timer = (25 + randi_range(0, 4)) * 60
