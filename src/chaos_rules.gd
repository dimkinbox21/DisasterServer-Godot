extends RefCounted
## Chaos ability requests, cooldowns and damage windows are server-owned.
var host: Node


func _init(server: Node):
	host = server


func is_chaos(p: Dictionary) -> bool:
	return p.get("char", -1) == 0 and p.get("exechar", -1) == 1


func reset_player(p: Dictionary):
	for key in [
		"chaos_ready",
		"chaos_attack_end",
		"chaos_contact_end",
		"chaos_stuck_end",
		"chaos_slime_end",
		"chaos_slime_ready",
		"chaos_kind"
	]:
		p[key] = 0


func valid(p: Dictionary) -> bool:
	return (
		is_chaos(p)
		and host.server_state == host.S.GAMESTART
		and not host.round_ending
		and host.character_rules.valid_action(p, 0)
		and p.get("move_state", 0) != 20
	)


func slime(p: Dictionary) -> bool:
	return p.get("chaos_slime_end", 0) > host._game_frame


func attack(p: Dictionary) -> bool:
	return (
		valid(p)
		and not slime(p)
		and p.get("chaos_attack_end", 0) > host._game_frame
		and p.get("chaos_stuck_end", 0) <= host._game_frame
	)


func can_hit(p: Dictionary, target: Dictionary) -> bool:
	return (
		valid(p)
		and not slime(p)
		and host.character_rules.pos(p).distance_to(host.character_rules.pos(target)) <= 64
		and (attack(p) or p.get("move_state", 0) in [3, 12])
	)


func reply(p: Dictionary, accepted: bool):
	var b: StreamPeerBuffer = host._pkt(NetPackets.SERVER_CHARACTER_STATUS)
	b.put_u8(7)
	b.put_u16(int(accepted))
	b.put_u16(maxi(0, p.get("chaos_ready", 0) - host._game_frame))
	var timer: int = (
		p.get("chaos_slime_end", 0) - host._game_frame
		if slime(p)
		else maxi(-1200, p.get("chaos_slime_ready", 0) - host._game_frame - 1200)
	)
	b.put_16(timer)
	host._send(p.peer, b)


func surface(at: Vector2, direction: Vector2) -> bool:
	for offset in range(-6, 7):
		# The client's wall sensors look ahead by maxHSpeed + 1 pixels.
		for distance in [18] if direction.y > 0 else range(8, 23):
			var point := (
				at + Vector2(offset, distance)
				if direction.y > 0
				else at + Vector2(direction.x * distance, offset)
			)
			if direction.y > 0 and host.character_rules.floor_at(point):
				return true
			if host.chosen_map == 8:
				var fraction := clampf(
					1.0 - host.game_ticks / float(host.active_map.total_ticks), 0, 1
				)
				var dx := int(1663 * fraction)
				var dy := int(1025 * fraction)
				for box in [
					Rect2(-2240, dy - 768, 7552, 768),
					Rect2(dx - 2240, 0, 2240, 1248),
					Rect2(3072 - dx, 0, 2240, 1248)
				]:
					if box.has_point(point):
						return true
			for g in host.character_rules.geometry.get(str(host.chosen_map), []):
				if g.group != "floor":
					continue
				if direction.y == 0 and (not g.get("can_stuck", true) or g.get("one_way", false)):
					continue
				if host.character_rules.mask_contains(g, point):
					return true
	return false


func handle(p, packet: int, rb: StreamPeerBuffer) -> bool:
	if packet != NetPackets.CLIENT_CHAOS_ACTION:
		return false
	if p == null or rb.get_available_bytes() < 7:
		return true
	var action := rb.get_u8()
	var direction := Vector2(rb.get_8(), rb.get_8())
	var at := Vector2(rb.get_16(), rb.get_16())
	if not is_chaos(p):
		return true
	var now: int = host._game_frame
	var accepted := false
	if valid(p):
		match action:
			0, 1:
				if (
					not slime(p)
					and p.get("chaos_ready", 0) <= now
					and p.get("chaos_stuck_end", 0) <= now
					and absf(direction.x) == 1
					and absf(direction.y) <= 1
				):
					var ground: bool = host.character_rules.grounded(p)
					if ground == (action == 0):
						p.chaos_ready = now + (90 if ground else 150)
						p.chaos_attack_end = now + (13 if ground else 15)
						p.chaos_contact_end = now + (0 if ground else 24)
						accepted = true
			2:
				if slime(p):
					if p.chaos_slime_end - now <= 890:
						p.chaos_slime_end = 0
						p.chaos_slime_ready = now + 1200
						accepted = true
				elif p.get("chaos_slime_ready", 0) <= now:
					p.chaos_slime_end = now + 900
					p.chaos_slime_ready = now + 2100
					p.chaos_attack_end = 0
					p.chaos_stuck_end = 0
					accepted = true
			5:
				if (
					not slime(p)
					and p.get("chaos_contact_end", 0) > now
					and p.get("chaos_stuck_end", 0) <= now
					and direction in [Vector2.LEFT, Vector2.RIGHT, Vector2.DOWN]
					and at.distance_to(host.character_rules.pos(p)) <= 100
					and surface(at, direction)
				):
					p.chaos_stuck_end = now + 30
					p.chaos_kind = 1 if direction.y > 0 else 2
					p.chaos_contact_end = 0
					p.chaos_attack_end = 0
					accepted = true
			3, 4:
				if (
					not slime(p)
					and p.get("chaos_stuck_end", 0) - now >= 15
					and p.get("chaos_kind", 0) == (2 if action == 3 else 1)
				):
					p.chaos_stuck_end = 0
					p.chaos_kind = 0
					p.chaos_attack_end = now + (15 if action == 3 else 8)
					if action == 3:
						p.chaos_ready = now + 150
					accepted = true
	if accepted and action in [0, 1, 3, 4]:
		host.profile_rules.event(p, "dash_start")
	reply(p, accepted)
	return true


func flags(p: Dictionary, requested: int) -> int:
	var result: int = (
		requested
		& ~(NetPackets.PLAYER_ATTACKING | NetPackets.PLAYER_INVIS | NetPackets.PLAYER_SLIME)
	)
	if attack(p) and requested & NetPackets.PLAYER_ATTACKING:
		result |= NetPackets.PLAYER_ATTACKING
	if slime(p) and requested & NetPackets.PLAYER_SLIME:
		result |= NetPackets.PLAYER_SLIME
	return result


func tick():
	for p in host.players.values():
		if not is_chaos(p):
			continue
		if p.get("chaos_slime_end", 0) > 0 and p.chaos_slime_end <= host._game_frame:
			p.chaos_slime_end = 0
			reply(p, false)
		if p.get("chaos_stuck_end", 0) > host._game_frame:
			p.chaos_ready += 1
		if (
			not valid(p)
			and (
				slime(p)
				or p.get("chaos_attack_end", 0) > host._game_frame
				or p.get("chaos_stuck_end", 0) > host._game_frame
			)
		):
			if slime(p):
				p.chaos_slime_end = 0
				p.chaos_slime_ready = host._game_frame + 1200
			p.chaos_attack_end = 0
			p.chaos_stuck_end = 0
			p.chaos_contact_end = 0
			p.attacking = false
			reply(p, false)
