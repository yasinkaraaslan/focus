go_to_definition :: (editor: *Editor, buffer: *Buffer) {
    if buffer.lang != .Jai {
        add_user_warning("Go to definition is available for Jai files.", dismiss_in_seconds = 3);
        return;
    }
    if !workspace_scan_complete {
        add_user_warning("The workspace is still scanning. Try go to definition again shortly.", dismiss_in_seconds = 3);
        return;
    }

    position := get_main_cursor(editor).pos;
    span, qualified := jai_identifier_at(to_string(buffer.bytes), position,
                                        include_right_edge = !config.settings.vim_mode || editor.vim.mode == .Insert);
    if span.start == span.end {
        add_user_warning("Place the cursor on a Jai identifier.", dismiss_in_seconds = 3);
        return;
    }
    if qualified {
        add_user_warning("Go to definition for qualified Jai names is unavailable.", dismiss_in_seconds = 3);
        return;
    }

    name := get_range_as_string(buffer, span);
    candidates := find_jai_definitions(editor.buffer_id, name, span.start);
    if !candidates {
        add_user_warning("No definition found for '%'.", name, dismiss_in_seconds = 3);
        return;
    }

    if candidates.count == 1 {
        jump_to_jai_definition(candidates[0], .in_place);
    } else {
        array_reset_keeping_memory(*definition_dialog.candidates);
        array_add(*definition_dialog.candidates, ..candidates);
        show_dialog(*definition_dialog);
    }
}

Jai_Definition_Location :: struct {
    buffer_id: s64;
    offset: s32;
    revision: u64;
}

find_jai_definitions :: (origin_id: s64, name: string, position: s32) -> [] Jai_Definition_Location /* temp */ {
    candidates: [..] Jai_Definition_Location;
    candidates.allocator = temp;

    origin := *open_buffers[origin_id];
    refresh_jai_definition_index(origin);

    // The nearest visible lexical scope wins. Keep all declarations in that
    // scope so overloads can be chosen explicitly.
    nearest_depth: s32 = 0;
    for declaration : origin.jai_definitions.symbols {
        if !declaration.scope continue;
        scope := origin.jai_definitions.scopes[declaration.scope];
        if scope.depth < nearest_depth || position < scope.start || position > scope.end continue;
        if declaration.name.start > position continue;
        if !jai_names_equal(get_range_as_string(origin, declaration.name), name) continue;

        if scope.depth > nearest_depth {
            candidates.count = 0;
            nearest_depth = scope.depth;
        }
        array_add(*candidates, .{origin_id, declaration.name.start, origin.content_revision});
    }
    if candidates return candidates;

    add_jai_file_definitions(*candidates, origin_id, name, only_private = true);
    if candidates return candidates;

    add_jai_file_definitions(*candidates, origin_id, name);
    for * buffer, id : open_buffers {
        if id == origin_id || buffer.lang != .Jai || !buffer.has_file || buffer.internal || buffer.binary continue;
        if buffer.deleted && !buffer.modified continue;
        refresh_jai_definition_index(buffer);
        add_jai_file_definitions(*candidates, id, name);
    }
    filter_jai_workspace_definitions(*candidates, origin_id);
    return candidates;
}

Definition_Dialog :: struct {
    using #as generic_dialog: Generic_Choice_Dialog(Definition_Entry);
    generic_dialog.global_widget_id = .definition_dialog;
    generic_dialog.refresh_entries = refresh_definition_entries;
    generic_dialog.open_entry = open_selected_jai_definition;
    candidates: [..] Jai_Definition_Location;
}

Definition_Entry :: struct {
    name: string;
    location: Jai_Definition_Location;
}

definition_dialog: Definition_Dialog;

deinit_definition_dialog :: () {
    using definition_dialog;
    candidates.count = 0;
    reset(*memory_pool);
    array_reset(*filtered);
}


#scope_file

add_jai_file_definitions :: (candidates: *[..] Jai_Definition_Location, id: s64, name: string, only_private := false) {
    buffer := *open_buffers[id];

    for declaration : buffer.jai_definitions.symbols {
        if declaration.scope || declaration.file_private != only_private continue;
        if !jai_names_equal(get_range_as_string(buffer, declaration.name), name) continue;
        array_add(candidates, Jai_Definition_Location.{id, declaration.name.start, buffer.content_revision});
    }
}

definition_location_is_current :: (location: Jai_Definition_Location) -> bool {
    if location.buffer_id >= open_buffers.count return false;

    buffer := *open_buffers[location.buffer_id];
    return buffer.lang == .Jai && buffer.content_revision == location.revision &&
           (!buffer.deleted || buffer.modified);
}

refresh_definition_entries :: (filter: Fuzzy_Filter) {
    using definition_dialog;
    for location, i : candidates {
        if !definition_location_is_current(location) continue;

        buffer := *open_buffers[location.buffer_id];
        if buffer.dirty then rescan_for_lines(buffer);

        line := offset_to_real_line(buffer, location.offset);
        signature := trim(get_real_line_as_string(buffer, line));
        path := "Untitled";
        if buffer.has_file {
            _, _, _, basename := path_decomp(buffer.file.full_path);
            path = ifx buffer.file.path then tprint("%/%", buffer.file.path, basename) else basename;
        }
        name := tprint("%:%  •  %", path, line + 1, signature);

        score, highlights := fuzzy_match(name, filter);
        if score <= 0 && filter.full_string continue;

        entry := array_add(*filtered);
        entry.name = copy_string(name);
        entry.location = location;
        entry.highlights = highlights;
        entry.sort_key = cast(u64) (candidates.count - i);
    }
}

open_selected_jai_definition :: (placement: Editor_Placement) {
    using definition_dialog;
    if selected < 0 || selected >= filtered.count return;

    location := filtered[selected].location;
    hide_dialog(definition_dialog);
    jump_to_jai_definition(location, placement);
}

jump_to_jai_definition :: (location: Jai_Definition_Location, placement: Editor_Placement) {
    if !definition_location_is_current(location) {
        add_user_warning("The definition changed. Run go to definition again.", dismiss_in_seconds = 3);
        return;
    }

    origin_id := get_active_editor_id();
    if origin_id < 0 return;
    origin, origin_buffer := get_editor_and_buffer(origin_id);
    if origin_buffer.dirty then rescan_for_lines(origin_buffer);

    origin_cursor := get_main_cursor(origin);
    if placement == .in_place && location.buffer_id == origin.buffer_id && location.offset == origin_cursor.pos return;

    if config.settings.vim_mode && origin.vim.mode == .Insert then new_edit_group(origin_buffer, origin);

    if location.buffer_id != origin.buffer_id || placement != .in_place {
        editors_open_buffer(location.buffer_id, placement);
        target_id := get_active_editor_id();
        if target_id < 0 || open_editors[target_id].buffer_id != location.buffer_id return;
        if target_id == origin_id && placement != .in_place return;
    }

    history_record_jump(origin_id, origin_cursor);

    editor, buffer := get_active_editor_and_buffer();
    if buffer.dirty then rescan_for_lines(buffer);

    cursor := leave_only_main_cursor(editor);
    cursor.pos = location.offset;
    cursor.sel = location.offset;
    cursor.col_wanted = -1;

    if config.settings.vim_mode {
        vim_clear_command(editor);
        editor.vim.mode = .Normal;
        editor.vim.visual_line = false;
        editor.vim.insert_count = 0;
        editor.vim.repeat.recording = false;
        reset_keeping_memory(*editor.vim.visual_cursors);
    }

    history_reset_last_seen_cursor();
    editor.cursor_moved = true;
    editor.refresh_selection = true;
    editor.scroll_to_cursor = .yes;
    cursors_start_blinking();
    redraw_requested = true;
}
