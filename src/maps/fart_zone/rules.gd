extends "res://src/maps/shared/rules.gd"
## Fart Zone: authoritative map mechanics.
var dummy = Vector2(1616, 2608)
var speed = 0.0
var frame = 0
var potato: Dictionary = {}
var losses: Dictionary = {}
var ball = 0.0
var ball_dir = -1.0
const SPIKE_FRAMES = [0, 1, 2, 3, 4, 5]
const SPIKE_DWELL = [120, 1, 120, 1, 1, 1]
var spike_index = 0
var spike_ticks = 0


func reset():
	super.reset()
	dummy = Vector2(1616, 2608)
	speed = 0
	frame = 0
	potato.clear()
	losses.clear()
	ball = 0
	ball_dir = -1
	spike_index = 0
	spike_ticks = 0


func snapshot(peer: ENetPacketPeer = null) -> void:
	var b = host._pkt(NetPackets.SERVER_FART_STATE)
	b.put_u16(int(dummy.x))
	b.put_u16(int(dummy.y))
	b.put_float(ball)
	b.put_float(ball_dir)
	b.put_u8(SPIKE_FRAMES[spike_index])
	if peer == null:
		host._broadcast(b)
	else:
		host._send(peer, b)


func handle(p, type, rb) -> bool:
	if type not in [NetPackets.CLIENT_FART_PUSH, NetPackets.CLIENT_PLAYER_POTATER]:
		return false
	if (
		host.server_state != host.S.GAMESTART
		or p == null
		or (not p.get("in_round", false))
		or (not p.get("position_ready", false))
	):
		return true
	var pos = Vector2(p.last_x, p.last_y)
	if type == NetPackets.CLIENT_FART_PUSH:
		if rb.get_available_bytes() < 1 or int(p.get("dummy_ready", 0)) > host._game_frame:
			return true
		var requested = rb.get_8()
		var projectile = false
		if p.char == 1 and int(p.get("map_ray_until", 0)) > host._game_frame:
			var origin: Vector2 = p.get("map_ray_origin", pos)
			projectile = (
				absf(origin.y - dummy.y) < 64
				and (dummy.x - origin.x) * p.get("map_ray_dir", 1) >= 0
				and absf(dummy.x - origin.x) <= 3300
			)
		if pos.distance_squared_to(dummy) > 100 * 100 and not projectile:
			return true
		if (
			not p.get("attacking", false)
			and not projectile
			and not (p.char == 0 and int(p.get("move_state", 0)) in [3, 4, 12])
		):
			return true
		var amount = (
			clampi(int(p.get("last_shot_power", 1)), 1, 6)
			if projectile
			else 6 if p.char == 0 and p.get("exechar", 0) != 1 else 4 if p.char in [2, 4] else 3
		)
		if projectile:
			p.map_ray_until = host._game_frame
		speed = amount * signf(dummy.x - pos.x)
		p.dummy_ready = host._game_frame + 20
	else:
		if rb.get_available_bytes() < 3:
			return true
		var action = rb.get_u8()
		var id = rb.get_u16()
		if action == 1:
			return true  # The server, rather than the sender, ends possession.
		if id == p.nid and not potato.has(p.nid) and not losses.has(p.nid):
			var touched = false
			for record in host.active_map.rooms.get("20", {}).get("instances", []):
				if (
					record.object == "obj_fart_mermer"
					and pos.distance_to(Vector2(record.position[0], record.position[1])) < 56
				):
					touched = true
					break
			if touched:
				set_potato(p.nid)
		elif potato.has(p.nid) and potato[p.nid].ticks <= 210 and host.players.has(id):
			var other: Dictionary = host.players[id]
			if (
				not potato.has(id)
				and not losses.has(id)
				and other.get("in_round", false)
				and other.get("position_ready", false)
				and not other.get("is_dead", false)
				and pos.distance_to(Vector2(other.last_x, other.last_y)) <= 48
			):
				clear_potato(p.nid)
				set_potato(id)
	return true


func set_potato(id: int):
	potato[id] = {"ticks": 240}
	potato_packet(0, id, 4)


func clear_potato(id: int):
	potato.erase(id)
	potato_packet(1, id, 0)


func potato_packet(action: int, id: int, seconds: int):
	var b = host._pkt(NetPackets.CLIENT_PLAYER_POTATER)
	b.put_u8(action)
	b.put_u16(id)
	if action == 0:
		b.put_u8(seconds)
	host._broadcast(b)


func tick():
	frame += 1
	dummy.x = clampf(dummy.x + speed, 1282, 2944)
	speed = move_toward(speed, 0, .1875)
	if frame % 3 == 0:
		snapshot()
	spike_ticks += 1
	if spike_ticks >= SPIKE_DWELL[spike_index]:
		spike_ticks = 0
		spike_index = (spike_index + 1) % SPIKE_FRAMES.size()
		var b = host._pkt(NetPackets.SERVER_MOVINGSPIKE_STATE)
		b.put_u8(SPIKE_FRAMES[spike_index])
		host._broadcast(b)
	ball = clampf(ball + .015 * ball_dir, -1, 1)
	if absf(ball) >= 1:
		ball_dir = -ball_dir
	for p in host.players.values():
		if not host.active_map.living(p):
			continue
		for record in host.active_map.objects("obj_darktower_ball"):
			var box: Rect2 = host.active_map.rect(record)
			box.position.y += (
				ball
				* float(record.properties.get("dir", 1))
				* float(record.properties.get("dist", 100))
			)
			if host.active_map.body(p).intersects(box):
				host._apply_survivor_damage(p, 1)
				host.active_map.owner_stats(p)
		if SPIKE_FRAMES[spike_index] in [1, 2, 3, 4]:
			for record in host.active_map.objects("obj_movingspike"):
				if host.active_map.body(p).intersects(
					Rect2(record.position[0], record.position[1], 32, 32)
				):
					host._apply_survivor_damage(p, 1)
					host.active_map.owner_stats(p)
	for id in losses.keys():
		losses[id] -= 1
		if losses[id] <= 0:
			losses.erase(id)
			if host.players.has(id):
				host.chat_commands.remove(host.players[id], false, "Practice session ended.")
	for id in potato.keys():
		if not host.players.has(id):
			potato.erase(id)
			continue
		potato[id].ticks -= 1
		if potato[id].ticks % 60 == 0:
			potato_packet(0, id, maxi(0, potato[id].ticks / 60))
		if potato[id].ticks <= 0:
			clear_potato(id)
			losses[id] = 30
