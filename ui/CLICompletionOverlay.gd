extends CanvasLayer

signal request_jump_to_plaque(id: String)

@export var double_tab_threshold := 0.35

@onready var prompt: LineEdit = $TopBar/HBox/Prompt
@onready var suggestions_panel: Panel = $SuggestionsPanel
@onready var suggestions: ItemList = $SuggestionsPanel/VBox/Suggestions
@onready var trees_panel: Panel = $TreesPanel
@onready var trees: ItemList = $TreesPanel/HSplit/Trees
@onready var tree_results: ItemList = $TreesPanel/HSplit/TreeResults

var catalog: Array = []
var filtered: Array = []
var last_tab_time := -1.0
var current_tree := "All"
var visuals := {}

func _ready() -> void:
    layer = 100
    hide()
    _load_visuals()
    prompt.text_submitted.connect(_on_prompt_submit)
    suggestions.item_activated.connect(_on_suggestion_activated)
    tree_results.item_activated.connect(_on_tree_result_activated)
    trees.item_selected.connect(_on_tree_changed)
    prompt.text_changed.connect(func(_t): _refilter())

func _load_visuals() -> void:
    var path := "res://content/meta/class_visuals.json"
    if ResourceLoader.exists(path):
        var f := FileAccess.open(path, FileAccess.READ)
        if f:
            var txt := f.get_as_text()
            var json: Variant = JSON.parse_string(txt)
            if typeof(json) == TYPE_DICTIONARY:
                visuals = json

func set_catalog(entries: Array) -> void:
    catalog = entries
    _refilter()

func open() -> void:
    visible = true
    trees_panel.visible = false
    suggestions_panel.visible = true
    prompt.text = ""
    prompt.grab_focus()
    _refilter()

func close() -> void:
    visible = false

func toggle_trees() -> void:
    trees_panel.visible = !trees_panel.visible
    suggestions_panel.visible = !trees_panel.visible
    if trees_panel.visible:
        _build_trees()

func _unhandled_input(event: InputEvent) -> void:
    if Util.is_xr():
        return
    if event is InputEventKey and event.pressed:
        # Tab to open/toggle
        if event.physical_keycode == KEY_TAB:
            if !visible:
                open()
                last_tab_time = Time.get_ticks_msec() / 1000.0
                get_viewport().set_input_as_handled()
                return
            var now = Time.get_ticks_msec() / 1000.0
            if last_tab_time > 0 and (now - last_tab_time) <= double_tab_threshold:
                toggle_trees()
                last_tab_time = -1.0
            else:
                last_tab_time = now
            get_viewport().set_input_as_handled()
            return
        # Additional open gestures: Up/Down to open overlay and move selection
        if !visible and (event.physical_keycode == KEY_UP or event.physical_keycode == KEY_DOWN):
            open()
            # select first item so the user can immediately navigate
            if suggestions.item_count > 0:
                suggestions.select(0)
            get_viewport().set_input_as_handled()
            return

    if visible:
        if event.is_action_pressed("ui_cancel"):
            close()
            get_viewport().set_input_as_handled()
            return
        if event is InputEventKey and event.pressed and !trees_panel.visible:
            match event.physical_keycode:
                KEY_UP:
                    _move_selection(-1)
                    get_viewport().set_input_as_handled()
                KEY_DOWN:
                    _move_selection(1)
                    get_viewport().set_input_as_handled()
                KEY_ENTER, KEY_KP_ENTER:
                    _activate_selected_suggestion()
                    get_viewport().set_input_as_handled()

func _move_selection(delta: int) -> void:
    var sel := suggestions.get_selected_items()
    var idx := 0 if sel.is_empty() else sel[0]
    idx = clamp(idx + delta, 0, max(0, suggestions.item_count - 1))
    if suggestions.item_count > 0:
        suggestions.select(idx)
        suggestions.ensure_current_is_visible()

func _on_prompt_submit(_text: String) -> void:
    _activate_selected_suggestion()

func _activate_selected_suggestion() -> void:
    var sel := suggestions.get_selected_items()
    if sel.is_empty():
        return
    var entry = filtered[sel[0]]
    request_jump_to_plaque.emit(str(entry.get("id", "")))
    close()

func _on_suggestion_activated(index: int) -> void:
    var entry = filtered[index]
    request_jump_to_plaque.emit(str(entry.get("id", "")))
    close()

func _on_tree_result_activated(index: int) -> void:
    var entry = _tree_entries()[index]
    request_jump_to_plaque.emit(str(entry.get("id", "")))
    close()

func _on_tree_changed(index: int) -> void:
    current_tree = trees.get_item_text(index)
    _rebuild_tree_results()

func _refilter() -> void:
    var q := prompt.text.strip_edges().to_lower()
    filtered.clear()
    for e in catalog:
        if _passes_tree_filter(e):
            var label := str(e.get("label", ""))
            var path := str(e.get("path", ""))
            if q == "" or label.to_lower().find(q) != -1 or path.to_lower().find(q) != -1:
                filtered.append(e)
    _rebuild_suggestions()

func _rebuild_suggestions() -> void:
    suggestions.clear()
    var i := 0
    for e in filtered:
        var text = "%s %s  [%s]" % [emoji_for(e), str(e.get("label", "")), str(e.get("path", ""))]
        suggestions.add_item(text)
        var color = _color_for_class(str(e.get("class_name", "")))
        suggestions.set_item_custom_fg_color(i, color)
        i += 1
    if suggestions.item_count > 0:
        suggestions.select(0)

func _build_trees() -> void:
    trees.clear()
    trees.add_item("All")
    trees.add_item("Knowledge Domains")
    trees.add_item("Projects")
    trees.add_item("Classes")
    trees.select(0)
    current_tree = "All"
    _rebuild_tree_results()

func _passes_tree_filter(e: Dictionary) -> bool:
    var cls := str(e.get("class_name", ""))
    match current_tree:
        "All":
            return true
        "Knowledge Domains":
            return cls == "knowledgeDomain"
        "Projects":
            return cls == "project"
        "Classes":
            # Entries originating from meta/classes ingestion tag themselves
            return str(e.get("source", "")) == "meta_classes"
        _:
            return true

func _tree_entries() -> Array:
    var arr: Array = []
    var q := prompt.text.strip_edges().to_lower()
    for e in catalog:
        if _passes_tree_filter(e):
            var label := str(e.get("label", ""))
            var path := str(e.get("path", ""))
            if q == "" or label.to_lower().find(q) != -1 or path.to_lower().find(q) != -1:
                arr.append(e)
    return arr

func _rebuild_tree_results() -> void:
    tree_results.clear()
    var i := 0
    for e in _tree_entries():
        var text = "%s %s  [%s]" % [emoji_for(e), str(e.get("label", "")), str(e.get("path", ""))]
        tree_results.add_item(text)
        var color = _color_for_class(str(e.get("class_name", "")))
        tree_results.set_item_custom_fg_color(i, color)
        i += 1

func _color_for_class(cls: String) -> Color:
    if visuals.has("class_colors") and visuals.class_colors.has(cls):
        return Color(visuals.class_colors[cls])
    if visuals.has("class_defaults") and visuals.class_defaults.has("fallback_color"):
        return Color(visuals.class_defaults.fallback_color)
    return Color.WHITE

func emoji_for(entry: Dictionary) -> String:
    var icon_key := str(entry.get("icon_key", ""))
    if visuals.has("icon_emoji") and visuals.icon_emoji.has(icon_key):
        return str(visuals.icon_emoji[icon_key])
    var cls := str(entry.get("class_name", ""))
    if visuals.has("class_defaults") and visuals.class_defaults.has("emoji") and visuals.class_defaults.emoji.has(cls):
        return str(visuals.class_defaults.emoji[cls])
    if visuals.has("class_defaults") and visuals.class_defaults.has("fallback_emoji"):
        return str(visuals.class_defaults.fallback_emoji)
    return "📍"
