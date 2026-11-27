extends Node2D
## The same collision sensors and character controllers used for client prediction.
const Maps = preload("res://src/data/maps.gd")
const Actor = preload("res://src/simulation/generated/player.gd")
var host: Node
var sprites := SimulationSprites.new()
var actors := {}
var objects := {}
var dynamic := {}


func setup(server: Node):
	host = server
	var data := Maps.world_data(host.chosen_map)
	var source_records := {}
	for record in data.mechanics.get("instances", []):
		source_records[record.name] = record
	for i in data.get("simulation_objects", data.mechanics.get("instances", [])):
		var moving: bool = (
			i.object
			in [
				"obj_act9_wall",
				"obj_movingspike",
				"obj_hd_door",
				"obj_hd_door2",
				"obj_marijuna_lavaplatform",
				"obj_nap_iceblock"
			]
		)
		if (
			("obj_floor_parent" in i.parents or i.get("floor", false))
			and not moving
			and i.object not in ["obj_spike", "obj_weed_convejor"]
		):
			continue
		var n: SimulationNode
		if moving:
			n = load("res://src/simulation/dynamic_floor.gd").new()
			dynamic[i.name] = n
		elif "obj_spring_parent" in i.parents or i.object == "obj_hd_spring":
			n = load("res://src/simulation/generated/spring.gd").new()
			n.xdir = i.get("xdir", 0)
			n.ydir = i.get("ydir", -12)
			n.hold_sensitive = i.get("hold_sensitive", false)
		else:
			n = SimulationNode.new()
		n.GM = sprites
		n.Net = SimulationNetwork.new()
		n.Globals = SimulationGlobals.new()
		n.gm_name = i.object
		n.sprite_name = i.sprite
		n.position = Vector2(i.position[0], i.position[1])
		n.image_xscale = i.scale[0]
		n.image_yscale = i.scale[1]
		n.sprite_rotation = -i.rotation
		n.set_meta("source_name", i.name)
		n.properties = i.get("properties", {}).duplicate()
		n.properties.merge(source_records.get(i.name, {}).get("properties", {}), false)
		add_child(n)
		for group in i.parents:
			n.add_to_group(group)
		objects[i.name] = n
	for index in data.geometry.size():
		var g: Dictionary = data.geometry[index]
		if g.group != "floor":
			continue
		var n := SimulationFloor.new()
		n.GM = sprites
		n.sprite_name = "mask_%d" % index
		sprites.sprites[n.sprite_name] = {
			"w": g.l + g.w,
			"h": g.t + g.h,
			"bboxMode": 0,
			"bbox": [g.l, g.t, g.l + g.w - 1, g.t + g.h - 1],
			"xorigin": 0,
			"yorigin": 0,
			"count": 1
		}
		n.position = Vector2(g.x, g.y)
		n.image_xscale = g.sx
		n.image_yscale = g.sy
		n.sprite_rotation = rad_to_deg(g.rot)
		n.canStuck = g.can_stuck
		if g.one_way:
			n.add_to_group("gm_jumpthrough")
		add_child(n)
	SimulationFloor._grid_scene = null


func sync_geometry():
	host.active_map.sync_simulation(self)


func spawn(p: Dictionary) -> Node:
	var actor = Actor.new()
	actor.GM = sprites
	actor.Globals = SimulationGlobals.new()
	actor.Globals.character = p.char
	actor.Globals.exeCharacter = p.get("exechar", 0)
	actor.Net = SimulationNetwork.new()
	actor.Net.host = host
	actor.Net.player = p
	actor.Net.nid = p.nid
	actor.Net.lvlId = host.chosen_map
	actor.Net.effect_node = SimulationNode.new()
	add_child(actor.Net.effect_node)
	actor.position = Vector2(p.last_x, p.last_y)
	actor.pcharacter = p.char
	add_child(actor)
	actor.add_to_group("obj_player_puppet")
	var ziplines := []
	var container := Node2D.new()
	add_child(container)
	for source in objects.values():
		if source.gm_name != "obj_aiz_zipline":
			continue
		var zip = load("res://src/simulation/generated/maps/zipline.gd").new()
		zip.name = str(source.name)
		zip.set_meta("source_name", source.get_meta("source_name", str(source.name)))
		zip.GM = sprites
		zip.Globals = actor.Globals
		zip.Net = actor.Net
		zip.position = source.position
		zip.sprite_name = source.sprite_name
		zip.image_xscale = source.image_xscale
		zip.image_yscale = source.image_yscale
		zip.gid = int(source.properties.get("gid", 0))
		container.add_child(zip)
		ziplines.append(zip)
	actor.set_meta("simulation_zip_objects", ziplines)
	actors[p.nid] = actor
	return actor


func step(p: Dictionary, held: int, extra_pressed := 0):
	var actor = actors.get(p.nid)
	if actor == null:
		actor = spawn(p)
	actor.Globals.timeMinutes = host.game_ticks / 3600
	actor.Globals.timeSeconds = (host.game_ticks / 60) % 60
	actor.Globals.palleteName = p.get("palette_name", "default")
	actor.Net.gameEnds = host.round_ending
	held = host.active_map.input_buttons(p, held)
	actor.Net.pressed = (held & ~actor.Net.held) | extra_pressed
	actor.Net.released = actor.Net.held & ~held
	actor.Net.held = held
	if actor.position != Vector2(p.last_x, p.last_y):
		actor.position = Vector2(p.last_x, p.last_y)
		actor.isGrounded = false
	actor.hp = p.hp
	actor.rings = p.rings
	actor.revivalTimes = p.revival
	if actor.isDead != p.is_dead:
		if p.is_dead:
			actor.player_instakill(true)
		else:
			actor.isDead = false
			actor.isHurt = false
			actor.reset_character_abilities()
	actor.hurttime = p.hurttime
	actor.redRingTimer = p.red_ring
	actor.shockedTimer = p.get("stunned_ticks", 0)
	if p.has("motion_stun"):
		actor.xspd = p.motion_stun
		actor.yspd = -2
		actor.isGrounded = false
		p.erase("motion_stun")
	if p.has("motion_parry"):
		actor.apply_parry(p.motion_parry[0], p.motion_parry[1])
		p.erase("motion_parry")
	actor.isBoosting = p.get("boosted", false)
	if p.has("motion_impact"):
		var hit: Array = p.motion_impact
		actor.player_hurt(1, hit[1], hit[2], "snd_hurt", "spr_blood1", false, true)
		p.erase("motion_impact")
	if p.get("slow_until", 0) > host._game_frame:
		actor.apply_slow(int(p.slow_until) - host._game_frame + 1, 0.7 if p.char == 0 else 0.6)
	host.active_map.before_actor(actor, p)
	actor.advance_animation()
	actor._gm_step()
	for zip in actor.get_meta("simulation_zip_objects", []):
		if zip.hasPlayer:
			zip.camY = actor.position.y - 135
		zip._gm_step()
	host.active_map.after_actor(actor, p)
	if actor.effectTime > 0:
		actor.effectTime -= 1
	p.last_x = actor.position.x
	p.last_y = actor.position.y
	p.motion_velocity = Vector2(actor.xspd, actor.yspd)
	p.move_state = actor.state
	p.move_frame = int(actor.image_index)
	p.facing = -1 if actor.image_xscale < 0 else 1
	p.attacking = actor.isAttacking
	if p.char == 0 and p.get("exechar", 0) == 0:
		p.attacking = (
			actor.isAttacking
			and (
				(actor.state == 14 and actor.image_index > 0)
				or (actor.state == 15 and actor.image_index >= 3)
			)
		)
	var was_invisible: bool = p.get("invisible", false)
	p.invisible = actor.invisTimer > 0
	if p.char == 0 and p.get("exechar", 0) == 0 and (was_invisible or p.invisible):
		host.profile_rules.event(p, "invis")
	actor.Net.flush()
	p.motion_velocity = Vector2(actor.xspd, actor.yspd)
	p.move_state = actor.state
	p.move_frame = int(actor.image_index)
	p.attacking = p.attacking and actor.isAttacking
	p.boosted = actor.isBoosting
	host.exeller_rules.sync_actor(p, actor)
	interactions(p, actor)
	host.active_map.simulation_state(actor, p)
	actor.isBoosting = p.boosted
	return actor


func before_player(actor: Node):
	host.active_map.before_collision(actor)


func request(p: Dictionary, type: int, id := -1, wide := false, extra := -1):
	var b: StreamPeerBuffer = host._pkt(type)
	if id >= 0:
		if wide:
			b.put_u16(id)
		else:
			b.put_u8(id)
	if extra >= 0:
		b.put_u8(extra)
	host._process_packet(p.get("peer"), b.data_array, true)


func interactions(p: Dictionary, actor: Node):
	if host.character_rules.alive(p):
		host.active_map.simulation_interactions(self, p, actor)
