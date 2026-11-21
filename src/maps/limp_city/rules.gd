extends "res://src/maps/shared/rules.gd"
## Limp City: authoritative map mechanics.
# Authoritative state for Ravine Mist, You Can't Run and Limp City.
var age := 0
var chain := 2
var chain_timer := 480
var eyes: Dictionary = {}
var pending := false


func reset():
	super.reset()
	age = 0

	chain = 2
	chain_timer = 480

	eyes.clear()

	pending = true
	for i in objects("obj_limpcity_eyeA"):
		eyes[int(i.properties.nid)] = {
			"used": false,
			"owner": -1,
			"target": int(i.properties.target1),
			"charge": 100,
			"cooldown": 0,
			"timer": 0
		}


func living(p: Dictionary) -> bool:
	return (
		host.character_rules.alive(p)
		and not host.character_rules.hunter(p)
		and p.get("position_ready", false)
	)


func release(p: Dictionary):
	for eye in eyes.values():
		if eye.owner == p.nid:
			eye.used = false
			eye.owner = -1
			pending = true


func damage(p: Dictionary):
	if not living(p) or p.hurttime > 0:
		return
	host._apply_survivor_damage(p, 1)
	host.active_map.owner_stats(p, 2)


func snapshot(peer: ENetPacketPeer = null) -> void:
	var data = {"map": host.chosen_map, "age": age, "chain": chain, "eyes": eyes}
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
		if b.get_available_bytes() < 3:
			return true
		var active := b.get_u8() != 0
		var id := b.get_u8()
		var target := b.get_u8()
		if not eyes.has(id):
			return true
		var eye: Dictionary = eyes[id]
		if not active:
			if eye.owner == p.nid:
				release(p)
			return true
		if not living(p) or eye.used or eye.charge < 20 or eye.cooldown > 0 or p.hurttime > 0:
			return true
		for item in objects("obj_limpcity_eyeA"):
			if int(item.properties.nid) != id:
				continue
			if (
				target not in [int(item.properties.target1), int(item.properties.target2)]
				or not body(p).grow(12).intersects(rect(item))
			):
				return true
			release(p)
			eye.used = true
			eye.owner = p.nid
			eye.target = target
			eye.timer = 0
			pending = true
	# Landing is simulated on the server; clients cannot move a shard.
	return true


func tick():
	if host.round_ending:
		return
	age += 1
	tick_city()
	if pending or age % 6 == 0:
		snapshot()
		pending = false


func tick_city():
	chain_timer -= 1
	if chain_timer <= 0:
		chain = 0 if chain == 2 else (1 if chain == 0 else 2)
		chain_timer = 480 if chain == 2 else 120
		pending = true
	for eye_id in eyes:
		var eye: Dictionary = eyes[eye_id]
		eye.cooldown = maxi(0, eye.cooldown - 1)
		eye.timer += 1
		if eye.used:
			if not host.players.has(eye.owner):
				eye.used = false
				eye.owner = -1
				pending = true
			else:
				var p: Dictionary = host.players[eye.owner]
				var touching := false
				for item in objects("obj_limpcity_eyeA"):
					if (
						int(item.properties.nid) == int(eye_id)
						and body(p).grow(16).intersects(rect(item))
					):
						touching = true
				if not living(p) or p.hurttime > 0 or not touching:
					eye.used = false
					eye.owner = -1
					pending = true
		if eye.timer >= 60:
			eye.timer = 0
			if eye.used:
				eye.charge = maxi(0, eye.charge - 20)
				if eye.charge < 20:
					eye.used = false
					eye.owner = -1
					eye.cooldown = 120
			elif eye.cooldown <= 0:
				eye.charge = mini(100, eye.charge + 10)
	if chain == 1:
		for p in host.players.values():
			if not living(p):
				continue
			for i in objects("obj_limpcity_echain1") + objects("obj_limpcity_echain2"):
				if body(p).intersects(rect(i)):
					damage(p)
