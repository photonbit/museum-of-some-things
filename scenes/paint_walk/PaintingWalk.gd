extends Node

# PaintingWalk: Minimal manager to enter a generated painting world
# from an interactive image (with .json/.geojson sidecar) and return
# the player to the museum if they fall 10 meters below the painting.

var _active: bool = false
var _container: Node3D = null
var _loader: Node3D = null # PaintingWorldLoader instance
var _return_transform: Transform3D
var _origin_wall_item: Node3D = null
var _player: Node3D = null

const FALL_THRESHOLD_M := 10.0
const WORLD_OFFSET := Vector3(8000.0, 3000.0, -8000.0)

# Watchdog guard
var _spawned: bool = false

func _ready() -> void:
    set_process(true)

func enter_walk(image_title: String, image_src: String, sidecar_url: String, origin_wall_item: Node3D) -> void:
    if _active:
        # If already active, ignore or re-enter by exiting first
        exit_and_return()
    _player = get_tree().get_first_node_in_group("Player")
    if _player == null:
        push_warning("PaintingWalk: No player node (group 'Player') found; cannot enter walk")
        return

    if sidecar_url == "":
        push_warning("PaintingWalk: Missing sidecar (.json/.geojson) for interactive image")
        return

    _origin_wall_item = origin_wall_item
    _return_transform = _compute_return_transform(origin_wall_item)

    # Create container for the painting world (far away from museum)
    _container = Node3D.new()
    _container.name = "PaintingWorldContainer"
    var root := get_tree().current_scene
    if root == null:
        root = get_tree().root
    root.add_child(_container)
    # Move the whole painting world far away and high so the museum is not visible
    _container.global_position = WORLD_OFFSET

    # Build a PaintingDefinition dynamically
    var PaintingDefinitionRes = load("res://scenes/paint_walk/painting_definition.gd")
    var def = PaintingDefinitionRes.new()
    def.geojson_path = sidecar_url
    var tex = load(image_src)
    if tex is Texture2D:
        def.image = tex
    def.use_image_size = true
    def.meters_per_pixel_override = 0.0

    # Instance the PaintingWorldLoader and build the world
    var LoaderScript = load("res://scenes/paint_walk/painting_world_loader.gd")
    _loader = LoaderScript.new()
    _loader.set("auto_build_on_ready", false)
    _container.add_child(_loader)

    # Apply definition and build immediately (use call to avoid static typing issues)
    if _loader.has_method("_apply_painting_definition"):
        _loader.call("_apply_painting_definition", def)
    if _loader.has_method("_build_world"):
        _loader.call("_build_world")

    _spawned = false
    _place_player_into_painting(_loader)
    _spawned = true

    _active = true

func exit_and_return() -> void:
    if _player and _return_transform:
        _teleport_player_to(_return_transform)
    if is_instance_valid(_container):
        _container.queue_free()
    _container = null
    _loader = null
    _origin_wall_item = null
    _spawned = false
    _active = false
    # Restore ambience to the exhibit/lobby rules after leaving the painting world.
    # If the current room (from Museum) has an exhibit-level audio override,
    # reapply it; otherwise resume default ambience. Lobby clears override.
    _restore_exhibit_ambience()

func _process(_dt: float) -> void:
    if not _active:
        return
    # Guard: while warping or before initial spawn, do not trigger fall return
    if not _spawned:
        return
    if _player == null or not is_instance_valid(_player):
        return
    if _loader == null or not is_instance_valid(_loader):
        return
    var base_h := 0.0
    if _loader.has_method("get"):
        base_h = float(_loader.get("base_height"))
    # Account for world offset when checking fall height
    var base_world_y := (_container.global_position.y if is_instance_valid(_container) else 0.0) + base_h
    var py := _player.global_position.y
    if py < (base_world_y - FALL_THRESHOLD_M):
        exit_and_return()

func _compute_return_transform(origin_wall_item: Node3D) -> Transform3D:
    if origin_wall_item == null or not is_instance_valid(origin_wall_item):
        # Fallback: use current player transform
        return _player.global_transform
    var gxf := origin_wall_item.global_transform
    var fwd := -gxf.basis.z # out from the wall (toward the viewer)
    var up := gxf.basis.y
    var frame_pos := gxf.origin
    var return_pos := frame_pos + fwd.normalized() * 1.2 + up.normalized() * 1.6
    var xform := Transform3D()
    xform.origin = return_pos
    xform = xform.looking_at(frame_pos, Vector3.UP)
    return xform

func _place_player_into_painting(loader: Node3D) -> void:
    if _player == null or not is_instance_valid(_player):
        return
    # Read world dimensions after build
    var base_h := 0.0
    var world_w := 5.0
    var world_h := 5.0
    if loader:
        if loader.has_method("get"):
            base_h = float(loader.get("base_height"))
            world_w = float(loader.get("world_width"))
            world_h = float(loader.get("world_height"))

    var eye_h := 1.6
    var z_off: float = -min(2.0, world_h * 0.25)
    var local_pos := Vector3(0.0, base_h + eye_h, z_off)
    var local_look_at := Vector3(0.0, base_h + eye_h, 0.0)
    # Convert to global using the container offset
    var gpos := _container.to_global(local_pos) if (is_instance_valid(_container)) else local_pos
    var gtgt := _container.to_global(local_look_at) if (is_instance_valid(_container)) else local_look_at
    var xform := Transform3D()
    xform.origin = gpos
    xform = xform.looking_at(gtgt, Vector3.UP)
    _teleport_player_to(xform)

func _teleport_player_to(xform: Transform3D) -> void:
    if _player == null or not is_instance_valid(_player):
        return
    # Minimal cross-platform placement; XR-specific helpers can be added later
    _player.global_transform = xform

# --- Ambience handoff helpers ---
func _restore_exhibit_ambience() -> void:
    var ac = _find_ambience_controller()
    if ac == null:
        return
    var museum = _find_museum()
    var title := ""
    if museum and museum.has_method("get_current_room"):
        title = str(museum.call("get_current_room"))
    if title == "":
        title = "$Lobby"
    if title == "$Lobby":
        if ac.has_method("clear_override"):
            ac.call("clear_override", 0.5)
        return
    var result = ExhibitFetcher.get_result(title)
    if result and typeof(result) == TYPE_DICTIONARY:
        var d: Dictionary = result
        if d.has("audio"):
            var rel_path := str(d.get("audio"))
            if rel_path != "" and ac.has_method("play_override_from_content_path"):
                ac.call("play_override_from_content_path", rel_path, true, 0.5)
                return
    if ac.has_method("clear_override"):
        ac.call("clear_override", 0.5)

func _find_museum() -> Node:
    var root = get_tree().current_scene
    if root:
        var n = root.get_node_or_null("Museum")
        if n:
            return n
    return get_tree().root.find_child("Museum", true, false)

func _find_ambience_controller() -> Node:
    var root = get_tree().current_scene
    if root:
        var n = root.get_node_or_null("AmbienceController")
        if n:
            return n
    return get_tree().root.find_child("AmbienceController", true, false)
