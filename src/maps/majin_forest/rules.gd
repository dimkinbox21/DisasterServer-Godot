extends "res://src/maps/shared/rules.gd"
## Majin Forest: authoritative map mechanics.
# Source objects + BetterServer DTTailsDoll/DTAss/DTBall/HDDoor state machines.
var age := 0
var events: Array = []
var pending := false


func reset():
	super.reset()
	age = 0

	events.clear()

	pending = true


func snapshot(peer: ENetPacketPeer = null) -> void:
	var data = {"map": host.chosen_map, "age": age, "events": events if peer == null else []}
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
	if not forest_player(p):
		return true
	if type == NetPackets.CLIENT_HDDOOR_TOGGLE:
		return true
	elif type == NetPackets.CLIENT_TOWER_INTERACT and b.get_available_bytes() >= 1:
		var kind := b.get_u8()
		if age < p.get("tower_tp_until", 0):
			return true
		if kind == 0 and (p.last_x <= 248 or p.last_x >= 3400):
			var x := 3408 if p.last_x < 1824 else 240
			# A special correction preserves speed/animation across the loop seam.
			var msg = host._pkt(NetPackets.SERVER_TOWER_WARP)
			msg.put_u16(x)
			msg.put_u16(p.last_y)
			msg.put_u8(0)
			host._send(p.peer, msg)
			host.motion.warp(p, Vector2(x, p.last_y), false)
			p.tower_tp_until = age + 6
		elif kind == 1:
			recover_forest(p)
	# Stalactite landing is server simulated; never trust a remote destroy request.
	return true


func forest_player(p: Dictionary) -> bool:
	# The source trigger also returns downed bodies; it does not require HP>0.
	return (
		p.get("in_round", false) and p.get("position_ready", false) and not p.get("escaped", false)
	)


func below_forest(p: Dictionary) -> bool:
	var bounds := body(p)
	for i in objects("obj_majong_trigger"):
		var zone := rect(i)
		# Keep recovery eligible below the thin strip. A cooldown or delayed packet
		# must not leave the actor permanently outside the room.
		if (
			bounds.end.y > zone.position.y
			and bounds.end.x > zone.position.x
			and bounds.position.x < zone.end.x
		):
			return true
	return false


func recover_forest(p: Dictionary):
	if not forest_player(p) or age < p.get("tower_tp_until", 0) or not below_forest(p):
		return
	var best: Dictionary = {}
	var distance := INF
	for point in objects("obj_majong_trigger_point"):
		var d := (
			Vector2(point.position[0] - p.last_x, point.position[1] - p.last_y).length_squared()
		)
		if d < distance:
			distance = d
			best = point
	if best.is_empty():
		return
	var msg = host._pkt(NetPackets.SERVER_TOWER_WARP)
	msg.put_u16(best.position[0])
	msg.put_u16(best.position[1])
	msg.put_u8(1)
	host._send(p.peer, msg)
	p.last_x = best.position[0]
	p.last_y = best.position[1]
	host.motion.warp(p, Vector2(p.last_x, p.last_y))
	p.tower_tp_until = age + 15


func tick_forest():
	for p in host.players.values():
		recover_forest(p)


func tick():
	if host.round_ending:
		return
	age += 1
	tick_forest()
	if pending or age % 6 == 0:
		snapshot()
		events.clear()
		pending = false


func simulation_interactions(world, p: Dictionary, actor):
	super.simulation_interactions(world, p, actor)
	if actor.position.x <= 248 or actor.position.x >= 3400:
		world.request(p, NetPackets.CLIENT_TOWER_INTERACT, 0)
