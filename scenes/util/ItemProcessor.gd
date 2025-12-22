extends Node

signal items_complete

var ignore_sections = [
  "references",
  "see also",
  "notes",
  "further reading",
  "external links",
  "external link s",
  "bibliography",
  "gallery",
  "sources",
]

var IMAGE_REGEX = RegEx.new()
var s2_re = RegEx.new()
var template_re = RegEx.new()
var links_re = RegEx.new()
var extlinks_re = RegEx.new()
var em_re = RegEx.new()
var tag_re = RegEx.new()
var whitespace_re = RegEx.new()
var nl_re = RegEx.new()
var alt_re = RegEx.new()
var tokenizer = RegEx.new()
var image_name_re = RegEx.new()
var image_field_re = RegEx.new()
var exclude_image_re = RegEx.new()
var md_bold_re = RegEx.new()
var md_italic_re = RegEx.new()
var md_list_re = RegEx.new()
var obs_image_re = RegEx.new()
var obs_link_with_alias_re = RegEx.new()
var obs_link_simple_re = RegEx.new()

var max_len_soft = 1000
# To ensure rich_text plaques never get visually truncated, we will also
# enforce a soft cap on the number of paragraphs per plaque. If adding the
# next paragraph would exceed either the character soft limit or this count,
# we flush the current plaque and start a new one (preserving the subtitle
# so long epigraphs carry over across overflow panels).
var max_paras_per_plaque = 8
var text_item_fmt = "[color=black][b][font_size=48]%s[/font_size][/b]\n\n%s"
var section_fmt = "[p][b][font_size=36]%s[/font_size][/b][/p]\n\n"
var p_fmt = "[p]%s[/p]\n\n"

var processor_thread: Thread
var PROCESSOR_QUEUE = "ItemProcessor"

func _ready():
  # Match common image extensions case-insensitively so .JPG/.PNG also work
  # (cuadernos uses upper-case JPG names).
  IMAGE_REGEX.compile("(?i)\\.(png|jpg|jpeg|webp|svg|gif|bmp|tif|tiff|avif)$")
  s2_re.compile("^==[^=]")
  template_re.compile("\\{\\{.*?\\}\\}")
  links_re.compile("\\[\\[([^|\\]]*?\\|)?(.*?)\\]\\]")
  extlinks_re.compile("\\[http[^\\s]*\\s(.*?)\\]")
  em_re.compile("'{2,}")
  tag_re.compile("<[^>]+>")
  whitespace_re.compile("[\t ]+")
  nl_re.compile("\n+")
  # Capture Obsidian/Wiki alt text up to the next pipe OR end of link.
  # Previously we required a trailing pipe, which failed for patterns like
  # [[File:foo.jpg|alt=My Caption]] (no trailing pipe). By stopping at either
  # a pipe or end-of-string, we correctly extract "My Caption".
  alt_re.compile("alt=([^|]+)")
  #image_field_re.compile("(photo|image\\|?)[^_\\|]*?=(.+?)(\\||$)")
  image_field_re.compile("[\\|=]\\s*([^\\n|=]+\\.\\w{,4})")
  #image_field_re.compile("photo")
  tokenizer.compile("[^\\{\\}\\[\\]<>]+|[\\{\\}\\[\\]<>]")
  image_name_re.compile("^([iI]mage:|[fF]ile:)")
  exclude_image_re.compile("\\bicon\\b|\\blogo\\b|blue pencil")
  # Basic Markdown inline formatting (used for local markdown exhibits)
  md_bold_re.compile("\\*\\*([^*]+)\\*\\*")
  md_italic_re.compile("\\*([^*]+)\\*")
  # Markdown unordered list items: lines starting with optional whitespace and "- "
  md_list_re.compile("^\\s*-\\s+(.*\\S.*)$")
  # Obsidian-style image embeds and links
  # Image embeds: ![[filename]] or ![[filename|Caption]] — to be removed from text
  obs_image_re.compile("!\\[\\[[^\\]]+\\]\\]")
  # Links with alias: [[target|Label]] -> bold Label
  obs_link_with_alias_re.compile("\\[\\[[^\\]|]+\\|([^\\]]+)\\]\\]")
  # Simple links: [[Target]] -> bold Target
  obs_link_simple_re.compile("\\[\\[([^\\]|]+)\\]\\]")

  if Util.is_using_threads():
    processor_thread = Thread.new()
    processor_thread.start(_processor_thread_loop)

func _exit_tree():
  WorkQueue.set_quitting()
  if processor_thread:
    processor_thread.wait_to_finish()

func _processor_thread_loop():
  while not WorkQueue.get_quitting():
    _processor_thread_item()

func _process(delta: float) -> void:
  if not Util.is_using_threads():
    _processor_thread_item()

func _processor_thread_item():
    var item = WorkQueue.process_queue(PROCESSOR_QUEUE)
    if item:
      _create_items(item[0], item[1], item[2])

func _seeded_shuffle(seed, arr, bias=false):
  var rng = RandomNumberGenerator.new()
  rng.seed = hash(seed)
  if not bias:
    Util.shuffle(rng, arr)
  else:
    Util.biased_shuffle(rng, arr, 2.0)

func _to_link_case(s):
  if len(s) > 0:
    return s[0].to_upper() + s.substr(1)
  else:
    return ""

func _add_text_item(items, title, subtitle, text):
  # Always add the text item unless the whole section is in the ignore list.
  # Previously we dropped very short fragments (len(text) <= 20), which caused
  # the tail of some local markdown documents to disappear if the last plaque
  # happened to be short. This change ensures we never "eat" content, matching
  # the expectation that exhibits show the full markdown.
  if (
    not ignore_sections.has(title.to_lower().strip_edges())
  ):
    var t = ((section_fmt % subtitle) + "\n" + text) if subtitle != "" else text
    items.append({
      "type": "rich_text",
      "material": "marble",
      "text": text_item_fmt % [title, t]
    })

func _clean_section(s):
  return s.replace("=", "").strip_edges()

var trim_filename_front = len("File:")
func _clean_filename(s):
  return IMAGE_REGEX.sub(s.substr(trim_filename_front), "")

func _apply_markdown_inline(line: String) -> String:
  var t = line
  if len(t) == 0:
    return t
  # Apply bold first, then italics, so nested patterns work reasonably well
  t = md_bold_re.sub(t, "[b]$1[/b]", true)
  t = md_italic_re.sub(t, "[i]$1[/i]", true)
  return t

# Split a long plain text paragraph into chunks no longer than limit.
# We prefer breaking at spaces; if no space exists within the window,
# we fall back to a hard split.
func _split_into_chunks(text: String, limit: int) -> Array:
  var chunks: Array = []
  var s: String = text
  var start: int = 0
  var n: int = s.length()
  if limit <= 0:
    chunks.append(s)
    return chunks
  while start < n:
    var end: int = int(min(start + limit, n))
    if end < n:
      var break_at: int = end - 1
      var found: bool = false
      # Search backwards for a space to break on
      while break_at > start:
        var c: String = s.substr(break_at, 1)
        if c == " ":
          found = true
          break
        break_at -= 1
      if found and break_at > start:
        end = break_at
    var part: String = s.substr(start, end - start).strip_edges()
    if part != "":
      chunks.append(part)
    # Skip the space at the split point if any
    start = end
    while start < n and s.substr(start, 1) == " ":
      start += 1
  return chunks

func _preprocess_obsidian_inline(s: String) -> String:
  var t = s
  # Remove image embeds entirely
  t = obs_image_re.sub(t, "", true)
  # Replace links with alias first, then simple links
  t = obs_link_with_alias_re.sub(t, "[b]$1[/b]", true)
  t = obs_link_simple_re.sub(t, "[b]$1[/b]", true)
  return t

func _create_text_items(title, extract):
  var items = []
  var lines = extract.split("\n")

  var current_title = title
  var current_subtitle = ""
  var current_text = ""
  var current_text_has_content = false
  var current_paras_count: int = 0

  for raw_line in lines:
    # Preprocess Obsidian inline syntax: remove image embeds; bold internal links
    var pre_line = _preprocess_obsidian_inline(raw_line)
    var line = pre_line.strip_edges()
    if line == "":
      continue

    # Markdown unordered list item ("- item" with optional leading whitespace)
    var list_match = md_list_re.search(pre_line)
    if list_match:
      var list_text = list_match.get_string(1).strip_edges()
      list_text = _apply_markdown_inline(list_text)
      if list_text != "":
        var bullet = "• " + list_text
        var list_para_full = p_fmt % bullet

        # If the single bullet paragraph itself is too large, split it into
        # smaller chunks to avoid creating an oversized first plaque.
        if len(list_para_full) > max_len_soft:
          var bullet_chunks = _split_into_chunks(bullet, max_len_soft - 100)
          for bc in bullet_chunks:
            var chunk_para = p_fmt % bc
            var would_exceed_chars = len(current_text) + len(chunk_para) > max_len_soft
            var would_exceed_paras = (current_paras_count + 1) > max_paras_per_plaque
            if (would_exceed_chars or would_exceed_paras) and current_text_has_content:
              _add_text_item(items, current_title, current_subtitle, current_text)
              # Preserve subtitle across overflow
              current_text = ""
              current_text_has_content = false
              current_paras_count = 0
            current_text_has_content = true
            current_text += chunk_para
            current_paras_count += 1
        else:
          # If adding this bullet would exceed soft limits, start a new plaque
          var would_exceed_chars2 = len(current_text) + len(list_para_full) > max_len_soft
          var would_exceed_paras2 = (current_paras_count + 1) > max_paras_per_plaque
          if (would_exceed_chars2 or would_exceed_paras2) and current_text_has_content:
            _add_text_item(items, current_title, current_subtitle, current_text)
            # Preserve subtitle across overflow
            current_text = ""
            current_text_has_content = false
            current_paras_count = 0

          current_text_has_content = true
          current_text += list_para_full
          current_paras_count += 1
      continue

    # Markdown-style headings: #, ##, ### ...
    if line.begins_with("#"):
      var level = 0
      while level < len(line) and line[level] == "#":
        level += 1
      var heading_text = _apply_markdown_inline(line.substr(level).strip_edges())
      if heading_text == "":
        continue

      if level == 1:
        # H1: treat as a new plaque title
        if current_text_has_content:
          _add_text_item(items, current_title, current_subtitle, current_text)
        current_title = heading_text
        current_subtitle = ""
        current_text = ""
        current_text_has_content = false
        current_paras_count = 0
      else:
        # H2+: start a new plaque under the same H1, using the heading as subtitle
        # This prevents long sections from being truncated at render time and
        # ensures short trailing sections are not "eaten" by a previous plaque.
        if current_text_has_content:
          _add_text_item(items, current_title, current_subtitle, current_text)
        current_subtitle = heading_text
        current_text = ""
        current_text_has_content = false
        current_paras_count = 0
      continue

    # Existing wikitext-style section heading support (== Heading ==)
    if s2_re.search(line):
      if current_text_has_content:
        _add_text_item(items, current_title, current_subtitle, current_text)
      current_title = _clean_section(line)
      current_subtitle = ""
      current_text = ""
      current_text_has_content = false
      current_paras_count = 0
      continue

    # Other =Heading= lines – start a new plaque with this as subtitle
    if line.begins_with("="):
      var heading2 = _clean_section(line)
      if current_text_has_content:
        _add_text_item(items, current_title, current_subtitle, current_text)
      current_subtitle = heading2
      current_text = ""
      current_text_has_content = false
      current_paras_count = 0
      continue

    # Regular paragraph line (Markdown or plain text)
    var formatted = _apply_markdown_inline(line)
    if len(formatted) == 0:
      continue

    var para_full = p_fmt % formatted

    # If the paragraph itself is very large, split into chunks to guarantee
    # we page correctly even when it's the first paragraph in a plaque.
    if len(para_full) > max_len_soft:
      var chunks = _split_into_chunks(formatted, max_len_soft - 100)
      for ch in chunks:
        var ch_para = p_fmt % ch
        var exceed_chars = len(current_text) + len(ch_para) > max_len_soft
        var exceed_paras = (current_paras_count + 1) > max_paras_per_plaque
        if (exceed_chars or exceed_paras) and current_text_has_content:
          _add_text_item(items, current_title, current_subtitle, current_text)
          # Preserve subtitle across overflow
          current_text = ""
          current_text_has_content = false
          current_paras_count = 0
        current_text_has_content = true
        current_text += ch_para
        current_paras_count += 1
    else:
      # If adding this paragraph would exceed soft limits, start a new plaque
      var would_exceed_chars3 = len(current_text) + len(para_full) > max_len_soft
      var would_exceed_paras3 = (current_paras_count + 1) > max_paras_per_plaque
      if (would_exceed_chars3 or would_exceed_paras3) and current_text_has_content:
        _add_text_item(items, current_title, current_subtitle, current_text)
        # Preserve subtitle across overflow
        current_text = ""
        current_text_has_content = false
        current_paras_count = 0

      current_text_has_content = true
      current_text += para_full
      current_paras_count += 1

  if current_text_has_content:
    _add_text_item(items, current_title, current_subtitle, current_text)

  return items

func _wikitext_to_extract(wikitext):
  wikitext = template_re.sub(wikitext, "", true)
  wikitext = links_re.sub(wikitext, "$2", true)
  wikitext = extlinks_re.sub(wikitext, "$1", true)
  wikitext = em_re.sub(wikitext, "", true)
  wikitext = tag_re.sub(wikitext, "", true)
  wikitext = whitespace_re.sub(wikitext, " ", true)
  wikitext = nl_re.sub(wikitext, "\n", true)
  return wikitext.strip_edges()

func _parse_wikitext(wikitext):
  var tokens = tokenizer.search_all(wikitext)
  var link = ""
  var links = []

  var depth_chars = {
    "<": ">",
    "[": "]",
    "{": "}",
  }

  var depth = []
  var dc
  var dl
  var in_link
  var t
  var in_tag
  var tag = ""
  var html_tag = null
  var html = []
  var template = []
  var in_template

  for match in tokens:
    t = match.get_string(0)
    dc = depth_chars.get(t)
    dl = len(depth)
    in_link = dl > 1 and depth[0] == "]" and depth[1] == "]"
    in_tag = dl > 0 and depth[dl - 1] == ">"
    in_template = dl > 1 and depth[0] == "}" and depth[1] == "}"

    if dc:
      depth.push_back(dc)
    elif dl == 0:
      if html_tag:
        html.append(t)
    elif t == depth[dl - 1]:
      depth.pop_back()
      # recalc whether we're in a link/tag/etc
      # not the nicest looking but it works
      dc = depth_chars.get(t)
      dl = len(depth)
      in_link = dl > 1 and depth[0] == "]" and depth[1] == "]"
      in_tag = dl > 0 and depth[dl - 1] == ">"
      in_template = dl > 1 and depth[0] == "}" and depth[1] == "}"
    elif in_tag:
      tag += t
    elif in_link:
      link += t
    elif in_template:
      template.append(t)

    if not in_link and len(link) > 0:
      links.append(["link", link])
      link = ""

    if not in_template and len(template) > 0:
      links.append(["template", "".join(template)])
      template.clear()

    if not in_tag and len(tag) > 0:
      # we don't handle nested tags for now
      if tag[0] == "!" or tag[len(tag) - 1] == "/":
        pass
      elif not tag[0] == "/":
        html_tag = tag
      else:
        if len(html) > 0 and html_tag.strip_edges().begins_with("gallery"):
          var html_str = "".join(html)
          var lines = html_str.split("\n")
          for line in lines:
            links.append(["link", line])
        html.clear()
        html_tag = null
      tag = ""

  return links

func commons_images_to_items(title, images, extra_text):
  var items = []
  var material = Util.gen_item_material(title)
  var plate = Util.gen_plate_style(title)

  # Deterministic ordering: keep images in given order and interleave
  # one extra_text plaque after each image if available.
  for image in images:
    if image and IMAGE_REGEX.search(image) and not exclude_image_re.search(image.to_lower()):
      items.append({
        "type": "image",
        "material": material,
        "plate": plate,
        "title": image,
        "text": _clean_filename(image),
      })
      if len(extra_text) > 0:
        items.append(extra_text.pop_front())

  return items

func create_items(title, result, prev_title=""):
  WorkQueue.add_item(PROCESSOR_QUEUE, [title, result, prev_title])

func _create_items(title, result, prev_title):
  var text_items = []
  var image_items = []
  var doors = []
  var doors_used = {}
  var material = Util.gen_item_material(title)
  var plate = Util.gen_plate_style(title)

  if result and result.has("wikitext") and result.has("extract"):
    var ordered_text = result.has("ordered_text") and result.ordered_text
    var wikitext = result.wikitext

    Util.t_start()
    var links = _parse_wikitext(wikitext)
    Util.t_end("_parse_wikitext")

    # we are using the extract returned from API or local markdown until parser works better
    text_items.append_array(_create_text_items(title, result.extract))

    for link_entry in links:
      var type = link_entry[0]
      var link = link_entry[1]

      var target = _to_link_case(image_name_re.sub(link.get_slice("|", 0), "File:"))
      var caption = alt_re.search(link)

      if target.begins_with("File:") and IMAGE_REGEX.search(target):
        image_items.append({
          "type": "image",
          "material": material,
          "plate": plate,
          "title": target,
          "text": caption.get_string(1) if caption else _clean_filename(target),
        })

      elif type == "template":
        var other_images = image_field_re.search_all(link)
        if len(other_images) > 0:
          for match in other_images:
            var image_title = image_name_re.sub(match.get_string(1), "File:")
            if image_title.find("\n") >= 0:
              print("newline in file name ", image_title)
            if not image_title or not IMAGE_REGEX.search(image_title):
              continue
            if not image_title.begins_with("File:"):
              image_title = "File:" + image_title
            image_items.append({
              "type": "image",
              "material": material,
              "plate": plate,
              "title": image_title,
              "text": caption.get_string(1) if caption else _clean_filename(image_title),
            })

      elif type == "link" and target and target.find(":") < 0:
        var door = _to_link_case(target.get_slice("#", 0))
        if not doors_used.has(door) and door != title and door != prev_title and len(door) > 0:
          doors.append(door)
          doors_used[door] = true

    # Local markdown exhibits may provide explicit links to other exhibits
    # via ExhibitFetcher (frontmatter "link"/"links" keys and Markdown
    # [label](Target) entries). These arrive as result.links containing
    # normalized exhibit titles. Treat them like Wikipedia article links
    # and turn them into doors, reusing the same filtering rules.
    if result.has("links") and typeof(result.links) == TYPE_ARRAY:
      for raw_link in result.links:
        var door_title := ""
        var door_label := ""
        if typeof(raw_link) == TYPE_DICTIONARY:
          if raw_link.has("title"):
            door_title = str(raw_link.title)
          if raw_link.has("label"):
            door_label = str(raw_link.label)
        else:
          door_title = str(raw_link)

        if door_title == "":
          continue

        var door2 = _to_link_case(door_title)
        if door2.find(":") >= 0:
          continue
        if not doors_used.has(door2) and door2 != title and door2 != prev_title and len(door2) > 0:
          if door_label != "":
            doors.append({"title": door2, "label": door_label})
          else:
            doors.append(door2)
          doors_used[door2] = true

  var items = []
  var extra_text = text_items

  # When ordered_text is true (used for local markdown exhibits), keep
  # text panels in order and ensure all content is displayed.
  if result and result.has("ordered_text") and result.ordered_text:
    extra_text = []
    var total_fragments = len(text_items)
    while len(text_items) > 0 or len(image_items) > 0:
      if len(text_items) == 0:
        items.append(image_items.pop_front())
      elif len(image_items) == 0:
        items.append(text_items.pop_front())
      else:
        var il = len(items)
        if il == 0 or items[il - 1].type != "text":
          items.append(text_items.pop_front())
        else:
          items.append(image_items.pop_front())

    # Annotate each rich_text plaque with its fragment index (i/n)
    # so the user can see progress through an ordered document.
    #
    # NOTE: RichTextItem may trim text from the *end* of the plaque content
    # when it doesn't fit vertically. To avoid losing the page marker on
    # long plaques, we insert the marker immediately after the main title
    # block (near the top) instead of appending it at the very end.
    if total_fragments > 0:
      var fragment_index = 1
      for i in range(len(items)):
        var item = items[i]
        if item and typeof(item) == TYPE_DICTIONARY and item.has("type") and item.type == "rich_text" and item.has("text"):
          var page_marker = "[p][font_size=24]%d/%d[/font_size][/p]\n" % [fragment_index, total_fragments]
          var text = item.text
          # text_item_fmt is "[color=black][b][font_size=48]%s[/font_size][/b]\n\n%s"
          # so we try to inject our page marker right after the first
          # double newline following the title, if present.
          var insert_pos = text.find("\n\n")
          if insert_pos >= 0:
            insert_pos += 2
            item.text = text.substr(0, insert_pos) + page_marker + text.substr(insert_pos)
          else:
            # Fallback: prepend the marker so it is still near the top.
            item.text = page_marker + text
          items[i] = item
          fragment_index += 1
  else:
    # Deterministic behaviour: preserve input order of text, doors, and images.
    # Start with the first text plaque (if present), then alternate text and
    # images as available without any randomness.
    if len(text_items) > 0:
      items.append(text_items.pop_front())

    # Explicitly type this boolean; Godot cannot infer the type from a complex expression.
    var last_was_text: bool = false
    if len(items) > 0:
      var _last = items[len(items) - 1]
      if typeof(_last) == TYPE_DICTIONARY and _last.has("type"):
        last_was_text = (_last.type == "rich_text")

    while len(text_items) > 0 or len(image_items) > 0:
      if last_was_text:
        if len(image_items) > 0:
          items.append(image_items.pop_front())
          last_was_text = false
        elif len(text_items) > 0:
          items.append(text_items.pop_front())
          last_was_text = true
        else:
          break
      else:
        if len(text_items) > 0:
          items.append(text_items.pop_front())
          last_was_text = true
        elif len(image_items) > 0:
          items.append(image_items.pop_front())
          last_was_text = false
        else:
          break

    # Any remaining text becomes extra_text to be queued after main items
    extra_text = text_items

  call_deferred("emit_signal", "items_complete", {
    "title": title,
    "doors": doors,
    "items": items,
    "extra_text": extra_text,
  })
