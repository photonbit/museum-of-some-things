extends MeshInstance3D

signal loaded

var image_url
var _image: Texture2D
var text
var title
var plate_style

var plate_margin = 0.05
var max_text_height = 0.5

@onready var plate_black = preload("res://assets/textures/black.tres")
@onready var plate_white = preload("res://assets/textures/flat_white.tres")

@onready var text_white = Color(0.8, 0.8, 0.8)
@onready var text_black = Color(0.0, 0.0, 0.0)
@onready var text_clear = Color(0.0, 0.0, 0.0, 0.0)

func get_image_size():
  if _image:
    return Vector2(_image.get_width(), _image.get_height())
  return Vector2.ZERO

func _format_time_component(raw: String) -> String:
  # Accept variants: "HH:MM", "HH:MM SS", "HHMM", "HHMMSS"
  var t = raw.strip_edges()
  if t.find(":") >= 0:
    return t
  if t.length() == 4 and t.is_valid_int():
    return str(int(t.substr(0, 2))) + ":" + t.substr(2, 2)
  if t.length() == 6 and t.is_valid_int():
    return str(int(t.substr(0, 2))) + ":" + t.substr(2, 2) + " " + t.substr(4, 2)
  return t

func _format_date_alias_lines(s: String) -> String:
  # Turn a flat alias like "2022 2 12 195035 something" into lines:
  # 2022 2 12\n19:50 35\nsomething
  # Works with partials too: YYYY, YYYY M, YYYY M D, with optional time and rest.
  var text = s.strip_edges()
  if text == "":
    return text
  var parts: PackedStringArray = text.split(" ")
  # Collect numeric leading tokens
  var nums: Array = []
  var i = 0
  while i < parts.size():
    var p = parts[i]
    if p == "":
      i += 1
      continue
    var is_num = true
    for c in p:
      if not (c >= '0' and c <= '9' or c == ':' or c == ' '):
        is_num = false
        break
    if not is_num:
      break
    nums.append(p)
    i += 1

  if nums.size() == 0:
    return text

  var year = nums[0]
  if year.length() != 4 or not year.is_valid_int():
    return text

  var lines: Array = []
  var date_line = year
  if nums.size() >= 2 and nums[1].is_valid_int():
    date_line += " " + str(int(nums[1]))
  if nums.size() >= 3 and nums[2].is_valid_int():
    date_line += " " + str(int(nums[2]))
  lines.append(date_line)

  # Time component: consider next numeric token if present
  var time_added = false
  var appended_extra_seconds = false
  if nums.size() >= 4:
    var tkn = nums[3]
    var time_line = _format_time_component(tkn)
    if time_line != "":
      # If the next token looks like 2-digit seconds and the time token already
      # contains a colon (i.e., HH:MM), append as " HH" to produce "HH:MM SS".
      if nums.size() >= 5 and nums[4].length() == 2 and nums[4].is_valid_int() and time_line.find(":") >= 0:
        time_line += " " + nums[4]
        appended_extra_seconds = true
      lines.append(time_line)
      time_added = true

  # Remaining tokens (from i where non-numeric started or after used)
  var rest_tokens: Array = []
  # If we consumed k numeric tokens for date (1..3) plus maybe time (1), determine consumed
  var consumed = 1
  if nums.size() >= 2 and nums[1].is_valid_int():
    consumed = 2
  if nums.size() >= 3 and nums[2].is_valid_int():
    consumed = 3
  if time_added:
    consumed = min(nums.size(), consumed + 1 + (1 if appended_extra_seconds else 0))

  # Build rest from remaining of nums (beyond consumed) and any leftover non-numeric parts
  for j in range(consumed, nums.size()):
    rest_tokens.append(str(nums[j]))
  while i < parts.size():
    var p2 = parts[i]
    if p2 != "":
      rest_tokens.append(p2)
    i += 1
  if rest_tokens.size() > 0:
    lines.append(" ".join(rest_tokens))

  return "\n".join(lines)

func _update_text_plate():
  var aabb = $Label.get_aabb()
  if aabb.size.length() == 0:
    return

  if aabb.size.y > max_text_height:
    $Label.font_size -= 1
    call_deferred("_update_text_plate")
    return

  if not plate_style:
    return

  var plate = $Label/Plate
  plate.visible = true
  plate.scale = Vector3(aabb.size.x + 2 * plate_margin, 1, aabb.size.y + 2 * plate_margin)
  plate.position.y = -(aabb.size.y / 2.0)

func _on_image_loaded(url, texture, _ctx):
  if url != image_url:
    return

  DataManager.loaded_image.disconnect(_on_image_loaded)
  _image = texture
  if _image and _image.get_width() > 0 and _image.get_height() > 0:
    if material_override is ShaderMaterial:
      (material_override as ShaderMaterial).set_shader_parameter("texture_albedo", _image)

  var label = $Label
  label.text = _format_date_alias_lines(Util.strip_markup(text))
  call_deferred("_update_text_plate")

  var w = _image.get_width()
  var h = _image.get_height()
  var fw = float(w)
  var fh = float(h)

  if w != 0:
    var height = 2.0 if h > w else 2.0 * (fh / fw)
    var width = 2.0 if w > h else 2.0 * (fw / fh)

    if mesh is PlaneMesh:
      var pm: PlaneMesh = mesh
      pm.size = Vector2(width, height)
    label.position.z = (height / 2.0) + 0.2
    label.vertical_alignment = VERTICAL_ALIGNMENT_TOP

    visible = true
    emit_signal("loaded")

func _set_image(data: Dictionary):
  # ensure this wasn't handled after free
  var label = $Label
  if is_instance_valid(label) and data.has("license_short_name") and data.has("artist"):
    var formatted = _format_date_alias_lines(Util.strip_markup(text))
    var license_line = str(data.get("license_short_name")) + " " + Util.strip_html(str(data.get("artist")))
    label.text = formatted + "\n" + license_line
    call_deferred("_update_text_plate")

  if data.has("src"):
    # Use the exact src string for URL identity. Normalizing (e.g., encoding
    # spaces to %20) breaks the equality check against DataManager's emitted
    # URL when filenames contain spaces. Keep it verbatim to match signals.
    image_url = str(data.get("src"))
    DataManager.loaded_image.connect(_on_image_loaded)
    DataManager.request_image(image_url)

# Called when the node enters the scene tree for the first time.
func _ready():
  if not plate_style:
    pass
  elif plate_style == "white":
    $Label.modulate = text_black
    $Label.outline_modulate = text_clear
    $Label/Plate.material_override = plate_white
  elif plate_style == "black":
    $Label.modulate = text_white
    $Label.outline_modulate = text_black
    $Label/Plate.material_override = plate_black

func init(_title, _text, _plate_style = null):
  text = _text
  title = _title
  plate_style = _plate_style

  var data = ExhibitFetcher.get_result(title)
  if data:
    _set_image(data)
  else:
    if OS.is_debug_build():
      push_warning("Missing image data for: " + str(title))
