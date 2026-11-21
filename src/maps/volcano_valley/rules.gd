extends "res://src/maps/shared/rules.gd"
## Volcano Valley: authoritative map mechanics.
# Source-matched PF/VV/WD/MJ mechanics. Timers are fixed 60Hz, owned by server.
var age = 0
var rings: Dictionary = {}
var columns: Dictionary = {}
var vases: Dictionary = {}
var events: Array = []
var pending = false
var damage_mode = 2


func alive(p: Dictionary) -> bool:
	return host.character_rules.alive(p) and p.get("position_ready", false)


func human(p: Dictionary) -> bool:
	return alive(p) and not host.character_rules.hunter(p)


func event(kind: String, at := Vector2.ZERO, owner := -1, extra: Dictionary = {}):
	var data = {}
	data.merge(extra)
	events.append(data)
	pending = true


func reset():
	super.reset()
	age = 0

	rings.clear()
	columns.clear()
	vases.clear()

	events.clear()

	pending = true

	for p in host.players.values():
		p.ruins_until = 0
	for i in objects("obj_vv_lavacolumn"):
		columns[str(int(i.properties.nid))] = {
			"state": 0,
			"timer": randi_range(20, 29) * 60,
			"sy": float(i.position[1]),
			"y": float(i.position[1]),
			"dist": 130.0,
			"speed": 0.0
		}
	for i in objects("obj_vv_vase"):
		vases[str(int(i.properties.nid))] = false


func snapshot(peer: ENetPacketPeer = null) -> void:
	var data = {
		"map": host.chosen_map,
		"age": age,
		"columns": columns,
		"vases": vases,
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
	if type == NetPackets.CLIENT_VVVASE_BREAK and human(p) and (b.get_available_bytes() > 0):
		var id = str(b.get_u8())
		if not vases.has(id) or vases[id]:
			return true
		var attacking = (
			p.get("attacking", false)
			or p.get("move_state", 0) in [3, 4, 12]
			or (p.char in [4, 6] and p.get("move_state", 0) in [15, 16])
		)
		if not attacking:
			return true
		for i in objects("obj_vv_vase"):
			if str(int(i.properties.nid)) == id and body(p).intersects(rect(i)):
				vases[id] = true
				var count = randi_range(1, 4)
				p.rings += count
				if p.red_ring >= 60:
					p.red_ring = maxi(60, p.red_ring - (120 if host.game_ticks < 3600 else 30))
				var heal = p.rings >= 10 and p.hp < 5 and p.get("heal_cd", 0) <= 0
				if heal:
					p.rings -= 10
					p.hp += 1
					p.heal_cd = 30
					host._stat(p, "healed", 1)
				host.active_map.owner_stats(p)
				event(
					"vase",
					Vector2(i.position[0], i.position[1]),
					-1,
					{"id": int(id), "player": p.nid, "count": count, "heal": heal}
				)
				break
	return true


func hurt(p: Dictionary, mode := 2, push := 0):
	if not human(p) or p.hurttime > 0:
		return
	damage_mode = mode
	var hp: int = p.hp
	var rings_before: int = p.rings
	host._apply_survivor_damage(p, 1)
	if p.hp >= hp:
		return
	if mode == 6:
		var b = host._pkt(NetPackets.SERVER_MAP_DAMAGE)
		b.put_u8(6)
		b.put_8(p.hp)
		b.put_16(p.rings)
		b.put_u16(p.hurttime)
		b.put_u8(int(p.is_dead))
		b.put_8(push)
		host._send(p.peer, b)
	else:
		host.active_map.owner_stats(p, 2)
	var sound = host._pkt(NetPackets.CLIENT_SOUND_EMIT, true)
	sound.put_u16(p.nid)
	sound.put_u8(2 if p.hp <= 0 else 6 if rings_before > 0 else 62 if mode == 6 else 9)
	sound.put_u8(0)
	host._broadcast(sound, p.nid)


func tick():
	if host.round_ending:
		return
	age += 1
	tick_volcano()
	if pending or age % 6 == 0:
		snapshot()
		pending = false
		events.clear()


func lava_step(item: Dictionary, ruins: bool):
	var phase: int = item.state
	if phase in [0, 3]:
		item.y = item.sy - (item.dist if phase == 3 else 0) + sin(item.timer / 25.0) * 6
		item.timer -= 1
		if item.timer <= 0:
			item.state = 4 if phase == 3 else 1
			item.speed = 0.0
	elif phase == 1:
		item.y += 0.15
		if item.y >= item.sy + 20:
			item.state = 2
			item.speed = 0.0
	elif phase == 2:
		item.y -= item.speed
		item.speed = minf(5, item.speed + 0.08)
		if item.y <= item.sy - item.dist:
			item.state = 3
			item.timer = randi_range(4, 6) * 60
			item.speed = 0.0
	else:
		item.y += item.speed
		item.speed = minf(5, item.speed + 0.08)
		if item.y >= item.sy:
			item.state = 0
			item.timer = randi_range(5, 8) * 60 if ruins else randi_range(20, 24) * 60
			item.speed = 0.0


func tick_volcano():
	for item in columns.values():
		lava_step(item, false)
	for i in objects("obj_vv_lavacolumn"):
		var column: Dictionary = columns[str(int(i.properties.nid))]
		var high = str(i.properties.isHigh).to_lower() in ["true", "1"]
		var hazard = Rect2(i.position[0] - 31, column.y + 17, 64, (510 if high else 200) - 17)
		for p in host.players.values():
			if human(p) and body(p).intersects(hazard):
				hurt(p, 6, 1 if p.last_x >= i.position[0] else -1)
