extends "res://src/maps/shared/rules.gd"
## Act 9: authoritative map mechanics.
## Original entity schedules recovered from BetterServer.exe, source-matched payloads.


func reset() -> void:
	total_ticks = maxi(1, host.game_ticks)


func snapshot(peer: ENetPacketPeer = null) -> void:
	walls(peer)


func walls(peer: ENetPacketPeer = null) -> void:
	var fraction := clampf(1.0 - host.game_ticks / float(total_ticks), 0, 1)
	for id in 3:
		var b: StreamPeerBuffer = host._pkt(NetPackets.SERVER_ACT9WALL_STATE)
		b.put_u8(id)
		b.put_u16(int(1663 * fraction) if id else 0)
		b.put_u16(int(1025 * fraction) if id == 0 else 0)
		if peer != null:
			host._send(peer, b)
		else:
			host._broadcast(b)


func crush(p: Dictionary) -> void:
	if not host.character_rules.alive(p) or not p.get("position_ready", false):
		return
	var fraction := clampf(1.0 - host.game_ticks / float(total_ticks), 0, 1)
	var left := 1663 * fraction
	var right := 3072 - left
	var ceiling := 1025 * fraction
	var at := Vector2(p.last_x, p.last_y)
	var crushed: bool = (
		at.y <= ceiling + 8
		or right - left < 16
		or (at.x - 8 <= left and host.character_rules.floor_at(Vector2(left + 16, at.y - 4)))
		or (at.x + 8 >= right and host.character_rules.floor_at(Vector2(right - 16, at.y - 4)))
	)
	if not crushed:
		return
	if not host.character_rules.hunter(p):
		p.hurttime = 0
		p.sally_shield_end = 0
		host._apply_survivor_damage(p, p.hp)
	teleport(p, Vector2(1535, 943))
	owner_stats(p, 1)


func tick() -> void:
	if host.round_ending:
		return
	if host._game_frame % 3 == 0:
		walls()
	for p in host.players.values():
		crush(p)


func sync_simulation(world):
	var fraction := clampf(1.0 - host.game_ticks / float(total_ticks), 0, 1)
	for n in world.dynamic.values():
		var id := int(n.properties.get("nid", 0))
		n.position = (
			Vector2(-2240, int(1025 * fraction) - 768)
			if id == 0
			else (
				Vector2(int(1663 * fraction) - 2240, 0)
				if id == 1
				else Vector2(3072 - int(1663 * fraction), 0)
			)
		)


func after_actor(actor, _p: Dictionary):
	var fraction := clampf(1.0 - host.game_ticks / float(total_ticks), 0, 1)
	actor.position.x = clampf(
		actor.position.x, int(1663 * fraction) + 8, 3072 - int(1663 * fraction) - 8
	)
	actor.position.y = maxf(actor.position.y, int(1025 * fraction) + 16)
