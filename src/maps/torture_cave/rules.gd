extends "res://src/maps/shared/rules.gd"
## Torture Cave: authoritative map mechanics.
## Original entity schedules recovered from BetterServer.exe, source-matched payloads.
var acid_group := -1
var acid_on := false
var acid_frame := 0


func reset() -> void:
	acid_group = -1
	acid_on = false
	acid_frame = 0
	total_ticks = maxi(1, host.game_ticks)


func snapshot(peer: ENetPacketPeer = null) -> void:
	if acid_group >= 0:
		acid_packet(peer)


func acid_packet(peer: ENetPacketPeer = null) -> void:
	var b: StreamPeerBuffer = host._pkt(NetPackets.SERVER_TCGOM_STATE)
	b.put_u8(acid_group)
	b.put_u8(int(acid_on))
	if peer != null:
		host._send(peer, b)
	else:
		host._broadcast(b)


func acid_pool_overlaps(body: Rect2) -> bool:
	for asset in rooms.get("15", {}).get("assets", []):
		if asset.sprite != "spr_am_acid":
			continue
		var pool := Rect2(
			Vector2(asset.position[0], asset.position[1]),
			Vector2(256 * asset.scale[0], 256 * asset.scale[1])
		)
		if pool.intersects(body):
			return true
	return false


func tick() -> void:
	if host.round_ending:
		return
	acid_frame += 1
	if acid_frame >= 240:
		acid_frame = 0
		if not acid_on:
			acid_group = randi_range(0, 6)
		acid_on = not acid_on
		acid_packet()
	for p in host.players.values():
		if not host.character_rules.alive(p) or not p.get("position_ready", false):
			continue
		var collision := acid_pool_overlaps(
			Rect2(Vector2(p.last_x, p.last_y) - Vector2(8, 18), Vector2(16, 37))
		)
		if acid_on and acid_frame >= 54:
			for cloud in rooms.get("15", {}).get("instances", []):
				if (
					cloud.object != "obj_abadon_cloud"
					or int(cloud.properties.get("nid", 0)) != acid_group
				):
					continue
				var at := Vector2(cloud.position[0], cloud.position[1])
				var rect := Rect2(at + Vector2(-69, -120), Vector2(135, 120))
				if rect.intersects(
					Rect2(Vector2(p.last_x, p.last_y) - Vector2(8, 18), Vector2(16, 37))
				):
					collision = true
		if not collision:
			p.acid_timer = 6
			continue
		if p.get("acid_timer", 6) > 0:
			p.acid_timer = p.get("acid_timer", 6) - 1
			continue
		p.acid_timer = 36
		if p.rings > 0:
			p.rings -= 1
			owner_stats(p)
			var sound: StreamPeerBuffer = host._pkt(NetPackets.CLIENT_SOUND_EMIT, true)
			sound.put_u16(p.nid)
			sound.put_u8(32)
			sound.put_u8(0)
			host._broadcast(sound, p.nid)
		elif p.hurttime <= 0:
			if host.character_rules.hunter(p):
				p.hurttime = 180
			else:
				host._apply_survivor_damage(p, 1)
			owner_stats(p, 2)
