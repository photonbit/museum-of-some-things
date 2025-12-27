extends Node3D

# --- Configurable parameters ---
@export var fade_duration := 2.5
@export var ambience_bus: StringName = "Ambience"
@export_range(1, 3600) var ambient_voice_space_min := 60
@export_range(1, 3600) var ambient_voice_space_max := 300
@export_range(1, 3600) var ambience_event_space_min := 30
@export_range(1, 3600) var ambience_event_space_max := 180

# Optional directories (if set, they override hardcoded lists)
var _ambience_dir: String
var _voices_dir: String
var _events_dir: String
var _event_weight_from_name := true

# --- State ---
var _current_player: AudioStreamPlayer
var _override_player: AudioStreamPlayer
var _paused := false
var _override_active := false

# Data sets; by default populated with preloads (backward-compatible)
var _ambience_tracks: Array[AudioStream] = [
    preload("res://assets/sound/Global Ambience/Global ambience 1.ogg"),
    preload("res://assets/sound/Global Ambience/Global ambience 2.ogg"),
    preload("res://assets/sound/Global Ambience/Global ambience 3.ogg"),
    preload("res://assets/sound/Global Ambience/Global ambience 4.ogg"),
]
var _ambient_voices: Array[AudioStream] = [
    preload("res://assets/sound/Voices/Voices 1.ogg"),
    preload("res://assets/sound/Voices/Voices 2.ogg"),
    preload("res://assets/sound/Voices/Voices 3.ogg"),
    preload("res://assets/sound/Voices/Voices 4.ogg"),
    preload("res://assets/sound/Voices/Voices 5.ogg"),
    preload("res://assets/sound/Voices/Voices 6.ogg"),
    preload("res://assets/sound/Voices/Voices 7.ogg"),
    preload("res://assets/sound/Voices/Voices 8.ogg"),
    preload("res://assets/sound/Voices/Voices 9.ogg"),
]
# events as pairs [weight, stream]
var _ambience_events_weighted: Array = [
    [2,  preload("res://assets/sound/Easter Eggs/Bird Cry 1.ogg")],
    [2,  preload("res://assets/sound/Easter Eggs/Bird Flapping 1.ogg")],
    [2,  preload("res://assets/sound/Easter Eggs/Peepers 1.ogg")],
    [5,  preload("res://assets/sound/Easter Eggs/Cricket Loop.ogg")],
    [5,  preload("res://assets/sound/Easter Eggs/Easter Eggs pen drop 1.ogg")],
    [10, preload("res://assets/sound/Easter Eggs/Random Ambience 1.ogg")],
    [10, preload("res://assets/sound/Easter Eggs/Random Ambience 2.ogg")],
    [10, preload("res://assets/sound/Easter Eggs/Random Ambience 3.ogg")],
    [10, preload("res://assets/sound/Easter Eggs/Random Ambience 4.ogg")],
]

# Child timers (create in _ready if not in scene)
var _track_timer: Timer
var _voice_timer: Timer
var _event_timer: Timer

# Track any spawned one-shots to stop/fade them on pause/override
var _active_players: Array[AudioStreamPlayer] = []

func _ready():
    _ensure_timers()
    call_deferred("_start_playing")

# --- Public API ---
func set_sources(ambience_dir: String, voices_dir: String, events_dir: String, event_weight_from_name := true) -> void:
    _ambience_dir = ambience_dir
    _voices_dir = voices_dir
    _events_dir = events_dir
    _event_weight_from_name = event_weight_from_name

func reload_sources() -> void:
    if _ambience_dir != "":
        _ambience_tracks = _load_audio_dir(_ambience_dir)
    if _voices_dir != "":
        _ambient_voices = _load_audio_dir(_voices_dir)
    if _events_dir != "":
        _ambience_events_weighted = _load_weighted_dir(_events_dir, _event_weight_from_name)

func pause_ambience(immediate := false) -> void:
    _paused = true
    _stop_timers()
    if immediate:
        if is_instance_valid(_current_player):
            _current_player.stop()
            _current_player.queue_free()
        _current_player = null
        for p in _active_players:
            if is_instance_valid(p):
                p.stop()
                p.queue_free()
        _active_players.clear()
    else:
        _fade_out_player(_current_player, fade_duration)
        _current_player = null
        for p in _active_players:
            _fade_out_player(p, min(fade_duration, 0.5))
        _active_players.clear()

func resume_ambience() -> void:
    _paused = false
    if _override_active:
        return
    _schedule_next_track()
    _schedule_next_voice()
    _schedule_next_event()

func play_override(stream: AudioStream, loop := false, fade := 0.5) -> void:
    _override_active = true
    _stop_timers()
    _fade_out_player(_current_player, fade)
    _current_player = null
    # If an override is already active, fade it out before starting the new one
    if _override_player and is_instance_valid(_override_player):
        _fade_out_player(_override_player, fade)
    for p in _active_players:
        _fade_out_player(p, min(fade, 0.5))
    _active_players.clear()
    _override_player = _create_player(stream, 0.0)
    _override_player.bus = ambience_bus
    if loop:
        # Try to enable loop on the stream if supported; fallback to manual loop
        var did_set := false
        if _override_player.stream and _override_player.stream.has_method("set_loop"):
            _override_player.stream.set_loop(true)
            did_set = true
        if not did_set:
            # manual loop
            _override_player.finished.connect(func():
                if is_instance_valid(_override_player):
                    _override_player.play()
            )

func clear_override(fade := 0.5) -> void:
    if _override_player and is_instance_valid(_override_player):
        _fade_out_player(_override_player, fade)
    _override_player = null
    _override_active = false
    if not _paused:
        _schedule_next_track()
        _schedule_next_voice()
        _schedule_next_event()

## Convenience helper: resolve a content-relative path and play override
## Example: play_override_from_content_path("audios/el_bosque.mp3", true, 0.75)
func play_override_from_content_path(path_rel: String, loop := true, fade := 0.5) -> bool:
    var rel := str(path_rel).strip_edges()
    if rel == "":
        return false
    var base := "res://content"
    var key := "moat/content_dir"
    if ProjectSettings.has_setting(key):
        var v = str(ProjectSettings.get_setting(key))
        if v != "":
            base = v
    # Accept both already absolute and relative forms
    var full_path := rel
    if not rel.begins_with("res://") and not rel.begins_with("user://"):
        full_path = base.path_join(rel)
    var res := ResourceLoader.load(full_path)
    if not (res is AudioStream):
        if OS.is_debug_build():
            push_warning("AmbienceController: could not load AudioStream at '" + full_path + "'")
        return false
    play_override(res, loop, fade)
    if OS.is_debug_build():
        print("AmbienceController: play_override_from_content_path src=", full_path)
    return true

func play_one_shot(stream: AudioStream, bus := "Ambience", volume_db := 0.0) -> void:
    var p = _create_player(stream, volume_db)
    p.bus = bus
    p.finished.connect(_on_one_shot_finished.bind(p))
    _active_players.append(p)

# --- Internals ---
func _start_playing():
    if _ambience_dir != "" or _voices_dir != "" or _events_dir != "":
        reload_sources()
    if _ambience_tracks.is_empty():
        push_warning("No ambience tracks available")
        return
    _current_player = _create_player(_random_track(), 0.0)
    _schedule_next_track()
    _schedule_next_voice()
    _schedule_next_event()

func _schedule_next_track():
    if _override_active or _paused:
        return
    _track_timer.stop()
    # Keep behavior driven by timer node; if scene already had $Timer, we reuse it
    if _track_timer.wait_time <= 0.0:
        _track_timer.wait_time = max(2.0, fade_duration + 0.1)
    _track_timer.start()

func _schedule_next_voice():
    if _override_active or _paused or _ambient_voices.is_empty():
        return
    _voice_timer.stop()
    _voice_timer.one_shot = true
    _voice_timer.wait_time = randi_range(ambient_voice_space_min, ambient_voice_space_max)
    if OS.is_debug_build():
        print("ambient voice delay=", _voice_timer.wait_time)
    _voice_timer.start()

func _schedule_next_event():
    if _override_active or _paused or _ambience_events_weighted.is_empty():
        return
    _event_timer.stop()
    _event_timer.one_shot = true
    _event_timer.wait_time = randi_range(ambience_event_space_min, ambience_event_space_max)
    if OS.is_debug_build():
        print("ambient event delay=", _event_timer.wait_time)
    _event_timer.start()

func _on_track_timeout():
    if _override_active or _paused:
        return
    var next_stream := _random_track()
    if _current_player and is_instance_valid(_current_player):
        _current_player = _fade_between(_current_player, next_stream, fade_duration)
    else:
        _current_player = _create_player(next_stream, 0.0)
    _schedule_next_track()

func _on_voice_timeout():
    if _override_active or _paused:
        return
    if _ambient_voices.is_empty():
        return
    var p = _create_player(_ambient_voices[randi() % _ambient_voices.size()], 0.0)
    if OS.is_debug_build():
        if p.stream and p.stream.resource_path != "":
            print("playing ambience voice. src=", p.stream.resource_path)
    p.finished.connect(_on_one_shot_finished.bind(p))
    _active_players.append(p)
    _schedule_next_voice()

func _on_event_timeout():
    if _override_active or _paused:
        return
    if _ambience_events_weighted.is_empty():
        return
    var p = _create_player(_pick_weighted_event(), 0.0)
    p.finished.connect(_on_one_shot_finished.bind(p))
    if OS.is_debug_build():
        if p.stream and p.stream.resource_path != "":
            print("playing ambience event. src=", p.stream.resource_path)
    _active_players.append(p)
    _schedule_next_event()

func _on_one_shot_finished(p: AudioStreamPlayer):
    _active_players.erase(p)
    _clean_player(p)

func _pick_weighted_event() -> AudioStream:
    var weight_sum := 0
    for ev in _ambience_events_weighted:
        weight_sum += int(ev[0])
    var choice = randi_range(1, max(1, weight_sum))
    for ev in _ambience_events_weighted:
        choice -= int(ev[0])
        if choice <= 0:
            return ev[1]
    return _ambience_events_weighted.back()[1]

func _random_track() -> AudioStream:
    return _ambience_tracks[randi() % _ambience_tracks.size()]

func _create_player(res: AudioStream, volume: float) -> AudioStreamPlayer:
    var audio := AudioStreamPlayer.new()
    audio.stream = res
    audio.volume_db = volume
    audio.autoplay = true
    audio.bus = ambience_bus
    add_child(audio)
    audio.play()
    return audio

func _fade_between(audio1, res2: AudioStream, duration: float) -> AudioStreamPlayer:
    var audio2 = _create_player(res2, -80.0)
    var tween = get_tree().create_tween()
    tween.tween_property(audio2, "volume_db", 0.0, duration)
    if audio1 and is_instance_valid(audio1) and (audio1 is AudioStreamPlayer):
        tween.tween_property(audio1, "volume_db", -80.0, duration)
        tween.finished.connect(_clean_player.bind(audio1))
    return audio2

func _fade_out_player(p: AudioStreamPlayer, duration := 0.5) -> void:
    if not p or not is_instance_valid(p):
        return
    var tween = get_tree().create_tween()
    tween.tween_property(p, "volume_db", -80.0, duration)
    tween.finished.connect(_clean_player.bind(p))

func _clean_player(audio1: AudioStreamPlayer):
    # Safely free a player and clear any references held by the controller.
    if audio1 and is_instance_valid(audio1):
        audio1.queue_free()
    # If this player was tracked as current/override/active, clear references
    if audio1 == _current_player:
        _current_player = null
    if audio1 == _override_player:
        _override_player = null
    if _active_players.has(audio1):
        _active_players.erase(audio1)

func _ensure_timers():
    # Try to reuse an existing Timer node named "Timer" for track changes if present
    if has_node("Timer") and not _track_timer:
        _track_timer = get_node("Timer") as Timer
        if not _track_timer.timeout.is_connected(_on_track_timeout):
            _track_timer.timeout.connect(_on_track_timeout)
    if not _track_timer:
        _track_timer = Timer.new()
        _track_timer.one_shot = true
        add_child(_track_timer)
        _track_timer.timeout.connect(_on_track_timeout)
    if not _voice_timer:
        _voice_timer = Timer.new()
        _voice_timer.one_shot = true
        add_child(_voice_timer)
        _voice_timer.timeout.connect(_on_voice_timeout)
    if not _event_timer:
        _event_timer = Timer.new()
        _event_timer.one_shot = true
        add_child(_event_timer)
        _event_timer.timeout.connect(_on_event_timeout)

func _stop_timers():
    if _track_timer:
        _track_timer.stop()
    if _voice_timer:
        _voice_timer.stop()
    if _event_timer:
        _event_timer.stop()

# --- Directory loading ---
static func _load_audio_dir(path: String) -> Array[AudioStream]:
    var exts := ["ogg", "wav", "mp3"]
    var out: Array[AudioStream] = []
    for f in DirAccess.get_files_at(path):
        var lower = f.to_lower()
        var ok := false
        for e in exts:
            if lower.ends_with("." + e):
                ok = true
                break
        if not ok:
            continue
        var res := ResourceLoader.load(path.path_join(f))
        if res is AudioStream:
            out.append(res)
    return out

static func _load_weighted_dir(path: String, parse_name := true) -> Array:
    var arr: Array = []
    for f in DirAccess.get_files_at(path):
        var full := path.path_join(f)
        var res := ResourceLoader.load(full)
        if not (res is AudioStream):
            continue
        var weight := 1
        if parse_name:
            var parts = f.split("__", false, 1)
            if parts.size() > 1 and parts[0].is_valid_int():
                weight = int(parts[0])
        arr.append([weight, res])
    return arr
