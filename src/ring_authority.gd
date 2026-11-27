extends RefCounted
## Spawns, pickup hit tests, ring healing and destruction use server coordinates.
var host: Node


func _init(server: Node):
	host = server


func bounds(ring: Dictionary) -> Rect2:
	return Rect2(ring.get("at", Vector2(INF, INF)), Vector2(16, 16))


func ready(ring: Dictionary) -> bool:
	return (
		ring.timer == 0
		and host._game_frame - int(ring.get("born", host._game_frame)) >= (180 if ring.red else 30)
	)


func player_body(p: Dictionary) -> Rect2:
	var body: Rect2 = host.exetior_rules.pickup_body(p)
	var previous: Vector2 = p.get("motion_previous", Vector2(p.last_x, p.last_y))
	return body.merge(Rect2(body.position + previous - Vector2(p.last_x, p.last_y), body.size))


func can_collect(p: Dictionary, ring: Dictionary) -> bool:
	return (
		ready(ring)
		and host.character_rules.alive(p)
		and not host.character_rules.hunter(p)
		and p.get("position_ready", false)
		and (not ring.red or p.red_ring <= 0)
		and player_body(p).intersects(bounds(ring))
	)


func break_request(p: Dictionary, iid: int, uid: int):
	if not host._ring_valid(iid, uid):
		return
	var ring: Dictionary = host.ring_states[iid]
	if (
		not ready(ring)
		or ring.red
		or not host.character_rules.alive(p)
		or not host.character_rules.hunter(p)
		or not p.get("position_ready", false)
		or p.char in [1, 5]
		or not p.get("attacking", false)
	):
		return
	if player_body(p).intersects(bounds(ring)):
		destroy(iid, float(p.get("motion_velocity", Vector2.ZERO).x))


func destroy(iid: int, speed := 0.0):
	var ring: Dictionary = host.ring_states[iid]
	if ring.timer != 0 or ring.red:
		return
	ring.timer = -1 if ring.get("dynamic", false) else 2700
	var state: StreamPeerBuffer = host._pkt(NetPackets.SERVER_RING_STATE)
	state.put_u8(1)
	state.put_u8(iid)
	state.put_u16(ring.uid)
	host._broadcast(state)
	var pieces: StreamPeerBuffer = host._pkt(NetPackets.CLIENT_RING_BROKE, true)
	pieces.put_u16(int(ring.at.x))
	pieces.put_u16(int(ring.at.y))
	# The renderer expects the original half-float horizontal impulse.
	var raw := PackedByteArray()
	raw.resize(4)
	raw.encode_float(0, speed)
	var bits := raw.decode_u32(0)
	var exponent := int((bits >> 23) & 255) - 127 + 15
	var half := (
		((bits >> 16) & 32768) | (clampi(exponent, 0, 31) << 10) | ((bits & 8388607) >> 13)
		if exponent > 0
		else 0
	)
	pieces.put_u16(half)
	host._broadcast(pieces)


func projectile(area: Rect2):
	for iid in host.ring_states.size():
		var ring: Dictionary = host.ring_states[iid]
		if ready(ring) and not ring.red and area.intersects(bounds(ring)):
			destroy(iid)


func tick():
	if host.round_ending:
		return
	for iid in host.ring_states.size():
		var ring: Dictionary = host.ring_states[iid]
		if not ready(ring):
			continue
		for p in host.players.values():
			if can_collect(p, ring):
				var b: StreamPeerBuffer = host._pkt(NetPackets.CLIENT_RING_COLLECTED)
				b.put_u8(iid)
				b.put_u16(ring.uid)
				host._process_packet(p.peer, b.data_array)
				break
			if host.character_rules.hunter(p):
				break_request(p, iid, ring.uid)
				if ring.timer != 0:
					break
