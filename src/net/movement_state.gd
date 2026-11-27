extends RefCounted
## Shared wire schema for fixed-step actor checkpoints.
const ACTOR := [
	"anims_visible",
	"anims_invisible",
	"anims_cur",
	"anims_invis",
	"anims_eanims",
	"survivor",
	"hunter",
	"_character_anim_state",
	"djumpRecharge",
	"shieldRechrage",
	"trackerRecharge",
	"dashTimer",
	"dashing",
	"flyTimeout",
	"ringsTimer",
	"ringsSpawn",
	"isColliding",
	"slowTimer",
	"glideTimer",
	"glideTimeout",
	"glide_xspd",
	"isGliding",
	"isStuck",
	"hjumpTimer",
	"isHJ",
	"shieldTimer",
	"isSliding",
	"slideSpeed",
	"gspd",
	"xspd",
	"yspd",
	"state",
	"angle",
	"lookTimer",
	"effectTime",
	"attackTimer",
	"hurttime",
	"redRingTimer",
	"shockedTimer",
	"invisTimer",
	"attackSpeed",
	"bounceTimer",
	"shards",
	"isGrounded",
	"isJumping",
	"isLookingUp",
	"isLookingDown",
	"isHurt",
	"isAttacking",
	"isSpinning",
	"isHiding",
	"won",
	"lost",
	"justJumped",
	"canMove",
	"canSpin",
	"emotion",
	"isBoosting",
	"isZipline",
	"isFlying",
	"flyTimer",
	"flyGrv",
	"attackCharge",
	"attackAfter",
	"attackKDir",
	"recoil",
	"healCooldown",
	"isOnEdge",
	"edgeDir",
	"acc",
	"maxHSpeed",
	"maxYSpeed",
	"yAccel",
	"jumpForce",
	"isSlow",
	"_sens_coll_BL",
	"_sens_BL",
	"_sens_BR",
	"_near",
	"_near_r",
	"_near_simple",
	"_near_one_way",
	"_sens_coll_BR",
	"_sens_L_x",
	"_sens_L_y",
	"_sens_R_x",
	"_sens_R_y",
	"_dead_pin",
	"image_xscale",
	"image_yscale",
	"image_index",
	"image_speed",
	"sprite_name",
	"_anim_accum"
]
const HUNTERS := {
	"chaos":
	[
		"slimeTimer",
		"slimeAnim",
		"stuckTimer",
		"stuckDashTimer",
		"stuckDir",
		"dashDir",
		"contactWindow",
		"held_left",
		"held_right",
		"held_up",
		"prev_grounded",
		"lost_state",
		"last_state"
	],
	"exetior":
	[
		## Shared wire schema for fixed-step actor checkpoints.
		"bringTimer",
		"isStomping",
		"justLanded",
		"canSpawnRings",
		"indicatorTimer",
		"prev_grounded",
		"last_state"
	],
	"exeller":
	["clones", "cloneTimer", "indicatorTimer", "last_state", "prev_grounded", "lost_state"]
}


static func capture(actor: Node, hunter_id: int) -> Array:
	var values := []
	for key in ACTOR:
		var value = actor.get(key)
		values.append(
			(
				value
				if typeof(value) in [TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_VECTOR2, TYPE_STRING]
				else null
			)
		)
	var hunter_values := []
	var names: Array = HUNTERS.get({1: "chaos", 2: "exetior", 3: "exeller"}.get(hunter_id, ""), [])
	if actor.hunter != null:
		for key in names:
			var value = actor.hunter.get(key)
			if value is Array:
				value = value.duplicate(true)
			hunter_values.append(
				(
					value
					if (
						typeof(value)
						in [TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_VECTOR2, TYPE_STRING, TYPE_ARRAY]
					)
					else null
				)
			)
	var zip_values := []
	for zip in zip_objects(actor):
		var record := [str(zip.get_meta("source_name", str(zip.name)))]
		for key in ZIP_FIELDS:
			record.append(zip.get(key))
		zip_values.append(record)
	return [values, hunter_values, zip_values]


static func apply(actor: Node, checkpoint: Array, hunter_id: int):
	if checkpoint.size() != 3 or not checkpoint[0] is Array or checkpoint[0].size() != ACTOR.size():
		return
	for i in ACTOR.size():
		if checkpoint[0][i] != null:
			actor.set(ACTOR[i], checkpoint[0][i])
	var names: Array = HUNTERS.get({1: "chaos", 2: "exetior", 3: "exeller"}.get(hunter_id, ""), [])
	if actor.hunter != null and checkpoint[1] is Array and checkpoint[1].size() == names.size():
		for i in names.size():
			if checkpoint[1][i] != null:
				if actor.hunter.get(names[i]) is Array:
					actor.hunter.get(names[i]).assign(checkpoint[1][i])
				else:
					actor.hunter.set(names[i], checkpoint[1][i])
	if checkpoint[2] is Array:
		for zip in zip_objects(actor):
			for record in checkpoint[2]:
				if (
					record is Array
					and record.size() == ZIP_FIELDS.size() + 1
					and record[0] == str(zip.get_meta("source_name", str(zip.name)))
				):
					for i in ZIP_FIELDS.size():
						zip.set(ZIP_FIELDS[i], record[i + 1])


const ZIP_FIELDS := ["position", "progress", "zspeed", "zvspeed", "timeout", "hasPlayer", "camY"]


static func zip_objects(actor: Node) -> Array:
	if actor.has_meta("simulation_zip_objects"):
		return actor.get_meta("simulation_zip_objects")
	return actor.get_tree().get_nodes_in_group("obj_aiz_zipline")
