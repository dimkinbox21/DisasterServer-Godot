extends "res://src/maps/shared/rules.gd"
## Kind and Fair: authoritative map mechanics.
var broken: Dictionary = {}


func reset():
	super.reset()
	broken.clear()

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
	for id in broken:
		emit(NetPackets.SERVER_KAFMONITOR_STATE, [2, id, 255, 255], peer)


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
	if type == NetPackets.CLIENT_KAFMONITOR_ACTIVATE:
		var ray := b.get_u8() != 0 if b.get_available_bytes() > 0 else false
		for i in objects(7, "obj_kaf_speedboobster"):
			if int(i.properties.get("nid", 0)) != id or broken.has(id):
				continue
			var valid: bool = (
				body(p).grow(8).intersects(rect(i))
				and (
					p.get("attacking", false)
					or p.get("move_state", 0) in [3, 12]
					or (p.char == 4 and p.get("move_state", 0) in [4, 15])
					or (p.char == 6 and p.get("move_state", 0) == 16)
					or p.get("boosted", false)
				)
			)
			if ray:
				valid = projectile_near(p, rect(i))
			if not valid or p.get("invisible", false):
				continue
			broken[id] = 600
			p.boosted = true
			var packet = host._pkt(NetPackets.SERVER_KAFMONITOR_STATE)
			packet.put_u8(2)
			packet.put_u8(id)
			packet.put_u16(p.nid)
			host._broadcast(packet)
	return true


func projectile_near(p: Dictionary, area: Rect2) -> bool:
	if p.get("map_ray_until", 0) > host._game_frame:
		for elapsed in range(0, host._game_frame - int(p.map_ray_start) + 1):
			var at: Vector2 = p.map_ray_origin + Vector2(p.map_ray_dir * 14 * elapsed, 0)
			if area.grow(16).has_point(at):
				return true
			if host.character_rules.floor_at(at):
				return false
	return false


func tick():
	if host.round_ending:
		return
	for id in broken.keys():
		broken[id] -= 1
		if broken[id] <= 0:
			broken.erase(id)
			emit(NetPackets.SERVER_KAFMONITOR_STATE, [1, id])
