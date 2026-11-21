extends "res://src/maps/shared/rules.gd"
## Ravine Mist: authoritative map mechanics.
# Authoritative state for Ravine Mist, You Can't Run and Limp City.
const SHARD_POINTS := [
	[862, 248],
	[3078, 248],
	[292, 558],
	[2918, 558],
	[1100, 820],
	[980, 1188],
	[1870, 1252],
	[2180, 1508],
	[2920, 2216],
	[282, 2228],
	[1318, 1916],
	[3010, 1766]
]
const SLUG_POINTS := [
	[1901, 392],
	[2193, 392],
	[2468, 392],
	[1188, 860],
	[2577, 1952],
	[2564, 2264],
	[2782, 2264],
	[1441, 2264],
	[884, 2264],
	[988, 2004],
	[915, 2004]
]
var age := 0
var shards: Dictionary = {}
var slugs: Dictionary = {}
var next_shard := 0
var pending := false


func reset():
	super.reset()
	age = 0

	shards.clear()
	slugs.clear()

	pending = true
	var points := SHARD_POINTS.duplicate()
	points.shuffle()
	for i in 7:
		shards[i] = {"x": points[i][0], "y": points[i][1], "owner": -1, "fall": false, "vy": 0.0}
		next_shard += 1
	for i in SLUG_POINTS.size():
		var at: Array = SLUG_POINTS[i]
		slugs[i] = {
			"x": float(at[0]),
			"y": at[1],
			"origin": at[0],
			"state": 0,
			"timer": 900 + randi_range(0, 9) * 60,
			"active": false,
			"eaten": 0,
			"born": 0
		}


func living(p: Dictionary) -> bool:
	return (
		host.character_rules.alive(p)
		and not host.character_rules.hunter(p)
		and p.get("position_ready", false)
	)


func collected() -> int:
	var count := 0
	for s in shards.values():
		if s.owner >= 0:
			count += 1
	return count


func can_escape() -> bool:
	return collected() >= 6


func drop(p: Dictionary):
	for s in shards.values():
		if s.owner == p.nid:
			s.owner = -1
			s.x = p.last_x + randi_range(-8, 8)
			s.y = p.last_y - 12
			s.vy = -2.0
			s.fall = true
			pending = true


func damage(p: Dictionary):
	if not living(p) or p.hurttime > 0:
		return
	host._apply_survivor_damage(p, 1)
	host.active_map.owner_stats(p, 2)


func snapshot(peer: ENetPacketPeer = null) -> void:
	var data = {
		"map": host.chosen_map, "age": age, "shards": shards, "slugs": slugs, "count": collected()
	}
	var raw := JSON.stringify(data).to_utf8_buffer()
	var packet = host._pkt(NetPackets.SERVER_CITY_STATE)
	packet.put_data(raw)
	if peer != null:
		host._send(peer, packet)
	else:
		host._broadcast(packet)


func handle(p, type: int, b: StreamPeerBuffer) -> bool:
	if (
		type
		not in [
			NetPackets.CLIENT_RMZSLIME_HIT,
			NetPackets.CLIENT_RMZSHARD_COLLECT,
			NetPackets.CLIENT_LCEYE_REQUEST_ACTIVATE,
			NetPackets.CLIENT_RMZSHARD_LAND
		]
	):
		return false
	if p == null or host.server_state != host.S.GAMESTART or host.round_ending:
		return true
	if type == NetPackets.CLIENT_LCEYE_REQUEST_ACTIVATE:
		return true
	elif (
		host.character_rules.alive(p)
		and p.get("position_ready", false)
		and (b.get_available_bytes() >= 2)
	):
		var id := b.get_u16()
		if type == NetPackets.CLIENT_RMZSHARD_COLLECT and living(p) and shards.has(id):
			var s: Dictionary = shards[id]
			if s.owner < 0 and body(p).grow(4).intersects(Rect2(s.x - 7, s.y - 7, 15, 29)):
				s.owner = p.nid
				s.fall = false
				pending = true
				host._stat(p, "shards", 1)
		elif type == NetPackets.CLIENT_RMZSLIME_HIT and slugs.has(id):
			var slug: Dictionary = slugs[id]
			var box := Rect2(slug.x - 13, slug.y - 18, 27, 19)
			var projectile := b.get_u8() != 0 if b.get_available_bytes() > 0 else false
			var hit: bool = (
				body(p).grow(8).intersects(box)
				and (p.get("attacking", false) or p.get("move_state", 0) in [3, 12, 15, 16])
			)
			if projectile:
				hit = projectile_near(p, box)
			if slug.active and age - slug.born >= 60 and hit:
				slug.active = false
				slug.timer = 900
				pending = true
				if living(p) and slug.eaten > 0:
					var red: bool = int(slug.state) >= 4
					var heal := false
					if red and p.red_ring <= 0:
						p.red_ring = 600
						host.character_rules.status(p, 10, 600)
					elif not red:
						p.rings += 1
						if p.red_ring >= 60:
							p.red_ring = maxi(
								60, p.red_ring - (120 if host.game_ticks < 3600 else 30)
							)
						if p.rings >= 10 and p.hp < 5 and p.get("heal_cd", 0) <= 0:
							p.hp += 1
							p.rings = 0
							p.heal_cd = 30
							heal = true
						host.active_map.owner_stats(p)
					var bonus = host._pkt(NetPackets.SERVER_RMZSLIME_RINGBONUS)
					bonus.put_u8(int(red))
					bonus.put_u8(int(heal))
					host._send(p.peer, bonus)
					slug.eaten = 0
	# Landing is simulated on the server; clients cannot move a shard.
	return true


func tick():
	if host.round_ending:
		return
	age += 1
	tick_ravine()
	if pending or age % 6 == 0:
		snapshot()
		pending = false


func tick_ravine():
	for s in shards.values():
		if s.owner >= 0:
			if not host.players.has(s.owner):
				s.owner = -1
				s.fall = true
				pending = true
			elif (
				not living(host.players[s.owner])
				and not host.players[s.owner].get("escaped", false)
			):
				drop(host.players[s.owner])
			else:
				s.x = host.players[s.owner].last_x
				s.y = host.players[s.owner].last_y - 12
		if s.owner < 0 and s.fall:
			s.vy = minf(6, s.vy + 0.16)
			for step in ceili(absf(s.vy)):
				var direction := signf(s.vy)
				if (
					direction > 0
					and (
						host.character_rules.floor_at(Vector2(s.x - 7, s.y + 21))
						or host.character_rules.floor_at(Vector2(s.x + 7, s.y + 21))
					)
				):
					s.fall = false
					break
				s.y += direction * minf(1, absf(s.vy) - step)
			if s.y > rooms["1"].height:
				s.y = SHARD_POINTS[0][1]
				s.x = SHARD_POINTS[0][0]
				s.fall = false
	for slug in slugs.values():
		if not slug.active:
			slug.timer -= 1
			if slug.timer <= 0:
				var cargo := slug_cargo(randi_range(0, 99))
				slug.active = true
				slug.x = float(slug.origin)
				slug.state = cargo * 2 + randi_range(0, 1)
				slug.eaten = int(cargo > 0)
				slug.born = age
				pending = true
			continue
		slug.x += 1 if int(slug.state) % 2 == 0 else -1
		if slug.x >= slug.origin + 100:
			slug.state = int(slug.state) | 1
		elif slug.x <= slug.origin - 100:
			slug.state = int(slug.state) & ~1
		if age - slug.born < 60:
			continue
		for p in host.players.values():
			if not living(p):
				continue
			if body(p).intersects(Rect2(slug.x - 13, slug.y - 18, 27, 19)) and age % 10 == 0:
				if p.get("attacking", false) or p.get("move_state", 0) in [3, 12, 15, 16]:
					continue
				if p.rings > 0:
					consume_ring(p)
				else:
					damage(p)


func projectile_near(p: Dictionary, area: Rect2) -> bool:
	if super.projectile_near(p, area):
		return true
	if host.get("exetior_rules") == null:
		return false
	for wave in host.exetior_rules.waves:
		if wave.owner != p.nid:
			continue
		var ticks: int = host._game_frame - wave.born
		for direction in [-1, 1]:
			if wave.stopped.has(direction):
				continue
			var at: Vector2 = wave.at + Vector2(direction * (25 if ticks < 10 else 50), 19)
			if Rect2(at + Vector2(-3 if direction > 0 else -18, -14), Vector2(22, 20)).intersects(
				area
			):
				return true
	return false


func consume_ring(p: Dictionary):
	p.rings -= 1
	host.active_map.owner_stats(p, 5)
	var sound = host._pkt(NetPackets.CLIENT_SOUND_EMIT, true)
	sound.put_u16(p.nid)
	sound.put_u8(32)
	sound.put_u8(0)
	host._broadcast(sound, p.nid)


# RMZSlug.c spawn: 0..49 empty, 50..89 normal ring, 90..99 red ring.


static func slug_cargo(roll: int) -> int:
	return 0 if roll < 50 else (1 if roll < 90 else 2)
