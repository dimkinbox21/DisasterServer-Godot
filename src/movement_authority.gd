extends RefCounted
## Fixed 60 Hz input-only server simulation; clients never supply transforms.
const Maps = preload("res://src/data/maps.gd")
const Checkpoint = preload("res://src/net/movement_state.gd")
var host: Node
var world: Node
var revision := 0


func _init(server: Node):
	host = server


func reset():
	if is_instance_valid(world):
		world.free()
	world = load("res://src/simulation/world.gd").new()
	(
		host.add_child(world)
		if host.is_inside_tree()
		else (Engine.get_main_loop() as SceneTree).root.add_child(world)
	)
	world.setup(host)
	for p in host.players.values():
		var kind := "obj_exespawn" if p.char == 0 else "obj_spawnpoint"
		var items: Array = Maps.world_data(host.chosen_map).hazards.items
		var points := items.filter(func(i): return i.type == kind)
		if points.is_empty():
			points = items.filter(func(i): return i.type == "obj_spawnpoint")
		var at := Vector2.ZERO
		if not points.is_empty():
			var point: Dictionary = points.pick_random()
			at = Vector2(point.x, point.y - 18)
		p.last_x = at.x
		p.last_y = at.y
		p.motion_seq = 0
		p.motion_received = 0
		p.motion_epoch = 0
		p.motion_inputs = 0
		p.motion_queue = []
		p.motion_credit = 3.0
		p.motion_frame = host._game_frame
		p.motion_last_input = host._game_frame
		p.motion_velocity = Vector2.ZERO
		p.motion_known = at
		p.motion_previous = at
		p.slow_until = 0
		p.boosted = false
		p.attacking = false
		p.invisible = false
		for key in ["motion_impact", "motion_parry", "motion_stun"]:
			p.erase(key)
		world.spawn(p)
		send(p, true)


func queue_input(p: Dictionary, sequence: int, held: int) -> bool:
	if sequence <= p.get("motion_received", 0) or sequence > p.get("motion_received", 0) + 256:
		return false
	p.motion_received = sequence
	if p.get("motion_queue", []).size() >= 120:
		return false
	p.motion_queue.append([sequence, held & 2047])
	p.motion_last_input = host._game_frame
	p.position_ready = true
	return true


func tick():
	if not is_instance_valid(world):
		return
	world.sync_geometry()
	for n in world.objects.values():
		if n.is_in_group("obj_spring_parent"):
			n._gm_step()
	for p in host.players.values():
		if (
			not p.get("in_round", false)
			or not p.get("position_ready", false)
			or p.get("escaped", false)
		):
			continue
		var elapsed: int = maxi(0, host._game_frame - int(p.motion_frame))
		p.motion_frame = host._game_frame
		p.motion_credit = minf(8, float(p.motion_credit) + elapsed)
		p.motion_previous = Vector2(p.last_x, p.last_y)
		var actor = null
		var steps := 0
		while not p.motion_queue.is_empty() and p.motion_credit >= 1 and steps < 4:
			var input: Array = p.motion_queue.pop_front()
			p.motion_seq = input[0]
			var inputs: int = input[1]
			host.attacks.input(p, inputs)
			actor = world.step(p, inputs)
			host.health.check_player(p)
			p.motion_inputs = inputs
			p.motion_credit -= 1
			steps += 1
		# A short jitter buffer keeps one input frame equal to one physics step.
		# After a stalled client stops sending, the server releases its controls and continues gravity.
		if actor == null and host._game_frame - p.motion_last_input > 15:
			actor = world.step(p, 0)
			p.motion_inputs = 0
			p.motion_credit = maxf(0, float(p.motion_credit) - 1)
		if actor == null:
			continue
		p.motion_known = Vector2(p.last_x, p.last_y)
		p.boosted = actor.isBoosting
		if p.char in [2, 4, 6]:
			p.attacking = host.character_rules.melee_flags(
				p, actor.isAttacking or (p.char == 4 and actor.survivor.combat_attack())
			)

		for other in host.players.values():
			if other.nid != p.nid:
				host.character_rules.try_parry(p, other)
		send(p)
		relay(p, actor)


func send(p: Dictionary, force := false, peer: ENetPacketPeer = null):
	revision += 1
	var b: StreamPeerBuffer = host._pkt(NetPackets.SERVER_PLAYER_MOTION)
	b.put_u32(host.round_id)
	b.put_u32(p.get("motion_seq", 0))
	b.put_u16(p.nid)
	b.put_u16(p.get("motion_epoch", 0))
	b.put_float(p.last_x)
	b.put_float(p.last_y)
	var v: Vector2 = p.get("motion_velocity", Vector2.ZERO)
	b.put_float(v.x)
	b.put_float(v.y)
	b.put_u8(int(force))
	b.put_u8(6 if p.is_dead else p.get("move_state", 0))
	b.put_u32(revision)
	b.put_u32(p.get("health_revision", 0))
	b.put_u16(p.get("motion_inputs", 0))
	var actor = world.actors.get(p.nid) if is_instance_valid(world) else null
	var bytes := var_to_bytes(
		Checkpoint.capture(actor, p.get("exechar", 0)) if actor != null else []
	)
	b.put_u16(bytes.size())
	b.put_data(bytes)
	host._send(p.get("peer") if peer == null else peer, b)


func snapshot(peer: ENetPacketPeer):
	for p in host.players.values():
		if p.get("in_round", false):
			send(p, true, peer)


func warp(p: Dictionary, at: Vector2, reset_speed := true):
	p.last_x = at.x
	p.last_y = at.y
	p.motion_known = at
	p.motion_previous = at
	p.motion_epoch = int(p.get("motion_epoch", 0)) + 1
	if is_instance_valid(world) and world.actors.has(p.nid):
		var actor = world.actors[p.nid]
		actor.position = at
		actor.isGrounded = false
		if reset_speed:
			actor.xspd = 0
			actor.yspd = 0
			actor.gspd = 0
	if reset_speed:
		p.motion_velocity = Vector2.ZERO
	send(p, true)


func relay(p: Dictionary, actor: Node):
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.put_u8(1)
	b.put_u8(NetPackets.CLIENT_PLAYER_DATA)
	b.put_u16(p.nid)
	b.put_16(int(p.last_x))
	b.put_16(int(p.last_y))
	b.put_16(half_bits(actor.xspd))
	b.put_16(half_bits(actor.yspd))
	b.put_u8(p.move_state)
	b.put_16(int(actor.angle))
	b.put_u8(p.move_frame)
	b.put_8(p.facing)
	var flags := 0
	if p.attacking:
		flags |= NetPackets.PLAYER_ATTACKING
	if p.invisible:
		flags |= NetPackets.PLAYER_INVIS
	if p.hurttime > 0:
		flags |= NetPackets.PLAYER_HURT
	if p.red_ring > 0:
		flags |= NetPackets.PLAYER_REDRING
	if actor.effectTime > 0:
		flags |= NetPackets.PLAYER_EFFECT
	if p.char == 6 and actor.shieldTimer > 0:
		flags |= NetPackets.PLAYER_SALLYSHIELD
	if p.char == 0 and p.get("exechar", 0) == 1 and actor.hunter.slimeAnim:
		flags |= NetPackets.PLAYER_SLIME
	b.put_u8(flags)
	if p.char == 1:
		b.put_u8(actor.attackCharge)
		b.put_16(
			int(-rad_to_deg(atan2(actor.yspd, actor.gspd if actor.isGrounded else actor.xspd)))
		)
	host._broadcast(b, p.nid)


static func half_bits(value: float) -> int:
	var bytes := PackedByteArray()
	bytes.resize(2)
	bytes.encode_half(0, value)
	return bytes.decode_u16(0)


func owner_status(peer: ENetPacketPeer, data: PackedByteArray):
	if not is_instance_valid(world):
		return
	var actor: Node = null
	for p in host.players.values():
		if p.get("peer") == peer:
			actor = world.actors.get(p.nid)
			break
	if actor == null:
		return
	var b := StreamPeerBuffer.new()
	b.data_array = data
	b.seek(2)
	var kind := b.get_u8()
	var ticks := b.get_u16()
	match kind:
		2:
			actor.isAttacking = false
			actor.shieldRechrage = ticks
		5:
			actor.shieldTimer = ticks
			actor.shieldRechrage = b.get_u16()
		6:
			if actor.survivor != null:
				actor.survivor.absorb_damage()
			actor.shieldTimer = 0
			actor.hurttime = ticks
			var push := Vector2(b.get_8(), b.get_8())
			if push != Vector2.ZERO:
				actor.isGrounded = false
				actor.isHurt = true
				actor.isSliding = false
				actor.xspd = push.x
				actor.yspd = push.y
		7:
			var attack := b.get_u16()
			var slime := b.get_16()
			if ticks == 0 and actor.hunter != null:
				actor.hunter.reconcile(attack, slime)
		8:
			var attack := b.get_u16()
			var ring := b.get_u16()
			if ticks == 0 and actor.hunter != null:
				actor.hunter.reconcile(attack, ring)
		9:
			var attack := b.get_u16()
			var clones := b.get_u16()
			var ids := []
			for index in 2:
				var id := b.get_u16()
				ids.append(-1 if id == 65535 else id)
			var action := b.get_u8()
			if ticks == 0 and actor.hunter != null:
				actor.hunter.reconcile(attack, clones, ids, action)
