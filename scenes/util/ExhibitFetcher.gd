extends Node

# Signals preserved for compatibility
signal search_complete(title, context)
signal random_complete(title, context)
signal wikitext_complete(titles, context)
signal wikitext_failed(titles, message)

# In-memory results only (no disk cache)
var _results: Dictionary = {}

# Simple index of local markdown by title (lowercased)
var _md_index: Dictionary = {}
var _indexed: bool = false

# Configurable content root directory. Defaults to res://content
func _get_content_dir() -> String:
    var key := "moat/content_dir"
    if ProjectSettings.has_setting(key):
        var v = str(ProjectSettings.get_setting(key))
        if v != "":
            return v
    return "res://content"

func set_language(_language: String):
    # No-op for local content strategy; kept for compatibility
    pass

func _build_index():
    if _indexed:
        return
    _indexed = true
    _md_index.clear()
    _index_dir(_get_content_dir(), "")

func _index_dir(root_path: String, rel_path: String) -> void:
    var dir := DirAccess.open(root_path)
    if not dir:
        push_error("ExhibitFetcher: cannot open directory: %s" % root_path)
        return
    dir.list_dir_begin()
    while true:
        var name = dir.get_next()
        if name == "":
            break
        if name == "." or name == "..":
            continue
        var full_path = root_path + "/" + name
        if dir.current_is_dir():
            # Skip folders we don't want as exhibits
            var lower = name.to_lower()
            if lower == "meta" or lower == "rels":
                continue
            # Skip hidden/system folders
            if name.begins_with("."):
                continue
            var next_rel = name if rel_path == "" else rel_path + "/" + name
            _index_dir(full_path, next_rel)
        else:
            if name.to_lower().ends_with(".md"):
                var base = name.substr(0, name.length() - 3)
                var rel_key = base if rel_path == "" else rel_path + "/" + base
                var path_lc = rel_key.to_lower()
                var base_lc = base.to_lower()
                var full = full_path
                # Add relative-path key (e.g., "pizarras/index")
                _md_index[path_lc] = full
                # Add normalized relative variant (underscores->spaces) to help matching
                var norm_rel = _normalize_title(rel_key).to_lower()
                _md_index[norm_rel] = full
                # Add basename key only if unique to avoid clobbering common names like "index"
                if not _md_index.has(base_lc):
                    _md_index[base_lc] = full
                var norm_base = _normalize_title(base).to_lower()
                if not _md_index.has(norm_base):
                    _md_index[norm_base] = full
    dir.list_dir_end()

func _normalize_title(title: String) -> String:
    var new_title = title.replace("_", " ").uri_decode()
    var title_fragments = new_title.split("#")
    return title_fragments[0]

func _find_markdown_for_title(title: String) -> String:
    _build_index()
    if title == "":
        return ""
    var raw := str(title).strip_edges()
    # Strip common markdown extension if author provided it
    if raw.to_lower().ends_with(".md"):
        raw = raw.substr(0, raw.length() - 3)
    elif raw.to_lower().ends_with(".markdown"):
        raw = raw.substr(0, raw.length() - 9)

    # Normalize slashes and remove leading content path if any
    raw = raw.replace("\\", "/")
    if raw.begins_with("res://"):
        raw = raw.trim_prefix("res://")
    # If the input included the configured content root name, strip it.
    var inv_root := _get_content_dir()
    var inv_name := inv_root.get_file() # e.g., "content"
    if inv_name != "" and raw.begins_with(inv_name + "/"):
        raw = raw.substr((inv_name + "/").length())

    var t_norm = _normalize_title(raw).to_lower()
    var t_raw = raw.to_lower()

    # Try exact matches in the index for several variants
    for key in [t_raw, t_norm]:
        if _md_index.has(key):
            return _md_index[key]

    # Also try replacing spaces/underscores heuristically
    var swap_space = t_raw.replace(" ", "_")
    var swap_us = t_raw.replace("_", " ")
    for key2 in [swap_space, swap_us]:
        if _md_index.has(key2):
            return _md_index[key2]

    # Fallback: contains match over keys (least preferred)
    for k in _md_index.keys():
        if k.find(t_raw) >= 0 or k.ends_with("/" + t_raw) or k.ends_with("/" + t_norm):
            return _md_index[k]
    return ""

func _read_file_text(path: String) -> String:
    var f = FileAccess.open(path, FileAccess.READ)
    if not f:
        return ""
    var txt = f.get_as_text()
    f.close()
    return txt

func _parse_frontmatter(md: String) -> Dictionary:
    var fm: Dictionary = {}
    if md.begins_with("---\n"):
        var end = md.find("\n---\n", 4)
        if end >= 0:
            var yml = md.substr(4, end - 4)
            for line in yml.split("\n"):
                var ln = line.strip_edges()
                if ln == "" or ln.begins_with("#"):
                    continue
                var sep = ln.find(":")
                if sep > 0:
                    var key = ln.substr(0, sep).strip_edges()
                    var value = ln.substr(sep + 1).strip_edges()
                    # simple list support: key: [a, b]
                    if value.begins_with("[") and value.ends_with("]"):
                        var arr = []
                        var inner = value.substr(1, value.length() - 2)
                        for v in inner.split(","):
                            arr.append(v.strip_edges().trim_prefix("\"").trim_suffix("\""))
                        fm[key] = arr
                    else:
                        fm[key] = value.trim_prefix("\"").trim_suffix("\"")
            # remove frontmatter from md
    return fm

func _strip_frontmatter(md: String) -> String:
    if md.begins_with("---\n"):
        var end = md.find("\n---\n", 4)
        if end >= 0:
            return md.substr(end + 5)
    return md

func _extract_images_from_md(md_path: String, body_md: String) -> Array:
    # returns array of dictionaries: { title: "File:xxx.ext", src: url, alt: caption }
    var images: Array = []
    var seen: Dictionary = {}
    var parent_dir = md_path.get_base_dir()

    # Regex for markdown images ![alt](src)
    var re = RegEx.new()
    re.compile("!\\[(.*?)\\]\\((.*?)\\)")
    for m in re.search_all(body_md):
        var alt = m.get_string(1)
        var src = m.get_string(2)
        var url = _resolve_path(parent_dir, src)
        var title = _file_title_from_url(url)
        if title != "" and not seen.has(title):
            images.append({ "title": title, "src": url, "alt": alt })
            seen[title] = true

    # Obsidian-style image embeds ![[filename]] or ![[filename|Caption]]
    var re_obs = RegEx.new()
    re_obs.compile("!\\[\\[(.+?)\\]\\]")
    for m_obs in re_obs.search_all(body_md):
        var inner = m_obs.get_string(1)
        var alt2 = ""
        var src2 = inner
        var pipe_idx = inner.find("|")
        if pipe_idx >= 0:
            src2 = inner.substr(0, pipe_idx)
            alt2 = inner.substr(pipe_idx + 1)
        var url2 = _resolve_path(parent_dir, src2.strip_edges())
        var title2 = _file_title_from_url(url2)
        if not seen.has(title2):
            images.append({ "title": title2, "src": url2, "alt": alt2.strip_edges() })
            seen[title2] = true

    # Also handle bare <img src="...">
    var re2 = RegEx.new()
    re2.compile("<img\\s+[^>]*src=\\\"([^\\\"]+)\\\"[^>]*>")
    for m2 in re2.search_all(body_md):
        var url2 = _resolve_path(parent_dir, m2.get_string(1))
        var title2 = _file_title_from_url(url2)
        if title2 != "" and not seen.has(title2):
            images.append({ "title": title2, "src": url2, "alt": "" })
            seen[title2] = true

    return images

func _extract_links_from_frontmatter(fm: Dictionary) -> Array:
    # Extract Obsidian-style links like "[[Target]]" from any frontmatter
    # value. We only keep links that point to actual top-level exhibits
    var links: Array = []
    var re = RegEx.new()
    re.compile("\\[\\[([^\\]]+)\\]\\]")
    for key in fm.keys():
        var value = fm[key]
        if typeof(value) == TYPE_STRING:
            var s = str(value)
            for m in re.search_all(s):
                var raw = m.get_string(1).strip_edges()
                if raw == "":
                    continue
                # Support alias: [[target|Label]] — keep label if provided
                var target = raw
                var label = ""
                var pipe_idx = raw.find("|")
                if pipe_idx >= 0:
                    target = raw.substr(0, pipe_idx).strip_edges()
                    label = raw.substr(pipe_idx + 1).strip_edges()
                # Strip common markdown extension
                var tl = target.to_lower()
                if tl.ends_with(".md"):
                    target = target.substr(0, target.length() - 3)
                elif tl.ends_with(".markdown"):
                    target = target.substr(0, target.length() - 9)
                var title = _normalize_title(target)
                if title == "":
                    continue
                # Only keep links that resolve to a real exhibit markdown file
                if _find_markdown_for_title(title) == "":
                    if _find_markdown_for_title(target) == "":
                        continue
                    title = target
                # Append as dict when we have a label; otherwise keep legacy string
                if label != "":
                    var entry = {"title": title, "label": label}
                    var exists = false
                    for e in links:
                        if typeof(e) == TYPE_DICTIONARY and e.has("title") and e.title == entry.title and e.get("label", "") == entry.label:
                            exists = true
                            break
                        elif typeof(e) == TYPE_STRING and e == title and label == "":
                            exists = true
                            break
                    if not exists:
                        links.append(entry)
                else:
                    if not links.has(title):
                        links.append(title)
        elif typeof(value) == TYPE_ARRAY:
            for entry in value:
                var s2 = str(entry)
                for m2 in re.search_all(s2):
                    var raw2 = m2.get_string(1).strip_edges()
                    if raw2 == "":
                        continue
                    var target2 = raw2
                    var label2 = ""
                    var pipe2 = raw2.find("|")
                    if pipe2 >= 0:
                        target2 = raw2.substr(0, pipe2).strip_edges()
                        label2 = raw2.substr(pipe2 + 1).strip_edges()
                    var tl2 = target2.to_lower()
                    if tl2.ends_with(".md"):
                        target2 = target2.substr(0, target2.length() - 3)
                    elif tl2.ends_with(".markdown"):
                        target2 = target2.substr(0, target2.length() - 9)
                    var title2 = _normalize_title(target2)
                    if title2 == "":
                        continue
                    if _find_markdown_for_title(title2) == "":
                        if _find_markdown_for_title(target2) == "":
                            continue
                        title2 = target2
                    if label2 != "":
                        var entry2 = {"title": title2, "label": label2}
                        var exists2 = false
                        for e2 in links:
                            if typeof(e2) == TYPE_DICTIONARY and e2.has("title") and e2.title == entry2.title and e2.get("label", "") == entry2.label:
                                exists2 = true
                                break
                            elif typeof(e2) == TYPE_STRING and e2 == title2 and label2 == "":
                                exists2 = true
                                break
                        if not exists2:
                            links.append(entry2)
                    else:
                        if not links.has(title2):
                            links.append(title2)
    return links

func _extract_links_from_md(body_md: String) -> Array:
    # Extract internal links from markdown content.
    #
    # We support two syntaxes:
    #   - Obsidian-style wiki links: [[Target]]
    #   - Standard markdown links: [label](Target)
    #
    # Only links that resolve to actual exhibit markdown files under
    # the content dir are returned.
    var links: Array = []

    # 1) Obsidian-style [[Target]] links
    var re_wiki = RegEx.new()
    re_wiki.compile("\\[\\[([^\\]]+)\\]\\]")
    for m in re_wiki.search_all(body_md):
        var raw = m.get_string(1).strip_edges()
        if raw == "":
            continue
        # Support alias: [[target|Label]]
        var target = raw
        var label = ""
        var pipe_idx = raw.find("|")
        if pipe_idx >= 0:
            target = raw.substr(0, pipe_idx).strip_edges()
            label = raw.substr(pipe_idx + 1).strip_edges()
        # Strip extension if provided
        var tl = target.to_lower()
        if tl.ends_with(".md"):
            target = target.substr(0, target.length() - 3)
        elif tl.ends_with(".markdown"):
            target = target.substr(0, target.length() - 9)

        # Keep slashes for subdirectories; normalize other aspects
        var title = _normalize_title(target)
        if title == "":
            continue
        if _find_markdown_for_title(title) == "":
            # Try the raw target as a last resort (path-like key)
            if _find_markdown_for_title(target) == "":
                continue
            title = target
        if label != "":
            var entry = {"title": title, "label": label}
            var exists = false
            for e in links:
                if typeof(e) == TYPE_DICTIONARY and e.has("title") and e.title == entry.title and e.get("label", "") == entry.label:
                    exists = true
                    break
                elif typeof(e) == TYPE_STRING and e == title and label == "":
                    exists = true
                    break
            if not exists:
                links.append(entry)
        else:
            if not links.has(title):
                links.append(title)

    # 2) Standard markdown [label](Target) links for completeness
    var re_md = RegEx.new()
    re_md.compile("\\[([^\\]]+)\\]\\(([^)]+)\\)")
    for m2 in re_md.search_all(body_md):
        var target = m2.get_string(2).strip_edges()
        if target == "":
            continue
        # Skip external URLs and anchors
        if target.find("://") >= 0:
            continue
        if target.begins_with("#") or target.begins_with("mailto:"):
            continue
        # Skip obvious image/file targets by extension
        var tl = target.to_lower()
        if tl.ends_with(".png") or tl.ends_with(".jpg") or tl.ends_with(".jpeg") or tl.ends_with(".webp") or tl.ends_with(".svg"):
            continue
        # Strip common markdown extensions so "Doc.md" becomes "Doc"
        if tl.ends_with(".md"):
            target = target.substr(0, target.length() - 3)
        elif tl.ends_with(".markdown"):
            target = target.substr(0, target.length() - 9)
        var title2 = _normalize_title(target)
        if title2 == "":
            continue
        if _find_markdown_for_title(title2) == "":
            continue
        # Use the markdown link label if present (group 1)
        var label2 = m2.get_string(1).strip_edges()
        if label2 != "":
            var entry_md = {"title": title2, "label": label2}
            var exists_md = false
            for e3 in links:
                if typeof(e3) == TYPE_DICTIONARY and e3.has("title") and e3.title == entry_md.title and e3.get("label", "") == entry_md.label:
                    exists_md = true
                    break
                elif typeof(e3) == TYPE_STRING and e3 == title2 and label2 == "":
                    exists_md = true
                    break
            if not exists_md:
                links.append(entry_md)
        else:
            if not links.has(title2):
                links.append(title2)

    return links

func _resolve_path(base_dir: String, path: String) -> String:
    # Normalize trivial surrounding spaces
    var p := str(path).strip_edges()
    # Absolute/resource/remote URLs as-is
    if p.begins_with("res://") or p.begins_with("user://") or p.begins_with("http://") or p.begins_with("https://"):
        return p
    if p.begins_with("/"):
        # Absolute within project
        return "res://" + p.trim_prefix("/")

    # Relative to the markdown file directory
    var base_norm := base_dir
    if base_norm.ends_with("/"):
        base_norm = base_norm.substr(0, base_norm.length() - 1)
    var p_norm := p
    if p_norm.begins_with("/"):
        p_norm = p_norm.trim_prefix("/")
    var candidate := base_norm + "/" + p_norm
    # Fast path if it exists exactly as written
    if FileAccess.file_exists(candidate):
        return candidate

    # Try a case-insensitive match in the target directory to be robust
    # against .JPG vs .jpg, etc. This helps when authoring markdown by hand.
    var subdir := p.get_base_dir()
    var fname := p.get_file()
    var search_dir := base_norm
    if subdir != "":
        var sub_norm := subdir
        if sub_norm.begins_with("/"):
            sub_norm = sub_norm.trim_prefix("/")
        search_dir = base_norm + "/" + sub_norm
    search_dir = search_dir.simplify_path()
    var da := DirAccess.open(search_dir)
    if da:
        da.list_dir_begin()
        var lower_target := fname.to_lower()
        while true:
            var entry = da.get_next()
            if entry == "":
                break
            if entry == "." or entry == "..":
                continue
            if da.current_is_dir():
                continue
            if entry.to_lower() == lower_target:
                da.list_dir_end()
                var resolved_dir := search_dir
                if resolved_dir.ends_with("/"):
                    resolved_dir = resolved_dir.substr(0, resolved_dir.length() - 1)
                return resolved_dir + "/" + entry
        da.list_dir_end()

    # Heuristic: some generated indexes repeat part of the current folder path
    # as the first segment(s) of the embed (e.g., base=".../cuadernos/revisiones/una"
    # and path="revisiones/una/IMG_3879.JPG"). Strip the longest matching prefix
    # of the embed that equals the trailing segments of base_dir (case-insensitive)
    # and retry resolution under base_dir.
    var p_parts: PackedStringArray = p_norm.split("/")
    var base_parts: PackedStringArray = base_norm.split("/")
    var max_k: int = min(p_parts.size(), base_parts.size())
    for k in range(max_k, 0, -1):
        var matches: bool = true
        for i in range(k):
            var a: String = str(p_parts[i]).to_lower()
            var b: String = str(base_parts[base_parts.size() - k + i]).to_lower()
            if a != b:
                matches = false
                break
        if matches:
            var stripped: String = ""
            for j in range(k, p_parts.size()):
                if stripped != "":
                    stripped += "/"
                stripped += str(p_parts[j])
            if stripped != "":
                var candidate2: String = base_norm + "/" + stripped
                if FileAccess.file_exists(candidate2):
                    return candidate2
                # Case-insensitive search under the derived search directory
                var subdir2: String = stripped.get_base_dir()
                var fname2: String = stripped.get_file()
                var search_dir2: String = base_norm
                if subdir2 != "":
                    var sub_norm2: String = subdir2
                    if sub_norm2.begins_with("/"):
                        sub_norm2 = sub_norm2.trim_prefix("/")
                    search_dir2 = (base_norm + "/" + sub_norm2).simplify_path()
                var da2 := DirAccess.open(search_dir2)
                if da2:
                    da2.list_dir_begin()
                    var lower_target2: String = fname2.to_lower()
                    while true:
                        var entry2 = da2.get_next()
                        if entry2 == "":
                            break
                        if entry2 == "." or entry2 == "..":
                            continue
                        if da2.current_is_dir():
                            continue
                        if entry2.to_lower() == lower_target2:
                            da2.list_dir_end()
                            var resolved_dir2: String = search_dir2
                            if resolved_dir2.ends_with("/"):
                                resolved_dir2 = resolved_dir2.substr(0, resolved_dir2.length() - 1)
                            return resolved_dir2 + "/" + entry2
                    da2.list_dir_end()
            break

    # Fallback to the original candidate (even if missing); downstream may handle it
    return candidate

func _file_title_from_url(url: String) -> String:
    # Turn a URL or path into a MediaWiki-like File: title for compatibility
    var fname = url.get_file()
    if fname == "":
        return ""
    return "File:" + fname

func _compose_wikitext_from_images(images: Array) -> String:
    var parts: Array = []
    for img in images:
        var title = img.get("title", "")
        var alt = img.get("alt", "")
        if title != "":
            var s = "[[%s" % title
            if alt != "":
                s += "|alt=%s" % alt
            s += "]]\n"
            parts.append(s)
    return "".join(parts)

func _store_image_results(images: Array) -> void:
    for img in images:
        var title = img.get("title", "")
        if title != "":
            var src: String = str(img.get("src", ""))
            var entry: Dictionary = { "src": src }
            # Detect JSON/GeoJSON sidecar next to the image (same basename)
            var sidecar := _find_sidecar_for_image(src)
            if sidecar != "":
                entry["sidecar_url"] = sidecar
            _results[title] = entry

# Look for a sidecar file with the same basename and .json or .geojson extension
func _find_sidecar_for_image(src: String) -> String:
    if src == "":
        return ""
    var base_dir := src.get_base_dir()
    var fname := src.get_file()
    if fname == "":
        return ""
    var dot := fname.rfind(".")
    var stem := fname if dot < 0 else fname.substr(0, dot)
    var candidates = [base_dir + "/" + stem + ".json", base_dir + "/" + stem + ".geojson"]
    for c in candidates:
        if FileAccess.file_exists(c):
            return c
    return ""

func fetch(titles, ctx):
    # Synchronously load local markdown files and emit results
    var missing: Array = []
    for raw_title in titles:
        var title: String = _normalize_title(str(raw_title))
        if title == "":
            continue
        var path = _find_markdown_for_title(title)
        if path == "":
            missing.append(title)
            continue
        var md = _read_file_text(path)
        var fm = _parse_frontmatter(md)
        var body = _strip_frontmatter(md)

        # collect images from frontmatter and body
        var images: Array = []
        if fm.has("image"):
            images.append({ "title": _file_title_from_url(_resolve_path(path.get_base_dir(), str(fm.image))), "src": _resolve_path(path.get_base_dir(), str(fm.image)), "alt": "" })
        if fm.has("images") and typeof(fm.images) == TYPE_ARRAY:
            for img_path in fm.images:
                var url = _resolve_path(path.get_base_dir(), str(img_path))
                images.append({ "title": _file_title_from_url(url), "src": url, "alt": "" })
        images.append_array(_extract_images_from_md(path, body))

        # Collect links to other exhibits from frontmatter and markdown body
        var links: Array = []
        links.append_array(_extract_links_from_frontmatter(fm))
        links.append_array(_extract_links_from_md(body))

        # Build a simple result understood by ItemProcessor
        var wikitext_images = _compose_wikitext_from_images(images)
        var extract_text = body # Keep markdown; ItemProcessor formats text plaques from extract
        # ordered_text tells ItemProcessor to keep text panels in source
        # order and ensure the full document content is used.
        var result: Dictionary = {
            "wikitext": wikitext_images,
            "extract": extract_text,
            "ordered_text": true,
        }
        if links.size() > 0:
            result["links"] = links
        _results[title] = result

        # make image lookups available to ImageItem
        _store_image_results(images)
        if OS.is_debug_build():
            print("[ExhibitFetcher]: _results ",_results)
        

    if missing.size() > 0:
        call_deferred("emit_signal", "wikitext_failed", missing, "Missing")
    call_deferred("emit_signal", "wikitext_complete", titles, ctx)

func fetch_search(title, ctx):
    _build_index()
    var t = _normalize_title(str(title)).to_lower()
    var found: String = ""
    if _md_index.has(t):
        # Use the stored file path to return the canonical title
        var path_ok = _md_index[t]
        found = path_ok.get_file().substr(0, path_ok.get_file().length() - 3)
    else:
        for k in _md_index.keys():
            if k.find(t) >= 0:
                var path2 = _md_index[k]
                found = path2.get_file().substr(0, path2.get_file().length() - 3)
                break
    call_deferred("emit_signal", "search_complete", (found if found != "" else null), ctx)

func fetch_random(ctx):
    _build_index()
    var keys = _md_index.keys()
    if keys.size() == 0:
        call_deferred("emit_signal", "random_complete", null, ctx)
        return
    var rng = RandomNumberGenerator.new()
    rng.randomize()
    var pick_key: String = keys[rng.randi() % keys.size()]
    # turn back into display title
    var file_path = _md_index[pick_key]
    var title = file_path.get_file().substr(0, file_path.get_file().length() - 3)
    call_deferred("emit_signal", "random_complete", title, ctx)

func get_result(title):
    var raw = str(title)
    # Important: For local file titles, preserve exact key including underscores.
    # The results dictionary stores image entries under the exact "File:..." name
    # derived from the filesystem. Normalizing (replacing '_' with ' ') breaks
    # lookups for filenames with underscores. For non-file titles (exhibits),
    # keep the normalization behavior.
    if raw.begins_with("File:"):
        return _results.get(raw)
    var t = _normalize_title(raw)
    if _results.has(t):
        return _results[t]
    return null
