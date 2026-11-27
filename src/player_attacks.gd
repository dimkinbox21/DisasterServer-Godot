extends RefCounted
## Server-owned hit tests, Tails charge/projectiles and classic Sonic action windows.
var host: Node
var shots := []


func body(p: Dictionary) -> Rect2:
	if is_instance_valid(host.motion.world):
		var actor = host.motion.world.actors.get(p.nid)
		if is_instance_valid(actor) and not actor.sprite_name.is_empty():
			return actor.bbox_rect()
	return host.exetior_rules.pickup_body(p)


func _init(server: Node):
	host = server


func reset():
	shots.clear()
	for p in host.players.values():
		p.tails_charge_start = -1
		p.tails_release = 0
		p.tails_ready = 0
		p.classic_attack_end = 0
		p.classic_attack_ready = 0
		p.classic_invis_end = 0
		p.classic_invis_ready = 0


func input(p: Dictionary, inputs: int):
	var previous: int = p.get("motion_inputs", 0)
	var pressed: int = inputs & ~previous
	var now: int = host._game_frame
	if not host.character_rules.alive(p) or p.get("stunned_ticks", 0) > 0:
		return
	if p.char == 1:
		if pressed & 32 and now >= p.get("tails_ready", 0):
			p.tails_charge_start = now
		if previous & 32 and not inputs & 32 and p.get("tails_charge_start", -1) >= 0:
			p.tails_release = now
	if p.char == 0 and p.get("exechar", 0) == 0:
		if pressed & 64:
			if p.get("classic_invis_end", 0) > now:
				p.classic_invis_end = now
				p.classic_invis_ready = now + 1200
			elif now >= p.get("classic_invis_ready", 0):
				p.classic_invis_end = now + 900
				p.classic_invis_ready = now + 2100
		if (
			pressed & 32
			and now >= p.get("classic_attack_ready", 0)
			and now >= p.get("classic_invis_end", 0)
		):
			var grounded: bool = p.get("move_state", 0) in [0, 1, 2, 7, 8, 13]
			p.classic_attack_end = now + (15 if grounded else 20)
			p.classic_attack_ready = now + (60 if grounded else 120)


func classic_flags(p: Dictionary, requested: int) -> int:
	var result: int = requested & ~(NetPackets.PLAYER_ATTACKING | NetPackets.PLAYER_INVIS)
	if p.get("classic_invis_end", 0) > host._game_frame:
		result |= NetPackets.PLAYER_INVIS
	elif p.get("classic_attack_end", 0) > host._game_frame and host.character_rules.alive(p):
		result |= NetPackets.PLAYER_ATTACKING
	return result


func handle(p, type: int, b: StreamPeerBuffer) -> bool:
	if type not in [NetPackets.CLIENT_TPROJECTILE, NetPackets.CLIENT_TPROJECTILE_HIT]:
		return false
	if type == NetPackets.CLIENT_TPROJECTILE_HIT:
		return true  # Client rendering cannot destroy the server projectile.
	if (
		p == null
		or host.server_state != host.S.GAMESTART
		or host.round_ending
		or p.char != 1
		or not host.character_rules.alive(p)
	):
		return true
	var started: int = p.get("tails_charge_start", -1)
	if (
		started < 0
		or host._game_frame < p.get("tails_ready", 0)
		or not p.get("position_ready", false)
	):
		return true
	var duration: int = clampi(
		(
			int(p.get("tails_release", 0)) - started
			if p.get("tails_release", 0) > started
			else host._game_frame - started
		),
		1,
		210
	)
	var demon: bool = p.revival >= 2
	var power: int = (
		(3 if duration >= 126 else 2 if duration >= 84 else 1)
		if demon
		else mini(6, 1 + duration / 42)
	)
	var shot := {
		"owner": p.nid,
		"at": Vector2(p.last_x, p.last_y),
		"direction": p.get("facing", 1),
		"power": power,
		"demon": demon,
		"tier": clampi(ceili(floorf(duration / 210.0 * 100.0) / 20.0), 0, 5),
		"life": 0
	}
	p.tails_charge_start = -1
	p.tails_ready = host._game_frame + (720 if demon else 1380)
	p.map_ray_origin = shot.at
	p.map_ray_dir = shot.direction
	p.map_ray_start = host._game_frame
	p.map_ray_until = host._game_frame + 300
	shots.append(shot)
	host._broadcast(packet(shot))
	return true


func packet(shot: Dictionary) -> StreamPeerBuffer:
	var b: StreamPeerBuffer = host._pkt(NetPackets.SERVER_TPROJECTILE_STATE)
	b.put_u8(0)
	b.put_u16(int(shot.at.x))
	b.put_u16(int(shot.at.y))
	b.put_u16(shot.owner)
	b.put_8(shot.direction)
	b.put_u8(shot.power)
	b.put_u8(int(shot.demon))
	b.put_u8(shot.tier)
	return b


func snapshot(peer: ENetPacketPeer):
	for shot in shots:
		host._send(peer, packet(shot))


func destroy(shot: Dictionary):
	shots.erase(shot)
	if host.players.has(shot.owner):
		host.players[shot.owner].map_ray_until = host._game_frame
	var b: StreamPeerBuffer = host._pkt(NetPackets.SERVER_TPROJECTILE_STATE)
	b.put_u8(2)
	host._broadcast(b)


func tick():
	tick_projectiles()
	tick_melee()


func tick_projectiles():
	for shot in shots.duplicate():
		shot.life += 1
		if shot.life > 300:
			destroy(shot)
			continue
		var hit := false
		for step in 4:
			shot.at.x += shot.direction * 3.5
			if host.chosen_map == 13:
				if shot.at.x < 0:
					shot.at.x = 3648.0
				elif shot.at.x > 3648:
					shot.at.x = 0.0
			if shot.at.x < 0 or host.character_rules.floor_at(shot.at):
				hit = true
				break
			var area := Rect2(
				shot.at + Vector2(-41 if shot.direction < 0 else 0, -3), Vector2(41, 8)
			)
			if shot.demon:
				host.rings.projectile(area)
			for p in host.players.values():
				if (
					p.nid == shot.owner
					or not host.character_rules.alive(p)
					or not p.get("position_ready", false)
					or p.hurttime > 0
					or host.character_rules.hunter(p) == shot.demon
					or p.get("invisible", false)
				):
					continue
				if not area.intersects(host.exetior_rules.pickup_body(p)):
					continue
				if shot.demon:
					host._apply_survivor_damage(p, shot.power, shot.owner)
				else:
					var ticks: int = shot.power * 60
					if not host.character_rules.break_sally_shield(
						p, Vector2(shot.direction * 4, -2)
					):
						p.hurttime = ticks + 120
						p.stunned_ticks = ticks
						p.motion_stun = shot.direction * 4
						var status: StreamPeerBuffer = host._pkt(NetPackets.SERVER_CHARACTER_STATUS)
						status.put_u8(3)
						status.put_u16(ticks)
						status.put_8(shot.direction * 4)
						host._send(p.peer, status)
						var relay: StreamPeerBuffer = host._pkt(NetPackets.CLIENT_PLAYER_HURT, true)
						relay.put_u16(p.nid)
						relay.put_u16(shot.owner)
						relay.put_u16(int(p.last_x))
						relay.put_u16(int(p.last_y))
						relay.put_u16(ticks)
						host._broadcast(relay, p.nid)
						if host.players.has(shot.owner):
							host._stat(host.players[shot.owner], "stuns", 1)
				hit = true
				break
			if hit:
				break
		if hit:
			destroy(shot)


func tick_melee():
	for victim in host.players.values():
		if (
			not host.character_rules.alive(victim)
			or not victim.get("position_ready", false)
			or victim.hurttime > 0
		):
			continue
		for attacker in host.players.values():
			if (
				attacker.nid == victim.nid
				or not host.character_rules.alive(attacker)
				or not attacker.get("position_ready", false)
			):
				continue
			if host.character_rules.hunter(attacker) == host.character_rules.hunter(victim):
				continue
			if not body(victim).intersects(body(attacker)):
				continue
			var spin: bool = attacker.get("move_state", 0) in [3, 12]
			var attack: bool = attacker.get("attacking", false)
			if host.character_rules.hunter(attacker):
				if not attack and not spin:
					continue
				if spin and not attack and victim.get("move_state", 0) in [3, 12]:
					continue
			elif not attack and not host.character_rules.shield(attacker):
				continue
			var b: StreamPeerBuffer = host._pkt(NetPackets.CLIENT_PLAYER_HURT)
			b.put_u16(attacker.nid)
			b.put_u16(int(victim.last_x))
			b.put_u16(int(victim.last_y))
			b.put_u16(
				0 if host.character_rules.hunter(attacker) else 120 if attacker.char == 3 else 180
			)
			host._process_packet(victim.peer, b.data_array, true)
			if victim.hurttime > 0 or victim.is_dead:
				break
