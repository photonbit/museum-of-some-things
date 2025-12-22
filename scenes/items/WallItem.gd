extends Node3D

@onready var ImageItem = preload("res://scenes/items/ImageItem.tscn")
@onready var TextItem = preload("res://scenes/items/TextItem.tscn")
@onready var RichTextItem = preload("res://scenes/items/RichTextItem.tscn")

@onready var MarbleMaterial = preload("res://assets/textures/marble21.tres")
@onready var WhiteMaterial = preload("res://assets/textures/flat_white.tres")
@onready var WoodMaterial = preload("res://assets/textures/wood_2.tres")
@onready var BlackMaterial = preload("res://assets/textures/black.tres")

@onready var _item_node = $Item
@onready var _item
@onready var _ceiling = $Ceiling
@onready var _light = get_node("Item/SpotLight3D")
@onready var _frame = get_node("Item/Frame")
@onready var _frame_mesh: MeshInstance3D = get_node("Item/Frame/Frame")
@onready var _animate_item_target = _item_node.position + Vector3(0, 4, 0)
@onready var _animate_ceiling_target = _ceiling.position - Vector3(0, 2, 0)

# Interactive sidecar info (for images that have a matching .json/.geojson)
var _has_sidecar: bool = false
var _image_src: String = ""
var _image_title: String = ""
var _sidecar_url: String = ""
var _interaction_distance: float = 3.0
var _glow_distance: float = 10.0

# Cached halo overlay material (only for sidecar images)
var _halo_overlay: StandardMaterial3D = null

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
  pass # Replace with function body.

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta: float) -> void:
  # Only toggle halo for sidecar-enabled images, based on proximity
  if not _has_sidecar:
    return
  if not is_instance_valid(_frame_mesh):
    return
  var player = get_tree().get_first_node_in_group("Player")
  var near = false
  if player:
    # Use world-space positions for accurate distance
    near = global_position.distance_to(player.global_position) < _glow_distance
  if near:
    if _halo_overlay and _frame_mesh.material_overlay != _halo_overlay:
      _frame_mesh.material_overlay = _halo_overlay
  else:
    if _frame_mesh.material_overlay != null:
      _frame_mesh.material_overlay = null

func _start_animate():
  var player = get_tree().get_first_node_in_group("Player")
  var tween_time = 0.5

  if not player or position.distance_to(player.global_position) > $Item/Plaque.visibility_range_end:
    tween_time = 0
  else:
    $SlideSound.play()

  var tween = create_tween()
  var light_tween = create_tween()
  var ceiling_tween = create_tween()

  tween.tween_property(
    _item_node,
    "position",
    _animate_item_target,
    tween_time
  )

  ceiling_tween.tween_property(
    _ceiling,
    "position",
    _animate_ceiling_target,
    tween_time
  )

  if Util.is_compatibility_renderer():
    # On the compatibility renderer, this will get faded in by the GraphicsManager.
    light_tween.kill()
    _light.visible = false
  else:
    light_tween.tween_property(
      _light,
      "light_energy",
      3.0,
      tween_time
    )

  tween.set_trans(Tween.TRANS_LINEAR)
  tween.set_ease(Tween.EASE_IN_OUT)

  light_tween.set_trans(Tween.TRANS_LINEAR)
  light_tween.set_ease(Tween.EASE_IN_OUT)

  ceiling_tween.set_trans(Tween.TRANS_LINEAR)
  ceiling_tween.set_ease(Tween.EASE_IN_OUT)

func _on_image_item_loaded():
  var size: Vector2 = _item.get_image_size()
  if size.x > size.y:
    _frame.scale.y = size.y / float(size.x)
  else:
    _frame.scale.x = size.x / float(size.y)
  _frame.position = _item.position
  _frame.position.z = 0
  _start_animate()

func _unhandled_input(event):
  if not _has_sidecar:
    return
  var player = get_tree().get_first_node_in_group("Player")
  var near = false
  if player:
    # Use world-space distance check
    near = global_position.distance_to(player.global_position) < _interaction_distance
  if not near:
    return
  if event is InputEventMouseButton:
    var mb := event as InputEventMouseButton
    if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
      var img_name = _image_src.get_file() if _image_src != "" else _image_title
      var json_name = _sidecar_url.get_file() if _sidecar_url != "" else _sidecar_url
      print("[InteractiveImage] ", img_name, " -> ", json_name)
      # Enter painting walk using the manager
      if _sidecar_url != "":
        PaintingWalk.enter_walk(_image_title, _image_src, _sidecar_url, self)
  elif Input.is_action_just_pressed("ui_accept"):
    var img_name2 = _image_src.get_file() if _image_src != "" else _image_title
    var json_name2 = _sidecar_url.get_file() if _sidecar_url != "" else _sidecar_url
    print("[InteractiveImage] ", img_name2, " -> ", json_name2)
    if _sidecar_url != "":
      PaintingWalk.enter_walk(_image_title, _image_src, _sidecar_url, self)

func init(item_data):
  if item_data.has("material"):
    if item_data.material == "marble":
      $Item/Plaque.material_override = (MarbleMaterial as Material)
    if item_data.material == "white":
      $Item/Plaque.material_override = (WhiteMaterial as Material)
    elif item_data.material == "none":
      $Item/Plaque.visible = false
      _animate_item_target.z -= 0.05

  if item_data.type == "image":
    _item = ImageItem.instantiate()
    _item.loaded.connect(_on_image_item_loaded)
    _item.init(item_data.title, item_data.text, item_data.plate)
    # Detect sidecar and enable interaction + frame highlight
    _image_title = item_data.title
    var data = ExhibitFetcher.get_result(item_data.title)
    if data and typeof(data) == TYPE_DICTIONARY:
      if data.has("src"):
        _image_src = str(data.get("src"))
      if data.has("sidecar_url"):
        _has_sidecar = true
        _sidecar_url = str(data.get("sidecar_url"))
        # Prepare (but do not always apply) a halo overlay derived from the base frame material.
        if is_instance_valid(_frame_mesh):
          var base_mat: Material = _frame_mesh.get_surface_override_material(0)
          if base_mat == null and _frame_mesh.mesh:
            base_mat = _frame_mesh.mesh.surface_get_material(0)
          var halo: StandardMaterial3D
          if base_mat is StandardMaterial3D:
            halo = (base_mat as StandardMaterial3D).duplicate(true)
          else:
            halo = StandardMaterial3D.new()
          halo.emission_enabled = true
          halo.emission = Color(0.9, 0.3, 0.1)
          halo.emission_energy_multiplier = 6.2
          halo.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
          halo.cull_mode = BaseMaterial3D.CULL_DISABLED
          _halo_overlay = halo
          _frame_mesh.material_overlay = halo
          # Do not apply immediately; _process() will toggle based on proximity.
        # Interaction handled via _unhandled_input when player is near.
      else:
        # Ensure there is no overlay applied to non-sidecar images
        if is_instance_valid(_frame_mesh) and _frame_mesh.material_overlay != null:
          _frame_mesh.material_overlay = null
  elif item_data.type == "text":
    _frame.visible = false
    _item = TextItem.instantiate()
    _item.init(item_data.text)
    _start_animate()
  elif item_data.type == "rich_text":
    _frame.visible = false
    _item = RichTextItem.instantiate()
    _item.init(item_data.text)
    _start_animate()
  else:
    return
  _item.position = Vector3(0, 0, 0.07)
  _item_node.add_child(_item)
