extends Node
## GM — asset loader + GM letter-font text renderer for the server UI.
## Autoloaded as `GM`.

var sprites: Dictionary = {}

const LETTER_SPR := "spr_letter1"


func _ready() -> void:
	var data: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("res://assets/gm/sprites.json")
	)
	for name: String in data:
		var m: Dictionary = data[name]
		var texs: Array[Texture2D] = []
		for f: String in m["frames"]:
			var t: Texture2D = load("res://assets/sprites/%s/%s" % [name, f])
			if t:
				texs.append(t)
		sprites[name] = {"textures": texs, "meta": m}


func sprite_texture(name: String, index: int) -> Texture2D:
	if not sprites.has(name):
		return null
	var fr: Array = sprites[name]["textures"]
	if fr.is_empty():
		return null
	while index < 0:
		index += fr.size()
	return fr[index % fr.size()]


static func _letter_index(c: String) -> int:
	var ordv := c.unicode_at(0)
	if ordv >= 0x0430 and ordv <= 0x044F:
		return 45 + (ordv - 0x0430)
	if c >= "a" and c <= "z":
		return ordv - 97
	match c:
		"-":
			return 26
		",":
			return 27
		"1":
			return 28
		"2":
			return 29
		"3":
			return 30
		"4":
			return 31
		"5":
			return 32
		"6":
			return 33
		"7":
			return 34
		"8":
			return 35
		"9":
			return 36
		"0":
			return 37
		".":
			return 38
		"'":
			return 39
		":":
			return 40
		"(":
			return 41
		")":
			return 42
		"%":
			return 43
		"+":
			return 77
	return 44


const _WIDE_CHARS := ["w", "m", "x", "n", "м", "д", "и", "й", "ю", "ь", "л", "ш", "щ", "ц", "ж"]


## GM letter-font text draw (same metrics as the client's scr_text_spr)
static func draw_text(
	ci: CanvasItem, xx: float, yy: float, str_: String, col: Color = Color.WHITE, scale := 1.0
) -> void:
	str_ = str_.to_lower()  # the letter font only has lowercase glyphs
	var x := xx
	var y := yy
	for i in str_.length():
		var c := str_[i]
		if c == "\n":
			x = xx
			y += 8 * scale
			continue
		if c == " ":
			x += 5 * scale
			continue
		var ind := _letter_index(c)
		var tex: Texture2D = GM.sprite_texture(LETTER_SPR, ind)
		if tex:
			if scale == 1.0:
				ci.draw_texture(tex, Vector2(x, y), col)
			else:
				var dst := Rect2(Vector2(x, y), Vector2(8, 6) * scale)
				ci.draw_texture_rect(tex, dst, false, col)
		x += 6 * scale
		if _WIDE_CHARS.has(c):
			x += 2 * scale


static func text_width(str_: String, scale := 1.0) -> float:
	var w := 0.0
	for i in str_.length():
		var c := str_[i]
		if c == "\n":
			continue
		w += 5 * scale
		if _WIDE_CHARS.has(c):
			w += 2 * scale
	return w
