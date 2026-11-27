extends "res://src/maps/shared/rules.gd"
## You Can't Run: authoritative map mechanics.
# Authoritative state for Ravine Mist, You Can't Run and Limp City.
var age := 0
var spike := 0
var spike_timer := 120
var gas_id := -1
var gas_phase := 0
var gas_timer := 60
var pending := false


func reset():
	super.reset()
	age = 0
	spike = 0
	spike_timer = 120

	gas_id = -1
	gas_phase = 0
	gas_timer = 60

	pending = true


func living(p: Dictionary) -> bool:
	return (
		host.character_rules.alive(p)
		and not host.character_rules.hunter(p)
		and p.get("position_ready", false)
	)


func damage(p: Dictionary):
	if not living(p) or p.hurttime > 0:
		return
	host._apply_survivor_damage(p, 1)
	host.active_map.owner_stats(p, 2)


func snapshot(peer: ENetPacketPeer = null) -> void:
	var data = {
		"map": host.chosen_map, "age": age, "spike": spike, "gas_id": gas_id, "gas_phase": gas_phase
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
	# Landing is simulated on the server; clients cannot move a shard.
	return true


func tick():
	if host.round_ending:
		return
	age += 1
	tick_ycr()
	if pending or age % 6 == 0:
		snapshot()
		pending = false


func tick_ycr():
	spike_timer -= 1
	if spike_timer <= 0:
		spike = (spike + 1) % 6
		spike_timer = 120 if spike in [0, 2] else 1
		pending = true
	gas_timer -= 1
	if gas_timer <= 0:
		if gas_phase == 0:
			gas_phase = 1
			gas_timer = 300
		else:
			gas_phase = 0
			gas_timer = 60
			gas_id = randi_range(0, 6) if gas_id < 0 else -1
		pending = true
	for p in host.players.values():
		if not living(p):
			continue
		if spike in [1, 2, 3, 4]:
			for i in objects("obj_movingspike"):
				if body(p).intersects(Rect2(i.position[0], i.position[1], 32, 32)):
					damage(p)
		# Each original smokearea keeps its own exposure timer. Overlapping smoke
		# tiles belong to that area even where their last tile crosses its bounds.
		var timers: Dictionary = p.get("city_gas_timers", {})
		for area in objects("obj_ycr_smokearea"):
			var bounds := rect(area)
			var smoke_bounds := Rect2(
				bounds.position,
				Vector2(ceilf(bounds.size.x / 228) * 228, ceilf(bounds.size.y / 178) * 178)
			)
			var inside: bool = (
				gas_id >= 0
				and int(area.properties.nid) == gas_id
				and smoke_bounds.intersects(body(p))
			)
			var timer: int = timers.get(area.name, -60)
			if inside:
				if timer >= 60:
					timer = 0
					if p.rings > 0:
						consume_ring(p)
					else:
						damage(p)
				if timer >= 0 and p.red_ring <= 0:
					p.red_ring = 180
					host.character_rules.status(p, 10, 180)
				timer += 1
			else:
				timer = -60
			timers[area.name] = timer
		p.city_gas_timers = timers


func consume_ring(p: Dictionary):
	p.rings -= 1
	host.active_map.owner_stats(p, 5)
	var sound = host._pkt(NetPackets.CLIENT_SOUND_EMIT, true)
	sound.put_u16(p.nid)
	sound.put_u8(32)
	sound.put_u8(0)
	host._broadcast(sound, p.nid)


# RMZSlug.c spawn: 0..49 empty, 50..89 normal ring, 90..99 red ring.


func moving_spike_frame() -> int:
	return spike


func sync_simulation(world):
	for n in world.dynamic.values():
		n.set_spike_frame(spike)
