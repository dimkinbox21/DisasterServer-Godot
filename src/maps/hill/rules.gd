extends "res://src/maps/shared/rules.gd"
## Hill: authoritative map mechanics.
var thunder := false
var thunder_timer := 900


func reset():
	super.reset()
	thunder = false
	thunder_timer = randi_range(15, 19) * 60
	for p in host.players.values():
		p.boosted = false
		p.map_ray_until = 0


func emit(type: int, bytes: Array, peer: ENetPacketPeer = null):
	var b = host._pkt(type)
	for v in bytes:
		b.put_u8(v)
	if peer != null:
		host._send(peer, b)
	else:
		host._broadcast(b)


func snapshot(peer: ENetPacketPeer = null) -> void:
	emit(NetPackets.SERVER_GHZTHUNDER_STATE, [0 if thunder else 1], peer)


func handle(p, type: int, b: StreamPeerBuffer) -> bool:
	if type not in [NetPackets.CLIENT_KAFMONITOR_ACTIVATE, NetPackets.CLIENT_NAPICE_ACTIVATE]:
		return false
	if (
		host.server_state != host.S.GAMESTART
		or p == null
		or host.round_ending
		or not host.character_rules.alive(p)
		or not p.get("position_ready", false)
		or b.get_available_bytes() < 1
	):
		return true
	var id := b.get_u8()
	return true


func hazard(p: Dictionary):
	if p.hurttime > 0:
		return
	if host.character_rules.hunter(p):
		p.hurttime = 180
	else:
		host._apply_survivor_damage(p, 1)
	host.active_map.owner_stats(p, 2)


func tick():
	if host.round_ending:
		return
	thunder_timer -= 1
	if not thunder and thunder_timer <= 120:
		thunder = true
		emit(NetPackets.SERVER_GHZTHUNDER_STATE, [0])
	if thunder_timer <= 0:
		thunder = false
		thunder_timer = randi_range(15, 19) * 60
		emit(NetPackets.SERVER_GHZTHUNDER_STATE, [1])
	if thunder:
		for water in objects(12, "obj_ghz_water"):
			var bounds := rect(water)
			for p in host.players.values():
				if (
					host.character_rules.alive(p)
					and p.get("position_ready", false)
					and bounds.intersects(
						Rect2(Vector2(p.last_x - 6, p.last_y + 17), Vector2(12, 3))
					)
				):
					hazard(p)
