extends "res://src/maps/shared/rules.gd"
## Echidna Ruins: authoritative map mechanics.
# Source-matched PF/VV/WD/MJ mechanics. Timers are fixed 60Hz, owned by server.
var age = 0
var rings: Dictionary = {}
var crystals = false
var crystal_timer = 600
var crystal_since = 0
var lava: Dictionary = {}
var judger = 0
var judger_timer = 600
var judger_since = 0
var shots: Dictionary = {}
var next_shot = 0
var events: Array = []
var pending = false
var damage_mode = 2


func alive(p: Dictionary) -> bool:
	return host.character_rules.alive(p) and p.get("position_ready", false)


func human(p: Dictionary) -> bool:
	return alive(p) and not host.character_rules.hunter(p)


func event(kind: String, at := Vector2.ZERO, owner := -1, extra: Dictionary = {}):
	var data = {"kind": kind, "x": at.x, "y": at.y, "owner": owner}
	data.merge(extra)
	events.append(data)
	pending = true


func reset():
	super.reset()
	age = 0

	rings.clear()

	shots.clear()
	events.clear()
	next_shot = 0
	pending = true

	crystals = false
	crystal_timer = 600
	crystal_since = 0
	judger = 0
	judger_timer = 600
	judger_since = 0
	lava = {"state": 0, "timer": 300, "sy": 1624.0, "y": 1624.0, "dist": 512.0, "speed": 0.0}
	for p in host.players.values():
		p.ruins_until = 0


func snapshot(peer: ENetPacketPeer = null) -> void:
	var inverted: Dictionary = {}
	for p in host.players.values():
		if p.get("ruins_until", 0) > age:
			inverted[str(p.nid)] = {
				"until": p.ruins_until,
				"x": p.get("ruins_x", p.last_x),
				"y": p.get("ruins_y", p.last_y)
			}
	var data = {
		"map": host.chosen_map,
		"age": age,
		"crystals": crystals,
		"crystal_since": crystal_since,
		"lava": lava,
		"judger": judger,
		"judger_since": judger_since,
		"shots": shots,
		"inverted": inverted,
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
	tick_ruins()
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


func platform_bounds() -> Rect2:
	var items = objects("obj_marijuna_lavaplatform")
	if items.is_empty() or lava.is_empty():
		return Rect2()
	return Rect2(items[0].position[0], lava.y, 160, 75)


func floor_at(at: Vector2) -> bool:
	return platform_bounds().has_point(at)


func tick_ruins():
	lava_step(lava, true)
	crystal_timer -= 1
	if crystal_timer <= 0:
		crystals = not crystals
		crystal_timer = randi_range(10, 14) * 60
		crystal_since = age
		event("crystal")
	for p in host.players.values():
		if not p.get("in_round", false) or not p.get("position_ready", false):
			continue
		if crystals and age - crystal_since >= 63 and age >= p.get("ruins_until", 0):
			for i in objects("obj_marijuna_crystal"):
				if body(p).intersects(rect(i)):
					p.ruins_until = age + 300
					p.ruins_x = i.position[0]
					p.ruins_y = i.position[1]
					event("invert", Vector2(i.position[0], i.position[1]), p.nid)
					var cue = host._pkt(NetPackets.CLIENT_SOUND_EMIT, true)
					cue.put_u16(p.nid)
					cue.put_u8(63)
					cue.put_u8(0)
					host._broadcast(cue, p.nid)
					break
		var platform = platform_bounds()
		if (
			p.last_y + 16 >= lava.y + 48
			and p.last_y <= lava.y + 672
			and p.last_x + 10 >= platform.position.x + 48
			and p.last_x <= platform.position.x + 113
		):
			hurt(p, 6, 1 if p.last_x >= platform.position.x + 80 else -1)
	judger_timer -= 1
	if judger_timer <= 0:
		judger = (judger + 1) % 3
		judger_timer = (
			120
			if judger == 1
			else randi_range(7, 8) * 60 if judger == 2 else randi_range(10, 14) * 60
		)
		judger_since = age
		event("judger")
	if judger == 2 and (age - judger_since) % 6 == 0:
		for i in objects("obj_marijuna_judger"):
			var direction = float(i.scale[0])
			shots[str(next_shot)] = {
				"x": i.position[0] + (30 if direction > 0 else -40),
				"y": i.position[1] - 4,
				"vx": direction * 4,
				"vy": randf_range(-0.3, 0.3),
				"life": randi_range(30, 50)
			}
			next_shot += 1
	for id in shots.keys():
		var shot: Dictionary = shots[id]
		shot.x += shot.vx
		shot.y += shot.vy
		shot.life -= 1
		for p in host.players.values():
			if (
				human(p)
				and body(p).intersects(
					Rect2(shot.x + (0 if shot.vx > 0 else -24), shot.y + 0, 24, 16)
				)
			):
				hurt(p)
		if shot.life <= 0:
			shots.erase(id)


func sync_simulation(world):
	for n in world.dynamic.values():
		n.set_meta("previous_y", n.position.y)
		if not lava.is_empty():
			n.position.y = lava.y


func input_buttons(p: Dictionary, held: int) -> int:
	if age >= p.get("ruins_until", 0):
		return held
	return (
		(held & ~15) | ((held & 1) << 1) | ((held & 2) >> 1) | ((held & 4) << 1) | ((held & 8) >> 1)
	)


func before_collision(actor: Node):
	if actor.get_meta("carry_frame", -1) == host._game_frame:
		return
	actor.set_meta("carry_frame", host._game_frame)
	for n in host.motion.world.dynamic.values():
		if n.gm_name != "obj_marijuna_lavaplatform":
			continue
		var box: Rect2 = n.bbox_rect()
		var previous_y: float = n.get_meta("previous_y", n.position.y)
		var change: float = n.position.y - previous_y
		if (
			actor.yspd >= 0
			and absf(actor.position.y + 18 - (box.position.y - change)) <= 6
			and actor.position.x >= box.position.x - 7
			and actor.position.x <= box.end.x + 7
		):
			actor.position.y += change
