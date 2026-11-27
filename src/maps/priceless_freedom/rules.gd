extends "res://src/maps/shared/rules.gd"
## Priceless Freedom: authoritative map mechanics.
# Source-matched PF/VV/WD/MJ mechanics. Timers are fixed 60Hz, owned by server.
const LIFT_ENDS = [1016, 704, 400, 544]
var age = 0
var lifts: Dictionary = {}
var rings: Dictionary = {}
var events: Array = []
var pending = false


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
	lifts.clear()
	rings.clear()

	events.clear()

	pending = true

	for p in host.players.values():
		p.ruins_until = 0
	for i in objects("obj_pf_lift"):
		var id = int(i.properties.nid)
		lifts[str(id)] = {
			"x": float(i.position[0]),
			"y": float(i.position[1]),
			"sy": float(i.position[1]),
			"end": LIFT_ENDS[id],
			"owner": -1,
			"speed": 0.0,
			"cooldown": 0,
			"ready": 63
		}
	var points = objects("obj_blackring_spawner")
	for id in points.size():
		rings[str(40000 + id)] = {
			"x": points[id].position[0], "y": points[id].position[1], "active": true
		}


func snapshot(peer: ENetPacketPeer = null) -> void:
	var data = {
		"map": host.chosen_map,
		"age": age,
		"lifts": lifts,
		"rings": rings,
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
		if not rings.has(str(id)):
			return false
	if p == null or host.server_state != host.S.GAMESTART or host.round_ending:
		return true
	if type == NetPackets.CLIENT_PFLIT_ACTIVATE and alive(p) and (b.get_available_bytes() > 0):
		var id = str(b.get_u8())
		if not lifts.has(id):
			return true
		var lift: Dictionary = lifts[id]
		if age < int(lift.ready) or lift.cooldown > 0 or lift.owner >= 0:
			return true
		for other in lifts.values():
			if other.owner == p.nid:
				return true
		if body(p).intersects(Rect2(lift.x - 16, lift.y - 7, 32, 15)):
			lift.owner = p.nid
			lift.speed = 0.0
			p.last_x = lift.x
			p.last_y = lift.y - 16
			event("lift_start", Vector2(lift.x, lift.y), -1, {"id": int(id)})
	elif type == NetPackets.CLIENT_BRING_COLLECTED and human(p):
		var id = str(b.get_u16())
		var ring: Dictionary = rings[id]
		if (
			not ring.active
			or age < 30
			or not host.exetior_rules.pickup_body(p).intersects(
				Rect2(ring.x + 7, ring.y + 7, 16, 16)
			)
		):
			return true
		host._stat(p, "black_rings", 1)
		ring.active = false
		if p.rings >= 5:
			p.rings -= 5
		else:
			p.hp = maxi(0, p.hp - 1)
			host._stat(p, "taken", 1)
			if p.hp == 0:
				p.is_dead = true
				p.dead_timer = 1860
				p.death_near = -1
				p.rings = 0
		host.active_map.owner_stats(p, 3)
		event("black_ring", Vector2(ring.x, ring.y), -1, {"id": int(id)})
	return true


func tick():
	if host.round_ending:
		return
	age += 1
	tick_lifts()
	if pending or age % 6 == 0:
		snapshot()
		pending = false
		events.clear()


func tick_lifts():
	for id in lifts:
		var lift: Dictionary = lifts[id]
		if lift.owner >= 0:
			var p: Dictionary = host.players.get(int(lift.owner), {})
			if p.is_empty() or not alive(p):
				lift.owner = -1
				lift.cooldown = 90
				pending = true
				continue
			lift.speed = minf(7, lift.speed + 0.052)
			lift.y = maxf(lift.end, lift.y - lift.speed)
			p.last_x = lift.x
			p.last_y = lift.y - 16
			if lift.y <= lift.end:
				var owner: int = lift.owner
				lift.owner = -1
				lift.cooldown = 90
				p.last_y = lift.end
				host.motion.warp(p, Vector2(lift.x, lift.end))
				if host.motion.world.actors.has(p.nid):
					host.motion.world.actors[p.nid].yspd = -3
					p.motion_velocity = Vector2(0, -3)
				event("lift_end", Vector2(lift.x, lift.y), -1, {"player": owner, "id": int(id)})
		elif lift.cooldown > 0:
			lift.cooldown -= 1
			if lift.cooldown == 0:
				lift.y = lift.sy
				lift.speed = 0.0
				lift.ready = age + 63
				event("lift_reset", Vector2(lift.x, lift.y), -1, {"id": int(id)})


func riding(p: Dictionary) -> Dictionary:
	for lift in lifts.values():
		if lift.owner == p.nid:
			return lift
	return {}


func before_actor(actor, p: Dictionary):
	var lift := riding(p)
	if not lift.is_empty():
		actor.Globals.playerControls = false
	elif actor.get_meta("riding", false):
		actor.Globals.playerControls = true
	actor.set_meta("riding", not lift.is_empty())


func after_actor(actor, p: Dictionary):
	var lift := riding(p)
	if lift.is_empty():
		return
	actor.position = Vector2(lift.x, lift.y - 16)
	actor.xspd = 0
	actor.yspd = 0
	actor.gspd = 0
	actor.isHurt = false
	actor.isFlying = false
	actor.isSpinning = false
	actor.isJumping = false
	actor.isGrounded = false
	actor.isAttacking = false
	actor.state = 5
	actor.apply_anim()
	actor.image_speed = 0.5


func simulation_interactions(world, p: Dictionary, actor):
	super.simulation_interactions(world, p, actor)
	simulation_requests(world, p, {"obj_pf_lift": NetPackets.CLIENT_PFLIT_ACTIVATE})
	for id in rings:
		world.request(p, NetPackets.CLIENT_BRING_COLLECTED, int(id), true)
