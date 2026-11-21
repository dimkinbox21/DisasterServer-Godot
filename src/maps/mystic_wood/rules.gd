extends "res://src/maps/shared/rules.gd"
## Mystic Wood: authoritative map mechanics.
# Source-matched PF/VV/WD/MJ mechanics. Timers are fixed 60Hz, owned by server.
var age = 0
var rings: Dictionary = {}
var lantern = -1
var lantern_timer = 420
var lantern_since = 0
var events: Array = []
var pending = false


func event(kind: String, at := Vector2.ZERO, owner := -1, extra: Dictionary = {}):
	var data = {}
	data.merge(extra)
	events.append(data)
	pending = true


func reset():
	super.reset()
	age = 0

	rings.clear()

	events.clear()

	pending = true
	lantern = -1
	lantern_timer = randi_range(7, 8) * 60
	lantern_since = 0

	for p in host.players.values():
		p.ruins_until = 0


func snapshot(peer: ENetPacketPeer = null) -> void:
	var data = {
		"map": host.chosen_map,
		"age": age,
		"lantern": lantern,
		"lantern_since": lantern_since,
		"lantern_timer": lantern_timer,
		"events": events if peer == null else []
	}
	var b = host._pkt(NetPackets.SERVER_FREEDOM_STATE)
	b.put_data(JSON.stringify(data).to_utf8_buffer())
	if peer != null:
		host._send(peer, b)
	else:
		host._broadcast(b)


func handle(p, type: int, b: StreamPeerBuffer) -> bool:
	if (
		type
		not in [
			NetPackets.CLIENT_PFLIT_ACTIVATE,
			NetPackets.CLIENT_VVVASE_BREAK,
			NetPackets.CLIENT_BRING_COLLECTED
		]
	):
		return false
	# Ability rings share the original collect opcode, but not map ring IDs.
	if type == NetPackets.CLIENT_BRING_COLLECTED:
		if b.get_available_bytes() < 2:
			return false
		var at = b.get_position()
		var id = b.get_u16()
		b.seek(at)
		return false
	if p == null or host.server_state != host.S.GAMESTART or host.round_ending:
		return true
	return true


func tick():
	if host.round_ending:
		return
	age += 1
	tick_wood()
	if pending or age % 6 == 0:
		snapshot()
		pending = false
		events.clear()


func tick_wood():
	lantern_timer -= 1
	if lantern_timer <= 0:
		if lantern < 0:
			lantern = randi_range(0, 6)
			lantern_timer = randi_range(20, 21) * 60
			lantern_since = age
			event("lantern")
		else:
			lantern = -1
			lantern_timer = randi_range(7, 8) * 60
			pending = true
