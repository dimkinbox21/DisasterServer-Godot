extends "res://src/maps/shared/rules.gd"
## Not Perfect: authoritative map mechanics.
## Original entity schedules recovered from BetterServer.exe, source-matched payloads.
var np_state := 0
var np_stage := 0
var np_timer := 0


func reset() -> void:
	np_state = 0
	np_stage = 0
	np_timer = 0

	total_ticks = maxi(1, host.game_ticks)


func offset(state: int) -> Vector2:
	return Vector2(2904 if state in [1, 3] else 0, 1368 if state in [2, 3] else 0)


func snapshot(peer: ENetPacketPeer = null) -> void:
	# false means 'show the next layout', not a neutral state snapshot.
	if np_state != 0:
		np_packet(true, np_state, 0, peer)
	if np_stage == 1:
		np_packet(false, np_state, np_state, peer)


func np_packet(warn: bool, state: int, previous: int, peer: ENetPacketPeer = null) -> void:
	var b: StreamPeerBuffer = host._pkt(NetPackets.SERVER_NPCONTROLLER_STATE)
	b.put_u8(int(warn))
	b.put_u8(state)
	b.put_u8(previous)
	if peer != null:
		host._send(peer, b)
	else:
		host._broadcast(b)


func tick() -> void:
	if host.round_ending:
		return
	np_timer += 1
	var fast: bool = host.game_ticks <= 3600
	if fast and not host.get_meta("np_fast", false):
		np_stage = 1
		np_timer = 300
		host.set_meta("np_fast", true)
	if np_stage == 1 and np_timer >= (180 if fast else 300):
		var previous := np_state
		np_state = (np_state + 1) % 4
		np_timer = 0
		np_stage = 0
		for p in host.players.values():
			if p.get("position_ready", false):
				var at := Vector2(p.last_x, p.last_y) - offset(previous) + offset(np_state)
				p.last_x = int(at.x)
				p.last_y = int(at.y)
		np_packet(true, np_state, previous)
	elif np_stage == 0 and np_timer >= (120 if fast else 900):
		np_stage = 1
		np_timer = 0
		np_packet(false, np_state, np_state)
