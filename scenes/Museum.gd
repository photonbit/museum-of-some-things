extends Node3D

@onready var TiledExhibitGenerator = preload("res://scenes/TiledExhibitGenerator.tscn")
@onready var StaticData = preload("res://assets/resources/lobby_data.tres")
var _lobby_data_path = "res://assets/resources/lobby_data.tres"

@onready var QUEUE_DELAY = 0.05

# item types
@onready var WallItem = preload("res://scenes/items/WallItem.tscn")
@onready var _xr = Util.is_xr()

@onready var _exhibit_hist = []
@onready var _exhibits = {}
@onready var _backlink_map = {}
@onready var _current_room_title = "$Lobby"
@export var items_per_room_estimate = 7
@export var min_rooms_per_exhibit = 2

var _starting_height = 40
var _height_increment = 20
var _used_exhibit_heights = {}

@export var fog_depth = 10.0
@export var fog_depth_lobby = 20.0
@export var ambient_light_lobby = 0.4
@export var ambient_light = 0.2

var _grid
var _player
var _custom_door

func _init():
    RenderingServer.set_debug_generate_wireframes(true)

func init(player):
    _player = player
    _set_up_lobby($Lobby)
    # Optional: starting door/title from ProjectSettings. Falls back to
    var start_key := "moat/start_door"
    var desired_start: String = ""
    if ProjectSettings.has_setting(start_key):
        desired_start = str(ProjectSettings.get_setting(start_key))
    if desired_start != "":
         _place_player_in_front_of_plaque(desired_start)
    reset_to_lobby()

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
    $WorldEnvironment.environment.ssr_enabled = not _xr
    $WorldEnvironment.environment.glow_enabled = true
    $WorldEnvironment.environment.glow_intensity = 0.01
    $WorldEnvironment.environment.glow_hdr_threshold = 1.0
    $WorldEnvironment.environment.glow_bloom = 0.8

    _grid = $Lobby/GridMap
    ExhibitFetcher.wikitext_complete.connect(_on_fetch_complete)
    GlobalMenuEvents.reset_custom_door.connect(_reset_custom_door)
    GlobalMenuEvents.set_custom_door.connect(_set_custom_door)
    GlobalMenuEvents.set_language.connect(_on_change_language)

func _get_free_exhibit_height() -> int:
    var height = _starting_height
    while _used_exhibit_heights.has(height):
        height += _height_increment
    _used_exhibit_heights[height] = true
    return height

func _release_exhibit_height(height: int) -> void:
    _used_exhibit_heights.erase(height)

func _get_lobby_exit_zone(exit):
    var ex = Util.gridToWorld(exit.from_pos).x
    var ez = Util.gridToWorld(exit.from_pos).z
    for w in StaticData.wings:
        var c1 = w.corner_1
        var c2 = w.corner_2
        if ex >= c1.x and ex <= c2.x and ez >= c1.y and ez <= c2.y:
            return w
    return null

func _on_change_language(_lang = ""):
# This is only safe to do if we're in the lobby
    if _current_room_title == "$Lobby":
        for exhibit in _exhibits.keys():
            if exhibit != "$Lobby":
                _erase_exhibit(exhibit)
        StaticData = ResourceLoader.load(_lobby_data_path, "", ResourceLoader.CACHE_MODE_IGNORE)
        _set_up_lobby($Lobby)

func _set_up_lobby(lobby):
    var exits = lobby.exits
    _exhibits["$Lobby"] = { "exhibit": lobby, "height": 0 }

    if OS.is_debug_build():
        print("Setting up lobby with %s exits..." % len(exits))

    var wing_indices = {}

    for exit in exits:
        var wing = _get_lobby_exit_zone(exit)

        if wing:
            if not wing_indices.has(wing.name):
                wing_indices[wing.name] = -1
            wing_indices[wing.name] += 1
            if wing_indices[wing.name] < len(wing.exhibits):
                exit.to_title = wing.exhibits[wing_indices[wing.name]]

        elif not _custom_door:
            _custom_door = exit
            _custom_door.entry_door.set_open(false, true)
            _custom_door.to_sign.visible = false

        exit.loader.body_entered.connect(_on_loader_body_entered.bind(exit))

func get_current_room():
    return _current_room_title

func _set_custom_door(title):
    if _custom_door and is_instance_valid(_custom_door):
        _custom_door.to_title = title
        _custom_door.entry_door.set_open(true)

func _reset_custom_door(title):
    if _custom_door and is_instance_valid(_custom_door):
        _custom_door.entry_door.set_open(false)

func reset_to_lobby():
    _set_current_room_title("$Lobby")

func _set_current_room_title(title):
    if title == "$Lobby":
        _backlink_map.clear()

    _current_room_title = title
    WorkQueue.set_current_exhibit(title)
    GlobalMenuEvents.emit_set_current_room(title)
    _start_queue()

    var fog_color = Util.gen_fog(_current_room_title)
    var environment = $WorldEnvironment.environment

    if environment.fog_light_color != fog_color:
        var tween = create_tween()
        tween.tween_property(
            environment,
            "fog_light_color",
            fog_color,
            1.0)

        tween.set_trans(Tween.TRANS_LINEAR)
        tween.set_ease(Tween.EASE_IN_OUT)

func _place_player_in_front_of_plaque(title: String) -> bool:
    # Locate the lobby exit pointing to the given title and place the player
    # a short distance in front of its sign, facing toward it. Returns true
    # if placement succeeded.
    var lobby = $Lobby
    if not is_instance_valid(lobby):
        return false

    # Find the hall whose to_title matches the given title (case-insensitive)
    var target_hall = null
    for exit in lobby.exits:
        if exit and str(exit.to_title).to_lower() == title.to_lower():
            target_hall = exit
            break

    if target_hall == null:
        return false

    var sign_node = target_hall.get_node_or_null("ToSign")
    if sign_node == null:
        return false

    var sign_xform: Transform3D = sign_node.global_transform
    var sign_pos: Vector3 = sign_xform.origin
    var sign_forward: Vector3 = -sign_xform.basis.z.normalized()

    var distance := 2.5
    var desired_pos: Vector3 = sign_pos - sign_forward * distance

    # Compute a floor-aware Y so we don't preserve an incompatible height.
    # 1) Measure player's current offset above the floor at their location.
    # 2) Place the player at the same offset above the floor at the target XZ.
    var current_pos: Vector3 = _player.global_position
    var current_floor_y: float = _get_floor_y_at(current_pos)
    var offset_above_floor: float = 1.6  # sensible default standing height
    if is_finite(current_floor_y):
        offset_above_floor = current_pos.y - current_floor_y
        # Clamp to a reasonable human/head/rig height range to avoid extremes
        offset_above_floor = clamp(offset_above_floor, 1.0, 2.2)

    # Raycast for floor at the desired XZ. Use sign Y as a reasonable cast origin.
    var desired_probe: Vector3 = Vector3(desired_pos.x, sign_pos.y, desired_pos.z)
    var target_floor_y: float = _get_floor_y_at(desired_probe)
    if is_finite(target_floor_y):
        desired_pos.y = target_floor_y + offset_above_floor
    else:
        # Fallback to sign height plus offset
        desired_pos.y = sign_pos.y + offset_above_floor

    # Compute a yaw that faces the sign
    var face_dir: Vector3 = sign_pos - desired_pos
    face_dir.y = 0.0
    if face_dir.length() < 0.001:
        return false
    face_dir = face_dir.normalized()
    # Compute yaw; Godot's forward is -Z for yaw = 0. Our face_dir points
    # from player to the sign, so add PI to align with the player forward.
    var target_yaw: float = atan2(face_dir.x, face_dir.z) + PI
    # Normalize yaw to [-PI, PI] to avoid excessive rotation deltas
    if target_yaw > PI:
        target_yaw -= TAU

    if not _xr:
        _player.global_position = desired_pos
        _player.global_rotation.y = target_yaw
    else:
        # Rotate XR body relative to current camera yaw
        var cam = _player.get_node_or_null("XRCamera3D")
        if cam:
            var cam_fwd: Vector3 = -cam.global_transform.basis.z
            cam_fwd.y = 0.0
            if cam_fwd.length() > 0.001:
                cam_fwd = cam_fwd.normalized()
                var cam_yaw: float = atan2(cam_fwd.x, cam_fwd.z)
                var delta: float = target_yaw - cam_yaw
                if delta > PI:
                    delta -= TAU
                elif delta < -PI:
                    delta += TAU
                var body = _player.get_node_or_null("XRToolsPlayerBody")
                if body and body.has_method("rotate_player"):
                    body.rotate_player(delta)
        _player.global_position = desired_pos
    return true

# Raycast down to find the floor Y at the given world position (using its X/Z).
# Returns NaN if no floor was found within the probe range.
func _get_floor_y_at(world_pos: Vector3, up: float = 6.0, down: float = 100.0) -> float:
    var from: Vector3 = Vector3(world_pos.x, world_pos.y + up, world_pos.z)
    var to: Vector3 = Vector3(world_pos.x, world_pos.y - down, world_pos.z)
    var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
    if space == null:
        return NAN
    var params := PhysicsRayQueryParameters3D.create(from, to)
    params.collide_with_areas = false
    params.collide_with_bodies = true
    var hit: Dictionary = space.intersect_ray(params)
    if hit and hit.has("position"):
        var p: Vector3 = hit["position"]
        return p.y
    return NAN

func _teleport(from_hall, to_hall, entry_to_exit=false):
    _prepare_halls_for_teleport(from_hall, to_hall, entry_to_exit)

func _prepare_halls_for_teleport(from_hall, to_hall, entry_to_exit=false):
    if not is_instance_valid(from_hall) or not is_instance_valid(to_hall):
        return

    from_hall.entry_door.set_open(false)
    from_hall.exit_door.set_open(false)
    to_hall.entry_door.set_open(false, true)
    to_hall.exit_door.set_open(false, true)

    var timer = $TeleportTimer
    Util.clear_listeners(timer, "timeout")
    timer.stop()
    timer.timeout.connect(
        _teleport_player.bind(from_hall, to_hall, entry_to_exit),
        ConnectFlags.CONNECT_ONE_SHOT
    )
    timer.start(HallDoor.animation_duration)

func _teleport_player(from_hall, to_hall, entry_to_exit=false):
    if is_instance_valid(from_hall) and is_instance_valid(to_hall):
        var pos = _player.global_position if not _xr else _player.get_node("XRCamera3D").global_position
        var distance = (from_hall.position - pos).length()
        if distance > max_teleport_distance:
            return
        var diff_from = _player.global_position - from_hall.position
        var rot_diff = Util.vecToRot(to_hall.to_dir) - Util.vecToRot(from_hall.to_dir)
        _player.global_position = to_hall.position + diff_from.rotated(Vector3(0, 1, 0), rot_diff)
        if not _xr:
            _player.global_rotation.y += rot_diff
        else:
            _player.get_node("XRToolsPlayerBody").rotate_player(-rot_diff)

        if entry_to_exit:
            to_hall.entry_door.set_open(true)
        else:
            to_hall.exit_door.set_open(true)
            from_hall.entry_door.set_open(true, false)

        _set_current_room_title(from_hall.from_title if entry_to_exit else from_hall.to_title)
    elif is_instance_valid(from_hall):
        if entry_to_exit:
            _load_exhibit_from_entry(from_hall)
        else:
            _load_exhibit_from_exit(from_hall)
    elif is_instance_valid(to_hall):
        if entry_to_exit:
            _load_exhibit_from_exit(to_hall)
        else:
            _load_exhibit_from_entry(to_hall)

func _on_loader_body_entered(body, hall, backlink=false):
    if hall.to_title == "" or hall.to_title == _current_room_title:
        return

    if body.is_in_group("Player"):
        if backlink:
            _load_exhibit_from_entry(hall)
        else:
            _load_exhibit_from_exit(hall)

func _load_exhibit_from_entry(entry):
    var prev_article = Util.coalesce(entry.from_title, "Fungus")

    if entry.from_title == "$Lobby":
        _link_backlink_to_exit($Lobby, entry)
        return

    if _exhibits.has(prev_article):
        var exhibit = _exhibits[prev_article].exhibit
        if is_instance_valid(exhibit):
            _link_backlink_to_exit(exhibit, entry)
            return

    ExhibitFetcher.fetch([prev_article], {
        "title": prev_article,
        "backlink": true,
        "entry": entry,
    })

func _load_exhibit_from_exit(exit):
    var next_article = Util.coalesce(exit.to_title, "Fungus")

    # TODO: this needs to only work if the hall type matches
    if _exhibits.has(next_article):
        var next_exhibit = _exhibits[next_article]
        if (
            next_exhibit.has("entry") and
            next_exhibit.entry.hall_type[1] == exit.hall_type[1] and
            next_exhibit.entry.floor_type == exit.floor_type
        ):
            _link_halls(next_exhibit.entry, exit)
            next_exhibit.entry.from_title = exit.from_title
            return
        else:
        # TODO: erase orphaned backlinks
            _erase_exhibit(next_article)

    ExhibitFetcher.fetch([next_article], {
        "title": next_article,
        "exit": exit
    })

func _add_item(exhibit, item_data):
    if not is_instance_valid(exhibit):
        return

    var slot = exhibit.get_item_slot()
    if slot == null:
        exhibit.add_room()
        if exhibit.has_item_slot():
            _add_item(exhibit, item_data)
        else:
            push_error("unable to add item slots to exhibit.")
        return

    var item = WallItem.instantiate()
    item.position = Util.gridToWorld(slot[0]) - slot[1] * 0.01
    item.rotation.y = Util.vecToRot(slot[1])

    # we use a delay to stop there from being a frame drop when a bunch of items are added at once
    # get_tree().create_timer(delay).timeout.connect(_init_item.bind(exhibit, item, item_data))
    _init_item(exhibit, item, item_data)

var text_item_fmt = "[color=black][b][font_size=200]%s[/font_size][/b]\n\n%s"

func _init_item(exhibit, item, data):
    if is_instance_valid(exhibit) and is_instance_valid(item):
        exhibit.add_child(item)
        item.init(data)

func _link_halls(entry, exit):
    if entry.linked_hall == exit and exit.linked_hall == entry:
        return

    for hall in [entry, exit]:
        Util.clear_listeners(hall, "on_player_toward_exit")
        Util.clear_listeners(hall, "on_player_toward_entry")

    _backlink_map[exit.to_title] = exit.from_title
    exit.on_player_toward_exit.connect(_teleport.bind(exit, entry))
    entry.on_player_toward_entry.connect(_teleport.bind(entry, exit, true))
    exit.linked_hall = entry
    entry.linked_hall = exit

    if exit.player_in_hall and exit.player_direction == "exit":
        _teleport(exit, entry)
    elif entry.player_in_hall and entry.player_direction == "entry":
        _teleport(entry, exit, true)

func _count_image_items(arr):
    var count = 0
    for i in arr:
        if i.has("type") and i.type == "image":
            count += 1
    return count

func _on_exit_added(exit, doors, backlink, new_exhibit, hall):
    # Doors list may contain plain strings (legacy) or dictionaries
    # { title: target, label: display } for Obsidian-style aliases.
    var linked_exhibit_raw = Util.coalesce(doors.pop_front(), "")
    var linked_title := ""
    var linked_label := ""
    if typeof(linked_exhibit_raw) == TYPE_DICTIONARY:
        if linked_exhibit_raw.has("title"):
            linked_title = str(linked_exhibit_raw.title)
        if linked_exhibit_raw.has("label"):
            linked_label = str(linked_exhibit_raw.label)
    else:
        linked_title = str(linked_exhibit_raw)

    exit.to_title = linked_title
    # If we have a custom label, show it on the door sign while keeping
    # to_title for navigation logic.
    if linked_label != "":
        exit.to_sign.text = linked_label
    exit.loader.body_entered.connect(_on_loader_body_entered.bind(exit))
    if is_instance_valid(hall) and backlink and exit.to_title == hall.to_title:
        _link_halls(hall, exit)

func _erase_exhibit(key):
    if OS.is_debug_build():
        print("erasing exhibit ", key)
    _exhibits[key].exhibit.queue_free()
    _release_exhibit_height(_exhibits[key].height)
    _global_item_queue_map.erase(key)
    _exhibits.erase(key)
    var i = _exhibit_hist.find(key)
    if i >= 0:
        _exhibit_hist.remove_at(i)

func _on_fetch_complete(_titles, context):
# we don't need to do anything to handle a prefetch
    if context.has("prefetch"):
        return
        
    var backlink = context.has("backlink") and context.backlink
    var hall = context.entry if backlink else context.exit
    var result = ExhibitFetcher.get_result(context.title)
    if not result or not is_instance_valid(hall):
    # TODO: show an out of order sign
        return

    var prev_title
    if backlink:
        prev_title = _backlink_map[context.title]
    else:
        prev_title = hall.from_title

    ItemProcessor.create_items(context.title, result, prev_title)

    var data
    while not data:
        data = await ItemProcessor.items_complete
        if data.title != context.title:
            data = null

    var doors = data.doors
    var items = data.items
    var extra_text = data.extra_text
    var exhibit_height = _get_free_exhibit_height()

    var new_exhibit = TiledExhibitGenerator.instantiate()
    add_child(new_exhibit)

    new_exhibit.exit_added.connect(_on_exit_added.bind(doors, backlink, new_exhibit, hall))
    new_exhibit.generate(_grid, {
        "start_pos": Vector3.UP * exhibit_height,
        "min_room_dimension": min_room_dimension,
        "max_room_dimension": max_room_dimension,
        "room_count": max(
            len(items) / items_per_room_estimate,
            min_rooms_per_exhibit
        ),
        "title": context.title,
        "prev_title": prev_title,
        "no_props": len(items) < 10,
        "hall_type": hall.hall_type,
        "exit_limit": len(doors),
    })

    # Ensure we create at least one exit per desired door link.
    # TiledExhibitGenerator places exits only where geometry allows; if the
    # initial layout doesn't expose enough wall spots, grow the exhibit until
    # we reach the required number of exits (capped to avoid infinite loops).
    # Compute the total desired exits as (already created exits + remaining door links).
    # Note: `doors` is being mutated by _on_exit_added (pop_front), so its length
    # here represents the remaining links that still need an exit.
    var _target_exits: int = len(doors) + len(new_exhibit.exits)
    var _tries: int = 0
    var _max_tries: int = max(10, _target_exits * 3)
    while is_instance_valid(new_exhibit) and len(new_exhibit.exits) < _target_exits and _tries < _max_tries:
        new_exhibit.add_room()
        _tries += 1
    if OS.is_debug_build() and len(new_exhibit.exits) < _target_exits:
        push_warning("Not enough exit slots created for all links (" + str(len(new_exhibit.exits)) + "/" + str(_target_exits) + ")")

    if not _exhibits.has(context.title):
        _exhibits[context.title] = { "entry": new_exhibit.entry, "exhibit": new_exhibit, "height": exhibit_height }
        _exhibit_hist.append(context.title)
        if len(_exhibit_hist) > max_exhibits_loaded:
            for e in range(len(_exhibit_hist)):
                var key = _exhibit_hist[e]
                if _exhibits.has(key):
                    var old_exhibit = _exhibits[key]
                    if abs(4 * old_exhibit.height - _player.position.y) < 20:
                        continue
                    if old_exhibit.exhibit.title == new_exhibit.title:
                        continue
                    _erase_exhibit(key)
                    break

    var item_queue = []
    for item_data in items:
        if item_data:
            item_queue.append(_add_item.bind(new_exhibit, item_data))

    # Queue the items directly; no external API waits
    _queue_item(context.title, item_queue)
    # Also queue any extra text plaques
    _queue_extra_text(new_exhibit, extra_text)
    # Finally, mark the exhibit as finished (handles backlink linking)
    var finish_ctx = {
        "exhibit": new_exhibit,
        "title": context.title,
        "hall": hall,
        "backlink": backlink,
    }
    _queue_item(context.title, _on_finished_exhibit.bind(finish_ctx))

    if backlink:
        new_exhibit.entry.loader.body_entered.connect(_on_loader_body_entered.bind(new_exhibit.entry, true))
    else:
        _link_halls(new_exhibit.entry, hall)

func _queue_extra_text(exhibit, extra_text):
    for item in extra_text:
        _queue_item(exhibit.title, _add_item.bind(exhibit, item))

func _link_backlink_to_exit(exhibit, hall):
    if not is_instance_valid(exhibit) or not is_instance_valid(hall):
        return

    var new_hall
    for exit in exhibit.exits:
        if exit.to_title == hall.to_title:
            new_hall = exit
            break
    if not new_hall and exhibit.entry:
        push_error("could not backlink new hall")
        new_hall = exhibit.entry
    if new_hall:
        _link_halls(hall, new_hall)

func _on_finished_exhibit(ctx):
    if not is_instance_valid(ctx.exhibit):
        return
    if OS.is_debug_build():
        print("finished exhibit. slots=", len(ctx.exhibit._item_slots))
    if ctx.backlink:
        _link_backlink_to_exit(ctx.exhibit, ctx.hall)

var _queue_running = false
var _global_item_queue_map = {}

func _process_item_queue():
    var queue = _global_item_queue_map.get(_current_room_title, [])
    var callable = queue.pop_front()
    if not callable:
        _queue_running = false
        return
    else:
        _queue_running = true
        callable.call()
        get_tree().create_timer(QUEUE_DELAY).timeout.connect(_process_item_queue.bind())

func _queue_item_front(title, item):
    _queue_item(title, item, true)

func _queue_item(title, item, front = false):
    if not _global_item_queue_map.has(title):
        _global_item_queue_map[title] = []
    if typeof(item) == TYPE_ARRAY:
        _global_item_queue_map[title].append_array(item)
    elif not front:
        _global_item_queue_map[title].append(item)
    else:
        _global_item_queue_map[title].push_front(item)
    _start_queue()

func _start_queue():
    if not _queue_running:
        _process_item_queue()

@export var max_teleport_distance: float = 10.0
@export var max_exhibits_loaded: int = 2
@export var min_room_dimension: int = 2
@export var max_room_dimension: int = 5
