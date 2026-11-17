// Optional, deliberately small Vim command layer. Edits go through the regular
// editor action path so readonly buffers, undo, rescanning and cursor updates agree.
Vim_State :: struct {
    mode: enum { Normal; Insert; Visual; };

    pending: u32; // d, c or y
    prefix: u32;  // A command waiting for one more key
    count: s32;   // Zero means no count was supplied
    operator_count: s32;

    visual_line: bool;
    visual_cursors: Array(Cursor);

    last_find_command: u32;
    last_find_char: u32;
    half_page: s32;

    insert_count: s32;
    insert_start: s64;
    insert_on_new_lines: bool;
    repeat: Vim_Repeat_State;
}

vim_action :: (editor: *Editor, buffer: *Buffer, action: Action_Editors, undo_cursors: [] Cursor = .[]) {
    event: Input.Event;
    event.type = .KEYBOARD;
    event.key_pressed = 1;

    editor.cursor_moved = false;
    if action == .undo then new_edit_group(buffer, editor);

    undo_count := buffer.undos.count;
    redo_count := buffer.redos.count;
    active_editor_handle_event(editor, buffer, event, action, undo_cursors);

    // Focus normally previews a moved undo cursor first; Vim's u/Ctrl-R apply immediately.
    if (action == .undo && undo_count > 0 && buffer.undos.count == undo_count) ||
       (action == .redo && redo_count > 0 && buffer.redos.count == redo_count) {
        active_editor_handle_event(editor, buffer, event, action);
    }
}

vim_enter_normal :: (editor: *Editor, buffer: *Buffer) {
    vim_repeat_record(editor, .{kind = .Escape});
    vim_visual_restore(editor);

    if editor.vim.mode == .Insert {
        vim_finish_counted_insert(editor, buffer);
        new_edit_group(buffer, editor);

        // Insert positions sit after the typed character.
        for * cursor : editor.cursors {
            start := get_real_line_start_offset(buffer, offset_to_real_line(buffer, cursor.pos));
            if cursor.pos > start then cursor.pos = prev_char_offset(buffer.bytes, cursor.pos);
        }
    }

    vim_clear_command(editor);
    editor.vim.mode = .Normal;
    editor.vim.visual_line = false;

    vim_action(editor, buffer, .escape);
    for * editor.cursors { it.sel = it.pos; }

    editor.cursor_moved = true;
    editor.refresh_selection = true;
    redraw_requested = true;
    vim_repeat_finish(editor, buffer);
}

vim_handle_char :: (editor: *Editor, buffer: *Buffer, char: u32) {
    using editor.vim;

    if !prefix && !pending && mode == .Normal && (char == #char "u" || char == #char ".") {
        repeat.recording = false;
        reset_keeping_memory(*repeat.draft);

        if char == #char "." {
            times := count;
            count = 0;
            vim_repeat_change(editor, buffer, times);
            return;
        }
    } else {
        vim_repeat_begin(editor, buffer);
        vim_repeat_record(editor, .{kind = .Command, char = char});
    }

    redraw_requested = true;

    // This may reallocate open_editors. Dispatch it before installing cursor cleanup.
    if prefix == #char "g" && char == #char "d" && !pending && mode == .Normal {
        vim_clear_command(editor);
        repeat.recording = false;
        vim_action(editor, buffer, .go_to_definition);
        return;
    }

    vim_visual_restore(editor);

    defer {
        vim_visual_refresh(editor, buffer);
        vim_repeat_finish(editor, buffer);

        if mode == .Normal && !pending && !prefix && !editor.search_bar.active {
            for * cursor : editor.cursors {
                cursor.pos = vim_normal_pos(buffer, cursor.pos);
                cursor.sel = cursor.pos;
            }

            editor.refresh_selection = true;
        }
    }

    if !prefix && char >= #char "0" && char <= #char "9" && (char != #char "0" || count > 0) {
        count = min(cast(s32) 1000, count * 10 + cast(s32)(char - #char "0"));
        return;
    }

    explicit_count := count > 0 || operator_count > 0;
    times := min(cast(s32) 1000, max(cast(s32) 1, count) * max(cast(s32) 1, operator_count));
    op := pending;
    command := prefix;
    vim_clear_command(editor);

    g := command == #char "g";
    if vim_is_find(command) {
        last_find_command = command;
        last_find_char = char;
        vim_find(editor, buffer, command, char, times, op);
        return;
    }

    if command == #char "i" || command == #char "a" {
        vim_select_object(editor, buffer, char, command == #char "a", times, op);
        return;
    }

    if command && !g {
        vim_mark(editor, buffer, command, char, op);
        return;
    }

    if !command {
        object := (op != 0 || mode == .Visual) && (char == #char "i" || char == #char "a");
        if object || vim_is_find(char) || char == #char "g" || char == #char "m" || char == #char "'" || char == #char "`" {
            prefix = char;
            pending = op;
            if explicit_count then count = times;
            return;
        }
    }

    if !g && (char == #char "/" || char == #char "?") {
        vim_search_open(editor, char == #char "?", times, op);
        return;
    }

    if char == #char "*" || char == #char "#" {
        vim_search_word(editor, buffer, char == #char "#", !g, times, op);
        return;
    }

    if !g && (char == #char "n" || char == #char "N") {
        vim_search_repeat(editor, buffer, char == #char "N", times, op);
        return;
    }

    if vim_motion(editor, buffer, char, times, explicit_count, op, g) return;
    if g return;

    if char == #char ";" || char == #char "," {
        if !last_find_command return;

        command := last_find_command;
        if char == #char "," {
            if command == {
                case #char "f"; command = #char "F";
                case #char "F"; command = #char "f";
                case #char "t"; command = #char "T";
                case #char "T"; command = #char "t";
            }
        }
        vim_find(editor, buffer, command, last_find_char, times, op, repeating = true);
        return;
    }

    if op && char == op {
        vim_line_operator(editor, buffer, op, times);
        return;
    }

    if op return;

    if char == {
        case #char "d"; #through;
        case #char "c"; #through;
        case #char "y";
            if mode == .Visual {
                before := vim_copy_cursors(editor);
                for * cursor: editor.cursors { vim_visual_range(cursor, buffer, visual_line, char); }

                visual_line = false;
                mode = .Normal;
                vim_apply_operator(editor, buffer, char, before);
            } else {
                pending = char;
                if explicit_count then operator_count = times;
            }

        case #char "V"; #through;
        case #char "v";
            linewise := char == #char "V";
            if mode == .Visual && visual_line == linewise {
                vim_enter_normal(editor, buffer);
            } else {
                if mode != .Visual then for * editor.cursors { it.sel = it.pos; }

                mode = .Visual;
                visual_line = linewise;
            }

        case #char "i";
            vim_prepare_insert(editor, buffer, .At_Cursor, times);

        case #char "a";
            vim_prepare_insert(editor, buffer, .Append, times);

        case #char "I";
            vim_prepare_insert(editor, buffer, .First_Nonblank, times);

        case #char "A";
            vim_prepare_insert(editor, buffer, .Line_End, times);

        case #char "J";
            new_edit_group(buffer, editor);
            before := vim_copy_cursors(editor);

            if mode != .Visual {
                for * cursor: editor.cursors {
                    line := offset_to_real_line(buffer, cursor.pos);
                    last := min(line + max(cast(s32) 2, times) - 1, cast(s32) buffer.line_starts.count - 1);
                    cursor.sel = get_real_line_start_offset(buffer, line);
                    cursor.pos = get_real_line_end_offset(buffer, last);
                }
            }

            revision := buffer.content_revision;
            vim_action(editor, buffer, .join_lines, undo_cursors = before);

            if buffer.content_revision == revision && editor.cursors.count == before.count {
                for * cursor, i: editor.cursors { cursor.* = before[i]; }
            }

            if mode == .Visual {
                mode = .Normal;
                visual_line = false;
            }

        case #char "o"; #through;
        case #char "O";
            if mode == .Visual {
                for * cursor : editor.cursors {
                    swap(*cursor.pos, *cursor.sel);
                    cursor.col_wanted = -1;
                }

                editor.cursor_moved = true;
                editor.refresh_selection = true;
                return;
            }

            new_edit_group(buffer, editor);
            action: Action_Editors = .new_line_below_without_breaking;
            if char == #char "O" then action = .new_line_above_without_breaking;
            vim_action(editor, buffer, action);
            vim_prepare_insert(editor, buffer, .At_Cursor, times, open_line = true);

        case #char "C"; #through;
        case #char "D";
            op := ifx char == #char "C" then cast(u32) #char "c" else cast(u32) #char "d";
            if mode == .Visual {
                before := vim_copy_cursors(editor);
                for * cursor: editor.cursors { vim_line_range(cursor, buffer, op); }

                mode = .Normal;
                visual_line = false;
                vim_apply_operator(editor, buffer, op, before);
            } else {
                vim_motion(editor, buffer, #char "$", times, explicit_count, op);
            }

        case #char "x"; #through;
        case #char "p"; #through;
        case #char "u";
            if char == #char "x" && buffer.readonly return;

            if mode == .Visual && char != #char "u" {
                op := ifx char == #char "x" then cast(u32) #char "d" else cast(u32) #char "y";
                for * cursor: editor.cursors { vim_visual_range(cursor, buffer, visual_line, op); }
                if char == #char "x" then times = 1;
            }

            action: Action_Editors = .delete_right_char;
            if char == #char "p" then action = .paste;
            if char == #char "u" then action = .undo;
            new_edit_group(buffer, editor);

            if char == #char "x" && mode != .Visual {
                before := vim_copy_cursors(editor);
                any_selection := false;

                for * cursor : editor.cursors {
                    end := get_real_line_end_offset(buffer, offset_to_real_line(buffer, cursor.pos));
                    cursor.sel = cursor.pos;

                    for 1..times {
                        if cursor.pos < end then cursor.pos = next_char_offset(buffer.bytes, cursor.pos);
                    }

                    if has_selection(cursor) then any_selection = true;
                }

                if any_selection then vim_action(editor, buffer, action, undo_cursors = before);
            } else {
                for 1..times { vim_action(editor, buffer, action); }
            }

            new_edit_group(buffer, editor);
            if mode == .Visual {
                mode = .Normal;
                visual_line = false;
            }
    }
}

vim_search_open :: (editor: *Editor, backward: bool, times: s32, op: u32 = 0) {
    using bar := *editor.search_bar;
    free(vim_history.draft);
    vim_history = .{};

    reset(*vim_original_cursors);
    for editor.cursors { add(*vim_original_cursors, it); }
    vim_original_main_cursor = editor.main_cursor;
    vim_original_cursor = editor.original_cursor;
    original_cursor_position = editor.cursors[editor.main_cursor];

    vim_operator = op;
    vim_prompt_backward = backward;
    vim_count = times;

    mode = .vim;
    active = true;
    jumped = false;
    regex_search = true;
    whole_word = false;
    case_sensitive_toggled_manually = false;

    text_input_fully_clear(*input);
    reset_search_results(bar);
    redraw_requested = true;
}

vim_search_position :: (editor: *Editor, buffer: Buffer, offset: s32) -> s32 {
    if editor.vim.mode == .Normal then return vim_normal_pos(buffer, offset);
    return offset;
}

// Compare the positions Normal mode can actually display. A zero-width match
// at a line end sits on the preceding character, so n must advance past it.
vim_search_index :: (editor: *Editor, buffer: Buffer, origin: s32, backward: bool, times: s32) -> s32 {
    bar := *editor.search_bar;
    if !bar.results return -1;

    index: s64 = 0;
    if backward {
        index = bar.results.count - 1;
        for bar.results {
            if vim_search_position(editor, buffer, it.offset) >= origin break;
            index = it_index;
        }

        index = (index - (times - 1) % bar.results.count + bar.results.count) % bar.results.count;
    } else {
        for bar.results {
            if vim_search_position(editor, buffer, it.offset) > origin { index = it_index; break; }
        }

        index = (index + times - 1) % bar.results.count;
    }

    return xx index;
}

vim_search_move :: (editor: *Editor, buffer: Buffer, index: s32) {
    if index < 0 return;

    using bar := *editor.search_bar;
    vim_visual_restore(editor);
    selected_result = index;
    cursor := leave_only_main_cursor(editor);
    cursor.pos = vim_search_position(editor, buffer, results[index].offset);
    if editor.vim.mode != .Visual && !vim_operator then cursor.sel = cursor.pos;
    cursor.col_wanted = -1;
    vim_visual_refresh(editor, buffer);

    editor.cursor_moved = true;
    editor.refresh_selection = true;
    editor.scroll_to_cursor = .yes;
    jumped = true;
    cursors_start_blinking();
    redraw_requested = true;
}

vim_search_restore_cursors :: (editor: *Editor) {
    using bar := *editor.search_bar;
    reset_keeping_memory(*editor.vim.visual_cursors);

    resize(*editor.cursors, vim_original_cursors.count);
    for vim_original_cursors { editor.cursors[it_index] = it; }

    editor.main_cursor = vim_original_main_cursor;
    editor.original_cursor = vim_original_cursor;
    editor.refresh_selection = true;
    editor.scroll_to_cursor = .yes;
    redraw_requested = true;
}

vim_search_preview :: (editor: *Editor, buffer: Buffer) {
    using bar := *editor.search_bar;

    // Every edit previews from the original position, including failed/empty queries.
    vim_search_restore_cursors(editor);
    index := vim_search_index(editor, buffer, original_cursor_position.pos, vim_prompt_backward, vim_count);
    if index < 0 then vim_visual_refresh(editor, buffer);
    else vim_search_move(editor, buffer, index);
}

vim_search_finish :: (editor: *Editor, buffer: *Buffer, accept: bool) {
    using bar := *editor.search_bar;

    if accept {
        reuse_pattern := !input.text;
        if reuse_pattern {
            regex_search = vim_pattern_regex;
            whole_word = vim_pattern_whole_word;
            replace_text(*input, to_string(vim_pattern));
            search_and_update_results(editor, buffer, jump = true);
        }

        if !is_empty(input.text) {
            reset(*vim_pattern);
            for to_string(input.text) { add(*vim_pattern, it); }
            vim_backward = vim_prompt_backward;
            vim_pattern_regex = regex_search;
            vim_pattern_whole_word = whole_word;
        }
    }

    vim_visual_restore(editor);
    op := vim_operator;
    vim_operator = 0;
    target := editor.cursors[editor.main_cursor].pos;
    valid := accept && (!regex_search || regex_is_valid) && results.count > 0;
    origin := original_cursor_position;

    if valid && op then vim_search_restore_cursors(editor);
    close_search_bar(editor, jump_to_original_cursor = !accept, keep_results = accept);
    if !accept then reset_search_results(bar);

    if valid && op {
        // The prompt previews the main cursor; apply that search independently
        // from each original cursor, keeping failed searches non-destructive.
        vim_search_repeat(editor, buffer, false, vim_count, op, main_target = target);
    } else if valid && origin.pos != target {
        vim_record_jump(editor, origin);
    }

    vim_visual_refresh(editor, buffer);
    editor.refresh_selection = true;
    redraw_requested = true;
}

vim_search_repeat :: (editor: *Editor, buffer: *Buffer, opposite: bool, times: s32, op: u32 = 0, main_target: s32 = -1, main_origin: s32 = -1) {
    using bar := *editor.search_bar;
    if !vim_pattern return;

    replace_text(*input, to_string(vim_pattern));
    mode = .vim;
    regex_search = vim_pattern_regex;
    whole_word = vim_pattern_whole_word;
    case_sensitive_toggled_manually = false;
    search_and_update_results(editor, buffer);
    if !results || (regex_search && !regex_is_valid) return;

    before := vim_copy_cursors(editor);
    has_range := false;

    for * cursor, i: editor.cursors {
        origin := ifx i == editor.main_cursor && main_origin >= 0 then main_origin else cursor.pos;
        index := vim_search_index(editor, buffer, origin, vim_backward != opposite, times);
        if index < 0 continue;

        target := vim_search_position(editor, buffer, results[index].offset);
        if i == editor.main_cursor && main_target >= 0 then target = main_target;

        if op {
            vim_motion_range(cursor, buffer, .{pos = target}, op);
            if has_selection(cursor) then has_range = true;
        } else {
            cursor.pos = target;
            if editor.vim.mode != .Visual then cursor.sel = target;
        }

        cursor.col_wanted = -1;
        if i == editor.main_cursor then selected_result = index;
    }

    if op {
        if has_range then vim_apply_operator(editor, buffer, op, before);
    } else if before[editor.main_cursor].pos != editor.cursors[editor.main_cursor].pos {
        vim_record_jump(editor, before[editor.main_cursor]);
    }

    editor.cursor_moved = true;
    editor.refresh_selection = true;
    editor.scroll_to_cursor = .yes;
    redraw_requested = true;
}

vim_search_word :: (editor: *Editor, buffer: *Buffer, backward: bool, whole: bool, times: s32, op: u32) {
    cursor := editor.cursors[editor.main_cursor];
    pos := cursor.pos;
    end := get_real_line_end_offset(buffer, offset_to_real_line(buffer, pos));

    // Prefer a keyword at/after the cursor, then a punctuation word.
    while pos < end && vim_word_class(buffer.bytes[pos]) != 1 { pos = next_char_offset(buffer.bytes, pos); }
    if pos == end {
        pos = cursor.pos;
        while pos < end && vim_word_class(buffer.bytes[pos]) == 0 { pos = next_char_offset(buffer.bytes, pos); }
    }
    if pos >= end return;

    start, finish, found := vim_object_range(buffer, pos, #char "w", false, 1);
    if !found return;

    bar := *editor.search_bar;
    reset_keeping_memory(*bar.vim_pattern);
    for i: start..finish-1 { add(*bar.vim_pattern, buffer.bytes[i]); }
    bar.vim_backward = backward;
    bar.vim_pattern_regex = false;
    bar.vim_pattern_whole_word = whole && vim_word_class(buffer.bytes[pos]) == 1;

    // Searching a word while inside it starts from its beginning, including #.
    vim_search_repeat(editor, buffer, false, times, op, main_origin = start);
}

vim_search_handle_event :: (editor: *Editor, buffer: *Buffer, event: Input.Event) -> bool {
    vim_repeat_record(editor, .{kind = .Search_Key, event = event});
    defer vim_repeat_finish(editor, buffer);

    using bar := *editor.search_bar;
    mods := event.modifier_flags;
    key := event.key_code;
    ctrl := mods.packed == Mods.{ctrl_pressed = true}.packed;

    if key == .ESCAPE || (ctrl && (key == #char "[" || key == #char "C")) {
        vim_search_finish(editor, buffer, false);
        return true;
    }

    if key == .ENTER || key == .NUMPAD_ENTER || (ctrl && (key == #char "M" || key == #char "J")) {
        vim_search_finish(editor, buffer, true);
        return true;
    }

    if (key == .BACKSPACE || (ctrl && key == #char "H")) && !input.text {
        vim_search_finish(editor, buffer, false);
        return true;
    }

    if ctrl && (key == #char "G" || key == #char "T") {
        if !is_empty(results) {
            delta := ifx vim_prompt_backward then -1 else 1;
            if key == #char "T" then delta = -delta;
            index := (selected_result + delta + results.count) % results.count;
            vim_search_move(editor, buffer, xx index);
        }
        return true;
    }

    old_search_str := copy_temporary_string(to_string(input.text));
    if key == .ARROW_UP || (ctrl && key == #char "P") {
        if !vim_pattern || vim_history.recalled return true;
        vim_history.draft = copy_string(to_string(input.text));
        vim_history.cursor = input.cursor;
        vim_history.recalled = true;
        replace_text(*input, to_string(vim_pattern));
        input.cursor.pos = xx input.text.count;
        input.cursor.sel = input.cursor.pos;
    } else if key == .ARROW_DOWN || (ctrl && key == #char "N") {
        if !vim_history.recalled return true;
        replace_text(*input, vim_history.draft);
        input.cursor = vim_history.cursor;
        free(vim_history.draft);
        vim_history = .{};
    } else if ctrl && key == #char "U" {
        text_input_fully_clear(*input);
    } else if ctrl && key == #char "W" {
        text_input_handle_action(*input, .delete_left_through_word);
    } else if ctrl && key == #char "H" {
        text_input_handle_action(*input, .delete_left_char);
    } else if ctrl && key == #char "B" {
        text_input_handle_action(*input, .jump_to_line_start);
    } else if ctrl && key == #char "E" {
        text_input_handle_action(*input, .jump_to_line_end);
    } else {
        // Leave printable key events unhandled so their layout-aware TEXT_INPUT
        // events reach the prompt (the main event loop suppresses handled text).
        if !text_input_handle_event(*input, event) return false;
    }

    if old_search_str != to_string(input.text) then search_and_update_results(editor, buffer, jump = true);

    return true;
}

// Whitespace, keyword characters and punctuation form separate Vim word groups.
vim_word_class :: (byte: u8, big := false) -> int {
    if ascii_is_space(byte) return 0;
    if big || ascii_is_alnum(byte) || byte == #char "_" || byte >= 128 return 1;
    return 2;
}

vim_word_forward :: (buffer: Buffer, pos: s32, big := false, stop_at_eol := false) -> s32 {
    if pos >= buffer.bytes.count return pos;

    kind := vim_word_class(buffer.bytes[pos], big);
    start := pos;
    while pos < buffer.bytes.count {
        if buffer.bytes[pos] == #char "\n" {
            if stop_at_eol && pos > start then return pos;
            if pos > start && vim_empty_line_at(buffer, pos) then return pos;
        }
        next_kind := vim_word_class(buffer.bytes[pos], big);
        if next_kind != kind && next_kind != 0 break;
        kind = next_kind;
        pos = next_char_offset(buffer.bytes, pos);
    }
    return pos;
}

vim_word_backward :: (buffer: Buffer, pos: s32, big := false) -> s32 {
    if pos == 0 return pos;

    pos = prev_char_offset(buffer.bytes, pos);
    while pos > 0 && vim_word_class(buffer.bytes[pos]) == 0 {
        if vim_empty_line_at(buffer, pos) then return pos;
        pos = prev_char_offset(buffer.bytes, pos);
    }
    if vim_word_class(buffer.bytes[pos], big) == 0 return pos;

    kind := vim_word_class(buffer.bytes[pos], big);
    while pos > 0 {
        previous := prev_char_offset(buffer.bytes, pos);
        if vim_word_class(buffer.bytes[previous], big) != kind break;
        pos = previous;
    }

    return pos;
}

vim_word_end :: (buffer: Buffer, pos: s32, big := false, include_current := false) -> s32 {
    if pos >= buffer.bytes.count return pos;

    // Ordinary e advances from a word's last character; cw must still change it.
    if !include_current then pos = next_char_offset(buffer.bytes, pos);
    while pos < buffer.bytes.count && ascii_is_space(buffer.bytes[pos]) {
        pos = next_char_offset(buffer.bytes, pos);
    }
    if pos >= buffer.bytes.count return xx buffer.bytes.count;

    kind := vim_word_class(buffer.bytes[pos], big);
    while true {
        next := next_char_offset(buffer.bytes, pos);
        if next >= buffer.bytes.count || vim_word_class(buffer.bytes[next], big) != kind return pos;
        pos = next;
    }
    return pos;
}

// Character ranges use the editor's half-open selection convention.
vim_object_range :: (buffer: Buffer, origin: s32, object: u32, around: bool, times: s32) -> range_start: s32, range_end: s32, found: bool {
    if origin >= buffer.bytes.count return origin, origin, false;

    if object == #char "p" {
        start, end, found := vim_paragraph_object(buffer, origin, around, times);
        return start, end, found;
    }

    if object == #char "w" || object == #char "W" {
        big := object == #char "W";
        kind := vim_word_class(buffer.bytes[origin], big);
        on_space := kind == 0;

        start := origin;
        while start > 0 {
            previous := prev_char_offset(buffer.bytes, start);
            if vim_word_class(buffer.bytes[previous], big) != kind break;
            start = previous;
        }

        end := origin;
        for step: 1..times {
            // iw counts whitespace runs; aw counts only words.
            if around {
                while end < buffer.bytes.count && ascii_is_space(buffer.bytes[end]) {
                    end = next_char_offset(buffer.bytes, end);
                }
                if end >= buffer.bytes.count break;
            }
            kind = vim_word_class(buffer.bytes[end], big);
            while end < buffer.bytes.count && vim_word_class(buffer.bytes[end], big) == kind {
                end = next_char_offset(buffer.bytes, end);
            }
            if end >= buffer.bytes.count break;
        }

        if around && !on_space {
            // Prefer trailing horizontal space; at EOL use preceding space.
            after := end;
            while after < buffer.bytes.count && (buffer.bytes[after] == #char " " || buffer.bytes[after] == #char "\t") {
                after += 1;
            }
            if after > end {
                end = after;
            } else {
                while start > 0 && (buffer.bytes[start - 1] == #char " " || buffer.bytes[start - 1] == #char "\t") {
                    start -= 1;
                }
            }
        }

        return start, end, true;
    }

    if object == #char "\"" || object == #char "'" || object == #char "`" {
        if times != 1 return origin, origin, false;

        line := offset_to_real_line(buffer, origin);
        left: s32 = -1;
        line_start := get_real_line_start_offset(buffer, line);
        line_end := get_real_line_end_offset(buffer, line);

        for i: line_start .. line_end - 1 {
            if buffer.bytes[i] != object continue;

            // An odd number of backslashes escapes a quote.
            slashes := 0;
            preceding := i;
            while preceding > line_start && buffer.bytes[preceding - 1] == #char "\\" {
                slashes += 1;
                preceding -= 1;
            }
            if slashes % 2 != 0 continue;

            if left < 0 {
                left = i;
            } else {
                if i >= origin {
                    return cast(s32) (left + (ifx around then 0 else 1)), cast(s32) (i + (ifx around then 1 else 0)), true;
                }
                left = -1;
            }
        }

        return origin, origin, false;
    }

    open: u8;
    close: u8;
    if object == {
        case #char "("; #through;
        case #char ")"; #through;
        case #char "b"; open = #char "("; close = #char ")";
        case #char "["; #through;
        case #char "]"; open = #char "["; close = #char "]";
        case #char "{"; #through;
        case #char "}"; #through;
        case #char "B"; open = #char "{"; close = #char "}";
        case; return origin, origin, false;
    }

    // Closing pairs are encountered from innermost to outermost around origin.
    stack: [..] s32;
    stack.allocator = temp;
    remaining := times;
    line_end := get_real_line_end_offset(buffer, offset_to_real_line(buffer, origin));
    next_open: s32 = -1;
    next_close: s32 = -1;
    for byte, i: buffer.bytes {
        if !vim_pair_delimiter(buffer, cast(s32) i) continue;
        if byte == open {
            array_add(*stack, cast(s32) i);
            if next_open < 0 && i > origin && i < line_end then next_open = xx i;
        }
        if byte != close || !stack continue;
        left := stack[stack.count - 1];
        stack.count -= 1;
        if left == next_open then next_close = xx i;
        if left > origin || i < origin continue;
        remaining -= 1;
        if remaining == 0 return cast(s32) (left + (ifx around then 0 else 1)), cast(s32) (i + (ifx around then 1 else 0)), true;
    }

    // With no enclosing pair, use the next opening delimiter on this line.
    if times == 1 && next_close >= 0 {
        if around return next_open, next_close + 1, true;
        return next_open + 1, next_close, true;
    }

    return origin, origin, false;
}

vim_select_object :: (editor: *Editor, buffer: *Buffer, object: u32, around: bool, times: s32, op: u32) {
    if object != #char "p" && object != #char "w" && object != #char "W" &&
       object != #char "\"" && object != #char "'" && object != #char "`" {
        vim_prepare_pair_tokens(buffer);
    }

    before := vim_copy_cursors(editor);
    any_match := false;

    for * cursor: editor.cursors {
        start, end, found := vim_object_range(buffer, cursor.pos, object, around, times);
        if !found || (!op && object != #char "p" && start == end) {
            if op then cursor.sel = cursor.pos;
            continue;
        }

        any_match = true;
        cursor.sel = start;
        cursor.pos = end;

        if object == #char "p" {
            if end > start then cursor.pos = prev_char_offset(buffer.bytes, end);
            if op then vim_line_range(cursor, buffer, op);
            else editor.vim.visual_line = true;
        } else if !op {
            cursor.pos = prev_char_offset(buffer.bytes, end);
            editor.vim.visual_line = false;
        }
        cursor.col_wanted = -1;
    }

    if !any_match return;

    editor.cursor_moved = true;
    editor.refresh_selection = true;
    cursors_start_blinking();
    if !op return;

    vim_apply_operator(editor, buffer, op, before);
}

vim_prepare_pair_tokens :: (buffer: *Buffer) {
    if buffer.was_dirty_during_frame || buffer_needs_tokenizing(buffer.*) then retokenize(buffer);
}

// Use language tokens when available so delimiters in strings and comments
// cannot close a surrounding code block. Plain text still supports raw pairs.
vim_pair_delimiter :: (buffer: Buffer, pos: s32) -> bool {
    if buffer.tokens.count != buffer.bytes.count return true;

    if buffer.tokens[pos] == {
        case .string_literal; #through;
        case .multiline_string; #through;
        case .raw_string; #through;
        case .char_literal; #through;
        case .comment; #through;
        case .multiline_comment; #through;
        case .comment_highlight1; #through;
        case .comment_highlight2; #through;
        case .comment_highlight3; #through;
        case .comment_highlight4; return false;
    }

    return true;
}

vim_matching_pair :: (buffer: Buffer, origin: s32) -> target: s32, found: bool {
    line_end := get_real_line_end_offset(buffer, offset_to_real_line(buffer, origin));
    for i: origin .. line_end - 1 {
        if !vim_pair_delimiter(buffer, i) continue;
        byte := buffer.bytes[i];
        open_index := find_index_from_left("([{", byte);
        close_index := find_index_from_left(")]}", byte);
        if open_index < 0 && close_index < 0 continue;

        forward := open_index >= 0;
        pair_index := ifx forward then open_index else close_index;
        counterpart := (ifx forward then ")]}" else "([{")[pair_index];
        balance := 1;
        pos := i;

        while true {
            if forward {
                pos += 1;
                if pos >= buffer.bytes.count break;
            } else {
                if pos == 0 break;
                pos -= 1;
            }

            if !vim_pair_delimiter(buffer, pos) continue;
            if buffer.bytes[pos] == byte then balance += 1;
            if buffer.bytes[pos] == counterpart then balance -= 1;
            if balance == 0 return pos, true;
        }
        return origin, false;
    }
    return origin, false;
}

// Find only within the current real line and step over whole UTF-8 characters.
// Resolve the entire count before moving, so a failed 3fx leaves the cursor alone.
vim_find_target :: (buffer: Buffer, origin: s32, command: u32, char: u32, times: s32, repeating: bool) -> target: s32, found: bool {
    forward := command == #char "f" || command == #char "t";
    till := command == #char "t" || command == #char "T";
    line := offset_to_real_line(buffer, origin);
    start := get_real_line_start_offset(buffer, line);
    end := get_real_line_end_offset(buffer, line);

    utf8 := convert_utf32_to_utf8(char);
    needle := to_string(*utf8);
    pos := origin;
    remaining := times;
    first := true;

    while remaining > 0 {
        if forward {
            if pos >= end return origin, false;
            pos = next_char_offset(buffer.bytes, pos);
            if pos >= end return origin, false;
        } else {
            if pos <= start return origin, false;
            pos = prev_char_offset(buffer.bytes, pos);
        }

        matches := pos + needle.count <= end && cast(string) to_view(buffer.bytes, pos, needle.count) == needle;
        if matches && !(repeating && till && times == 1 && first) then remaining -= 1;
        first = false;
    }
    if command == #char "t" then pos = prev_char_offset(buffer.bytes, pos);
    if command == #char "T" then pos = next_char_offset(buffer.bytes, pos);
    return pos, true;
}

vim_find :: (editor: *Editor, buffer: *Buffer, command: u32, char: u32, times: s32, op: u32, repeating := false) {
    before := vim_copy_cursors(editor);
    any_selection := false;
    any_match := false;

    for * cursor : editor.cursors {
        target, found := vim_find_target(buffer, cursor.pos, command, char, times, repeating);
        if !found {
            if op then cursor.sel = cursor.pos;
            continue;
        }

        any_match = true;
        if op {
            cursor.sel = cursor.pos;
            // Forward f/t motions include their destination character in an operator.
            if command == #char "f" || command == #char "t" then target = next_char_offset(buffer.bytes, target);
        }

        cursor.pos = target;
        cursor.col_wanted = -1;
        if !op && editor.vim.mode != .Visual then cursor.sel = cursor.pos;
        if has_selection(cursor) then any_selection = true;
    }

    if !any_match return;

    editor.cursor_moved = true;
    editor.refresh_selection = true;
    cursors_start_blinking();
    if !op || !any_selection return;

    vim_apply_operator(editor, buffer, op, before);
}

// All insertion commands share blank-line indentation. Nonblank lines retain
// each command's usual insertion position; I always uses the first nonblank.
Vim_Insert_Position :: enum { At_Cursor; Append; First_Nonblank; Line_End; }

vim_prepare_insert :: (editor: *Editor, buffer: *Buffer, where: Vim_Insert_Position, times: s32, open_line := false) {
    if !open_line then new_edit_group(buffer, editor);

    organise_cursors(editor);
    context.current_editor_id = get_active_editor_id();
    defer context.current_editor_id = -1;

    Insert_Position :: struct { line: s32; pos: s32; indent: string; }
    positions := NewArray(editor.cursors.count, Insert_Position,, allocator = temp);
    for cursor, i : editor.cursors {
        line := offset_to_real_line(buffer, cursor.pos);
        indent := get_real_line_indentation(buffer, line);
        end := get_real_line_end_offset(buffer, line);
        positions[i].line = line;
        positions[i].pos = cursor.pos;

        if indent.end == end {
            positions[i].pos = end;
            if indent.start == end && !buffer.readonly {
                positions[i].indent = copy_temporary_string(get_previous_line_indentation(buffer, line));
            }
        } else if where == .First_Nonblank {
            positions[i].pos = indent.end;
        } else if where == .Line_End {
            positions[i].pos = end;
        } else if where == .Append && cursor.pos < end {
            positions[i].pos = next_char_offset(buffer.bytes, cursor.pos);
        }
    }

    // Capture undo positions before adding indentation. All offsets above refer
    // to the original buffer so several cursors can insert in the same event.
    if !buffer.edits {
        resize(*buffer.cursors, editor.cursors.count);
        for cursor, i : editor.cursors { buffer.cursors[i] = cursor; }
    }

    delta: s32;
    for * cursor, i : editor.cursors {
        position := positions[i];
        if i > 0 && position.line == positions[i-1].line && position.pos == positions[i-1].pos {
            cursor.pos = editor.cursors[i-1].pos;
        } else {
            cursor.pos = position.pos + delta;
            if position.indent {
                insert_string_at_offset(buffer, cursor.pos, position.indent);
                delta += xx position.indent.count;
                cursor.pos += xx position.indent.count;
            }
        }

        cursor.sel = cursor.pos;
        cursor.col_wanted = -1;
    }

    if buffer.dirty {
        rescan_for_lines(buffer);
        if line_wrap_is_active(editor) then rescan_for_wrapped_lines(editor, buffer);
        if !is_empty(editor.search_bar.results) then search_and_update_results(editor, buffer, jump = false);
        maybe_make_temporary_editor_permanent();
        buffer.last_edit_time = frame_time64;
    }

    organise_cursors(editor);

    editor.vim.mode = .Insert;
    editor.vim.insert_count = times;
    editor.vim.insert_on_new_lines = open_line;
    repeat := *editor.vim.repeat;
    editor.vim.insert_start = ifx repeat.replaying then repeat.replay_index + 1 else repeat.draft.count;
    editor.cursor_moved = true;
    editor.refresh_selection = true;
    cursors_start_blinking();
}

// Shift affects command case/symbols, independently of layout and Caps Lock.
vim_command_char :: (key: Input.Key_Code, shift: bool) -> u32 {
    char := cast(u32) key;
    // Input names the physical equals/plus key Plus for existing keymaps.
    if char == #char "+" char = #char "=";
    if char >= #char "A" && char <= #char "Z" {
        return ifx shift then char else char + 32;
    }

    if char < 32 || char >= 127 return 0;
    if shift {
        plain   := "`1234567890-=[]\\;',./";
        shifted := "~!@#$%^&*()_+{}|:\"<>?";
        for plain if char == it return shifted[it_index];
    }
    return char;
}

// Motions carry range semantics independently of the editor's selection actions.
Vim_Motion :: struct {
    pos: s32;
    valid := true;
    linewise: bool;
    inclusive: bool;
    exact_end: bool; // Do not adjust an exclusive endpoint at the start of a line.
    jump: bool;
}

Vim_Mark :: struct { pos: s32; valid: bool; }

Vim_Repeat_State :: struct {
    recording: bool;
    replaying: bool;
    replay_index: s64;

    revision_before: u64;
    undo_before: s32;

    draft: Array(Vim_Replay_Step);
    last_change: Array(Vim_Replay_Step);
    repeat_count: s32;
}

vim_copy_cursors :: (editor: *Editor) -> [] Cursor {
    result := NewArray(editor.cursors.count, Cursor,, allocator = temp);
    for editor.cursors { result[it_index] = it; }
    return result;
}

vim_normal_pos :: (buffer: Buffer, pos: s32) -> s32 {
    pos = clamp(pos, 0, cast(s32) buffer.bytes.count);
    line := offset_to_real_line(buffer, pos);
    start := get_real_line_start_offset(buffer, line);
    end := get_real_line_end_offset(buffer, line);

    if pos >= end && end > start then pos = prev_char_offset(buffer.bytes, end);
    return pos;
}

vim_line_range :: (cursor: *Cursor, buffer: Buffer, op: u32) {
    first := offset_to_real_line(buffer, min(cursor.pos, cursor.sel));
    last := offset_to_real_line(buffer, max(cursor.pos, cursor.sel));
    start := get_real_line_start_offset(buffer, first);
    end := get_real_line_end_offset(buffer, last);

    if op == #char "c" {
        start = get_first_nonblank_offset(buffer, start);
    } else if last < get_max_real_line_num(buffer) {
        end = get_real_line_start_offset(buffer, last + 1);
    } else if op == #char "d" && start > 0 {
        // Deleting the final unterminated line also removes the preceding EOL.
        start = get_real_line_end_offset(buffer, first - 1);
    }

    cursor.sel = start;
    cursor.pos = end;
}

vim_apply_operator :: (editor: *Editor, buffer: *Buffer, op: u32, before: [] Cursor) {
    any_text := false;
    for editor.cursors { if has_selection(it) then any_text = true; }

    main := editor.main_cursor;
    original := editor.original_cursor;

    if any_text && (op == #char "y" || !buffer.readonly) {
        new_edit_group(buffer, editor);
        organise_cursors(editor);
        vim_action(editor, buffer, .copy);

        if op != #char "y" then vim_action(editor, buffer, .delete_right_char, undo_cursors = before);
    }

    if op == #char "y" || buffer.readonly {
        resize(*editor.cursors, before.count);
        for before { editor.cursors[it_index] = it; }
        editor.main_cursor = main;
        editor.original_cursor = original;
    }

    for * editor.cursors { it.sel = it.pos; }
    if op == #char "c" && !buffer.readonly then editor.vim.mode = .Insert;
    editor.refresh_selection = true;
}

vim_line_operator :: (editor: *Editor, buffer: *Buffer, op: u32, times: s32) {
    before := vim_copy_cursors(editor);
    for * cursor: editor.cursors {
        line := offset_to_real_line(buffer, cursor.pos);
        cursor.sel = cursor.pos;
        cursor.pos = get_real_line_start_offset(buffer, min(get_max_real_line_num(buffer), line + times - 1));
        vim_line_range(cursor, buffer, op);
    }

    vim_apply_operator(editor, buffer, op, before);
}

// Vim tracks inclusive endpoints. Focus uses half-open selections for drawing
// and editing, so expand the far end only when exposing the selection.
vim_visual_range :: (cursor: *Cursor, buffer: Buffer, linewise: bool, op: u32) {
    backwards := cursor.pos < cursor.sel;
    if linewise {
        vim_line_range(cursor, buffer, op);
    } else {
        first := min(cursor.pos, cursor.sel);
        last := max(cursor.pos, cursor.sel);
        if last < buffer.bytes.count then last = next_char_offset(buffer.bytes, last);
        cursor.sel = first;
        cursor.pos = last;
    }
    if backwards {
        swap(*cursor.pos, *cursor.sel);
    }
}

vim_visual_restore :: (editor: *Editor) {
    if editor.vim.mode != .Visual return;

    saved := *editor.vim.visual_cursors;
    if saved.count == editor.cursors.count {
        for * cursor, i: editor.cursors { cursor.* = saved.data[i]; }
    }

    reset_keeping_memory(saved);
}

vim_visual_refresh :: (editor: *Editor, buffer: Buffer) {
    if editor.vim.mode != .Visual return;

    saved := *editor.vim.visual_cursors;
    resize(saved, editor.cursors.count);
    for * cursor, i: editor.cursors {
        saved.data[i] = cursor.*;
        vim_visual_range(cursor, buffer, editor.vim.visual_line, #char "y");
    }

    editor.refresh_selection = true;
}

vim_record_jump :: (editor: *Editor, before: Cursor) {
    for * candidate, id: open_editors {
        if candidate == editor {
            history_record_jump(id, before);
            return;
        }
    }
}

vim_motion_range :: (cursor: *Cursor, buffer: Buffer, motion: Vim_Motion, op: u32) {
    first := min(cursor.pos, motion.pos);
    last := max(cursor.pos, motion.pos);
    first_line := offset_to_real_line(buffer, first);
    last_line := offset_to_real_line(buffer, last);
    starts_in_indent := first <= get_first_nonblank_offset(buffer, first);
    linewise := motion.linewise;

    if motion.inclusive {
        if last < buffer.bytes.count && !vim_empty_line_at(buffer, last) then last = next_char_offset(buffer.bytes, last);
    } else if !motion.exact_end && last_line > first_line && last == get_real_line_start_offset(buffer, last_line) && !linewise {
        // An exclusive motion to column zero excludes the destination line.
        last_line -= 1;
        last = get_real_line_end_offset(buffer, last_line);
        linewise = starts_in_indent;
    }

    // A delete spanning lines takes whole lines if only indentation precedes
    // the range and only whitespace follows it on the final line.
    if !linewise && op == #char "d" && starts_in_indent && last_line > first_line {
        linewise = true;
        end := get_real_line_end_offset(buffer, last_line);
        for i: last..end-1 {
            if !ascii_is_space(buffer.bytes[i]) { linewise = false; break; }
        }
    }

    cursor.sel = first;
    cursor.pos = last;
    if linewise {
        cursor.sel = get_real_line_start_offset(buffer, first_line);
        cursor.pos = get_real_line_start_offset(buffer, last_line);
        vim_line_range(cursor, buffer, op);
    }
}

vim_motion :: (editor: *Editor, buffer: *Buffer, char: u32, times: s32, explicit_count: bool, op: u32, g := false) -> bool {
    // Recognize first, so an unsupported key cannot partly modify cursors.
    recognized := false;
    if g {
        recognized = char == #char "g" || char == #char "e" || char == #char "E" || char == #char "j" || char == #char "k";
    } else {
        for "hljkwWbBeE0^$G%{}()+-_HML" { if char == it then recognized = true; }
        if char == #char "\n" then recognized = true;
    }
    if !recognized return false;

    if char == #char "%" && !explicit_count then vim_prepare_pair_tokens(buffer);

    before: [] Cursor;
    if op then before = vim_copy_cursors(editor);
    main := editor.cursors[editor.main_cursor];
    any_valid := false;
    jump := false;

    for * cursor, i: editor.cursors {
        motion := vim_motion_target(editor, buffer, cursor, char, times, explicit_count, op, g);
        if !motion.valid {
            if op then cursor.sel = cursor.pos;
            continue;
        }

        any_valid = true;
        if i == editor.main_cursor then jump = motion.jump && motion.pos != main.pos;

        if op {
            vim_motion_range(cursor, buffer, motion, op);
        } else {
            cursor.pos = vim_normal_pos(buffer, motion.pos);
            if editor.vim.mode != .Visual {
                cursor.sel = cursor.pos;
            } else if !editor.vim.visual_line {
                if char == #char "l" then cursor.pos = motion.pos;
                if char == #char "$" then cursor.pos = get_real_line_end_offset(buffer, offset_to_real_line(buffer, cursor.pos));
            }
        }
        if char != #char "j" && char != #char "k" then cursor.col_wanted = -1;
    }

    if jump && !op then vim_record_jump(editor, main);
    if op && any_valid then vim_apply_operator(editor, buffer, op, before);

    editor.cursor_moved = true;
    editor.refresh_selection = true;
    cursors_start_blinking();
    return true;
}

vim_motion_target :: (editor: *Editor, buffer: *Buffer, cursor: *Cursor, char: u32, times: s32, explicit_count: bool, op: u32, g: bool) -> Vim_Motion {
    pos := cursor.pos;
    line := offset_to_real_line(buffer, pos);
    start := get_real_line_start_offset(buffer, line);
    end := get_real_line_end_offset(buffer, line);
    max_line := get_max_real_line_num(buffer);
    result := Vim_Motion.{pos = pos};

    if g && char == #char "g" || !g && char == #char "G" {
        target := ifx explicit_count then min(times - 1, max_line) else ifx g then 0 else max_line;
        result.pos = get_first_nonblank_offset(buffer, get_real_line_start_offset(buffer, target));
        result.linewise = true;
        result.jump = true;
    } else if char == #char "j" || char == #char "k" {
        coords := ifx g then offset_to_coords(editor, buffer, pos) else offset_to_real_coords(buffer, pos);
        if cursor.col_wanted < 0 then cursor.col_wanted = coords.col;
        coords.col = cursor.col_wanted;
        coords.line += ifx char == #char "j" then times else -times;
        result.pos = ifx g then coords_to_offset(editor, buffer, coords) else real_coords_to_offset(buffer, coords);
        result.linewise = !g;
        result.valid = result.pos != pos;
    } else if char == #char "$" {
        if times > 1 && line == max_line && op return .{pos = pos, valid = false};

        target := min(max_line, line + times - 1);
        result.pos = get_real_line_end_offset(buffer, target);
        target_start := get_real_line_start_offset(buffer, target);

        if result.pos > target_start {
            result.pos = prev_char_offset(buffer.bytes, result.pos);
            result.inclusive = true;
        } else {
            result.exact_end = true;
        }
    } else if char == #char "0" {
        result.pos = start;
    } else if char == #char "^" {
        result.pos = get_first_nonblank_offset(buffer, pos);
    } else if char == #char "+" || char == #char "-" || char == #char "_" || char == #char "\n" {
        delta := times;
        if char == #char "-" then delta = -times;
        if char == #char "_" then delta = times - 1;

        target := line + delta;
        if target < 0 || target > max_line return .{pos = pos, valid = false};

        result.pos = get_first_nonblank_offset(buffer, get_real_line_start_offset(buffer, target));
        result.linewise = true;
    } else if char == #char "H" || char == #char "M" || char == #char "L" {
        top, bottom := vim_visible_lines(editor, buffer);
        target := min(top + times - 1, bottom);
        if char == #char "M" then target = (top + bottom) / 2;
        if char == #char "L" then target = max(top, bottom - times + 1);

        screen_start := get_line_start_offset(editor, buffer, target);
        result.pos = max(screen_start, get_first_nonblank_offset(buffer, screen_start));
        result.linewise = true;
    } else if char == #char "%" {
        if explicit_count {
            if times > 100 return .{pos = pos, valid = false};

            target := ((max_line + 1) * times + 99) / 100 - 1;
            result.pos = get_first_nonblank_offset(buffer, get_real_line_start_offset(buffer, max(cast(s32) 0, target)));
            result.linewise = true;
        } else {
            result.pos, result.valid = vim_matching_pair(buffer, pos);
            result.inclusive = true;
        }
        result.jump = true;
    } else if char == #char "{" || char == #char "}" {
        for 1..times {
            target := vim_paragraph_motion(buffer, result.pos, char == #char "{");
            if target == result.pos return .{pos = pos, valid = false};
            result.pos = target;
        }
        result.jump = true;
    } else if char == #char "(" || char == #char ")" {
        for 1..times {
            target := vim_sentence_motion(buffer, result.pos, char == #char "(");
            if target == result.pos return .{pos = pos, valid = false};
            result.pos = target;
        }
        result.jump = true;
    } else if g {
        for 1..times {
            if result.pos == 0 return .{pos = pos, valid = false};
            result.pos = vim_word_end_backward(buffer, result.pos, char == #char "E");
        }
        result.inclusive = true;
    } else if char == #char "h" || char == #char "l" {
        for 1..times {
            if char == #char "h" && result.pos > start then result.pos = prev_char_offset(buffer.bytes, result.pos);
            if char == #char "l" && result.pos < end then result.pos = next_char_offset(buffer.bytes, result.pos);
        }
        result.valid = result.pos != pos;
    } else {
        motion := char;
        if op == #char "c" && pos < buffer.bytes.count && !ascii_is_space(buffer.bytes[pos]) {
            if char == #char "w" then motion = #char "e";
            if char == #char "W" then motion = #char "E";
        }

        for step: 1..times {
            if motion == #char "w" || motion == #char "W" {
                on_word := result.pos < buffer.bytes.count && vim_word_class(buffer.bytes[result.pos]) != 0;
                result.pos = vim_word_forward(buffer, result.pos, motion == #char "W", stop_at_eol = op != 0 && step == times && on_word);
            }
            if motion == #char "b" || motion == #char "B" then result.pos = vim_word_backward(buffer, result.pos, motion == #char "B");
            if motion == #char "e" || motion == #char "E" then result.pos = vim_word_end(buffer, result.pos, motion == #char "E", include_current = motion != char && step == 1);
        }

        result.inclusive = motion == #char "e" || motion == #char "E";
    }

    return result;
}

vim_word_end_backward :: (buffer: Buffer, pos: s32, big: bool) -> s32 {
    if pos <= 0 return 0;
    kind := ifx pos < buffer.bytes.count then vim_word_class(buffer.bytes[pos], big) else 0;
    pos = prev_char_offset(buffer.bytes, pos);
    if kind != 0 {
        while pos > 0 && vim_word_class(buffer.bytes[pos], big) == kind { pos = prev_char_offset(buffer.bytes, pos); }
    }
    while pos > 0 && vim_word_class(buffer.bytes[pos], big) == 0 {
        if vim_empty_line_at(buffer, pos) then break;
        pos = prev_char_offset(buffer.bytes, pos);
    }
    return pos;
}

vim_empty_line_at :: (buffer: Buffer, pos: s32) -> bool {
    return pos < buffer.bytes.count && buffer.bytes[pos] == #char "\n" &&
           (pos == 0 || buffer.bytes[pos - 1] == #char "\n");
}

vim_blank_line :: (buffer: Buffer, line: s32) -> bool {
    return get_real_line_start_offset(buffer, line) == get_real_line_end_offset(buffer, line);
}

vim_paragraph_motion :: (buffer: Buffer, pos: s32, backward: bool) -> s32 {
    line := offset_to_real_line(buffer, pos);
    max_line := get_max_real_line_num(buffer);
    delta: s32 = cast(s32) (ifx backward then -1 else 1);
    // Skip an initial run of empty lines, then find the next paragraph boundary.
    while vim_blank_line(buffer, line) {
        next := line + delta;
        if next < 0 return 0;
        if next > max_line return xx buffer.bytes.count;
        line = next;
    }
    while true {
        next := line + delta;
        if next < 0 return 0;
        if next > max_line return xx buffer.bytes.count;
        line = next;
        if vim_blank_line(buffer, line) return get_real_line_start_offset(buffer, line);
    }
    return pos;
}

vim_sentence_start :: (buffer: Buffer, pos: s32) -> bool {
    if pos == 0 return true;
    if pos >= buffer.bytes.count || ascii_is_space(buffer.bytes[pos]) return false;
    previous := prev_char_offset(buffer.bytes, pos);
    if !ascii_is_space(buffer.bytes[previous]) return false;
    while ascii_is_space(buffer.bytes[previous]) {
        if vim_empty_line_at(buffer, previous) return true;
        if previous == 0 return false;
        previous = prev_char_offset(buffer.bytes, previous);
    }
    while previous > 0 && (buffer.bytes[previous] == #char "\"" || buffer.bytes[previous] == #char "'" || buffer.bytes[previous] == #char ")" || buffer.bytes[previous] == #char "]") {
        previous = prev_char_offset(buffer.bytes, previous);
    }
    return buffer.bytes[previous] == #char "." || buffer.bytes[previous] == #char "!" || buffer.bytes[previous] == #char "?";
}

vim_sentence_motion :: (buffer: Buffer, pos: s32, backward: bool) -> s32 {
    // An empty line is its own stop. Skip the rest of an empty run when
    // starting there so each count makes progress.
    if vim_empty_line_at(buffer, pos) {
        if backward {
            while pos > 0 && vim_empty_line_at(buffer, pos - 1) { pos -= 1; }
        } else {
            while vim_empty_line_at(buffer, pos + 1) { pos += 1; }
        }
    }
    while true {
        if backward {
            if pos == 0 return 0;
            pos = prev_char_offset(buffer.bytes, pos);
        } else {
            if pos >= buffer.bytes.count return xx buffer.bytes.count;
            pos = next_char_offset(buffer.bytes, pos);
        }
        if vim_empty_line_at(buffer, pos) || vim_sentence_start(buffer, pos) return pos;
    }
    return pos;
}

vim_visible_lines :: (editor: *Editor, buffer: Buffer) -> s32, s32 {
    height := max(cast(s32) 1, editor.text_height);
    step := max(cast(s32) 1, cast(s32) line_height);
    top := clamp((editor.viewport.top + step - 1) / step, 0, get_max_line_num(editor, buffer));
    bottom := clamp((editor.viewport.top + height) / step - 1, top, get_max_line_num(editor, buffer));
    return top, bottom;
}

vim_mark :: (editor: *Editor, buffer: *Buffer, command: u32, name: u32, op: u32) {
    if name < #char "a" || name > #char "z" return;
    mark := *buffer.vim_marks[name - #char "a"];
    if command == #char "m" {
        if !op then mark.* = .{pos = editor.cursors[editor.main_cursor].pos, valid = true};
        return;
    }
    if !mark.valid return;
    before := vim_copy_cursors(editor);
    target := vim_normal_pos(buffer, mark.pos);
    if command == #char "'" then target = get_first_nonblank_offset(buffer, target);
    for * cursor: editor.cursors {
        if op {
            vim_motion_range(cursor, buffer, .{pos = target, linewise = command == #char "'"}, op);
        } else {
            cursor.pos = target;
            if editor.vim.mode != .Visual then cursor.sel = target;
        }
        cursor.col_wanted = -1;
    }
    if op then vim_apply_operator(editor, buffer, op, before);
    else if before[editor.main_cursor].pos != target then vim_record_jump(editor, before[editor.main_cursor]);
    editor.cursor_moved = true;
    editor.refresh_selection = true;
}

vim_clear_command :: (editor: *Editor) {
    using editor.vim;
    prefix = 0;
    pending = 0;
    count = 0;
    operator_count = 0;
}

vim_is_find :: (key: u32) -> bool {
    return key == #char "f" || key == #char "F" || key == #char "t" || key == #char "T";
}

vim_handle_control :: (editor: *Editor, buffer: *Buffer, key: Input.Key_Code) -> bool {
    if key != #char "R" && key != #char "O" && key != #char "I" &&
       key != #char "D" && key != #char "U" && key != #char "F" && key != #char "B" return false;
    times := max(cast(s32) 1, editor.vim.count);
    explicit_count := editor.vim.count > 0;
    vim_clear_command(editor);
    editor.vim.repeat.recording = false;
    if key == #char "R" {
        for 1..times { vim_action(editor, buffer, .redo); }
        return true;
    }
    if key == #char "O" || key == #char "I" {
        if editor.vim.mode == .Visual return true;
        for 1..times {
            if key == #char "O" then action_cursor_go_back(); else action_cursor_go_forward();
        }
        return true;
    }
    vim_visual_restore(editor);
    defer vim_visual_refresh(editor, buffer);
    top, bottom := vim_visible_lines(editor, buffer);
    height := bottom - top + 1;
    // Use the pane height even when the file is shorter than the viewport.
    if editor.text_height > 0 then height = max(cast(s32) 1, editor.text_height / max(cast(s32) 1, cast(s32) line_height));
    distance: s32;
    if key == #char "D" || key == #char "U" {
        if explicit_count then editor.vim.half_page = times;
        distance = editor.vim.half_page;
        if !distance then distance = max(cast(s32) 1, height / 2);
    } else {
        distance = max(cast(s32) 1, height - 2) * times;
    }
    if key == #char "U" || key == #char "B" then distance = -distance;
    for * cursor: editor.cursors {
        coords := offset_to_coords(editor, buffer, cursor.pos);
        coords.line += distance;
        cursor.pos = vim_normal_pos(buffer, coords_to_offset(editor, buffer, coords));
        if editor.vim.mode != .Visual then cursor.sel = cursor.pos;
        cursor.col_wanted = -1;
    }
    target := clamp(editor.viewport.top + distance * cast(s32) line_height, 0, get_max_y_scroll(editor, buffer));
    snap_viewport_top_to_target(editor, buffer, target);
    editor.cursor_moved = true;
    editor.refresh_selection = true;
    redraw_requested = true;
    return true;
}

vim_paragraph_object :: (buffer: Buffer, origin: s32, around: bool, times: s32) -> s32, s32, bool {
    first := offset_to_real_line(buffer, origin);
    last := first;
    max_line := get_max_real_line_num(buffer);
    blank := vim_paragraph_object_blank(buffer, first);
    while first > 0 && vim_paragraph_object_blank(buffer, first - 1) == blank { first -= 1; }
    for step: 1..times {
        while last < max_line && vim_paragraph_object_blank(buffer, last + 1) == blank { last += 1; }
        if around {
            if blank && last < max_line {
                last += 1;
                while last < max_line && !vim_paragraph_object_blank(buffer, last + 1) { last += 1; }
            } else {
                while last < max_line && vim_paragraph_object_blank(buffer, last + 1) { last += 1; }
            }
        }
        if step < times {
            if last == max_line return origin, origin, false;
            last += 1;
            blank = vim_paragraph_object_blank(buffer, last);
        }
    }
    // At EOF, ap includes preceding whitespace if no trailing whitespace exists.
    if around && last == max_line && !vim_paragraph_object_blank(buffer, last) {
        while first > 0 && vim_paragraph_object_blank(buffer, first - 1) { first -= 1; }
    }
    start := get_real_line_start_offset(buffer, first);
    end := ifx last < max_line then get_real_line_start_offset(buffer, last + 1) else cast(s32) buffer.bytes.count;
    return start, end, true;
}

vim_paragraph_object_blank :: (buffer: Buffer, line: s32) -> bool {
    start := get_real_line_start_offset(buffer, line);
    end := get_real_line_end_offset(buffer, line);
    for i: start..end-1 { if !ascii_is_space(buffer.bytes[i]) return false; }
    return true;
}

// Replay semantic input, so repeats use the current cursor and existing edit
// actions (including auto-indent, UTF-8, readonly checks and undo bookkeeping).
Vim_Replay_Step :: struct {
    kind: enum { Command; Text; Action; Search_Key; Escape; };
    char: u32;
    action: Action_Editors;
    event: Input.Event;
}

vim_repeat_begin :: (editor: *Editor, buffer: *Buffer) {
    using editor.vim.repeat;
    if recording || replaying return;

    new_edit_group(buffer, editor);
    recording = true;
    revision_before = buffer.content_revision;
    undo_before = buffer.undos.count;
    reset_keeping_memory(*draft);
}

vim_repeat_record :: (editor: *Editor, step: Vim_Replay_Step) {
    using editor.vim.repeat;
    if recording && !replaying then add(*draft, step);
}

vim_repeat_finish :: (editor: *Editor, buffer: *Buffer) {
    using editor.vim.repeat;
    if !recording || replaying return;
    if editor.vim.mode != .Normal || editor.vim.pending || editor.vim.prefix || editor.vim.count || editor.search_bar.active return;

    if buffer.content_revision != revision_before {
        new_edit_group(buffer, editor);
        vim_merge_undo(buffer, undo_before);
        repeat_count = 0;
        swap(*last_change, *draft);
    }

    recording = false;
    reset_keeping_memory(*draft);
}

vim_merge_undo :: (buffer: *Buffer, first: s32) {
    if first < 0 || first >= buffer.undos.count - 1 return;

    merged: Array(Buffer.Edit);
    for i: first..buffer.undos.count-1 {
        for buffer.undos[i].edits { add(*merged, it); }
        array_free(buffer.undos[i].edits);
        if i != first then array_free(buffer.undos[i].cursors_before);
        if i != buffer.undos.count - 1 then array_free(buffer.undos[i].cursors_after);
    }

    group := *buffer.undos[first];
    group.edits = to_owned_array(*merged, free_memory = true);
    group.cursors_after = buffer.undos[buffer.undos.count - 1].cursors_after;
    buffer.undos.count = first + 1;
}

vim_repeat_change :: (editor: *Editor, buffer: *Buffer, supplied_count: s32) {
    using editor.vim.repeat;
    if replaying || !last_change || buffer.readonly return;

    count := ifx supplied_count > 0 then supplied_count else repeat_count;
    revision := buffer.content_revision;
    replaying = true;
    defer replaying = false;

    new_edit_group(buffer, editor);
    first := buffer.undos.count;

    index: s64 = 0;
    operator_index: s64 = -1;
    if count > 0 {
        while index < last_change.count && last_change[index].kind == .Command && last_change[index].char >= #char "0" && last_change[index].char <= #char "9" { index += 1; }
        if index < last_change.count && (last_change[index].char == #char "d" || last_change[index].char == #char "c" || last_change[index].char == #char "y") then operator_index = index;
        for char: tprint("%", count) { vim_handle_char(editor, buffer, char); }
    }

    while index < last_change.count {
        replay_index = index;
        step := last_change[index];
        if step.kind == {
            case .Command; vim_handle_char(editor, buffer, step.char);
            case .Text;
                if editor.vim.mode == .Insert || editor.search_bar.active then active_editor_type_char(step.char);
            case .Action;
                if editor.vim.mode == .Insert then vim_action(editor, buffer, step.action);
            case .Search_Key;
                if editor.search_bar.active then vim_search_handle_event(editor, buffer, step.event);
            case .Escape; vim_enter_normal(editor, buffer);
        }

        index += 1;

        // A count on dot replaces both components of an operator/motion count.
        if index == operator_index + 1 {
            if index < last_change.count && last_change[index].kind == .Command && last_change[index].char >= #char "1" && last_change[index].char <= #char "9" {
                index += 1;
                while index < last_change.count && last_change[index].kind == .Command && last_change[index].char >= #char "0" && last_change[index].char <= #char "9" { index += 1; }
            }
        }
    }

    new_edit_group(buffer, editor);
    vim_merge_undo(buffer, first);
    if buffer.content_revision != revision then repeat_count = count;

    // A failed repeated search/find must not strand the editor in a prefix.
    if editor.vim.mode == .Normal then vim_clear_command(editor);
}

vim_finish_counted_insert :: (editor: *Editor, buffer: *Buffer) {
    using editor.vim;
    times := insert_count;
    insert_count = 0;
    if times <= 1 || buffer.readonly || (!repeat.recording && !repeat.replaying) return;

    // Replay just the Insert input. The opening command and Escape run once.
    was_replaying := repeat.replaying;
    steps := ifx was_replaying then repeat.last_change else repeat.draft;
    end := ifx was_replaying then repeat.replay_index else steps.count - 1;
    repeat.replaying = true;
    defer repeat.replaying = was_replaying;

    for 2..times {
        if insert_on_new_lines then vim_action(editor, buffer, .new_line_below_without_breaking);
        for i: insert_start..end-1 {
            step := steps[i];
            if step.kind == .Text then active_editor_type_char(step.char);
            if step.kind == .Action then vim_action(editor, buffer, step.action);
        }
    }
}

vim_repeat_insert_action :: (editor: *Editor, action: Action_Editors) {
    if action == {
        case .delete_left_char; #through;
        case .delete_right_char; #through;
        case .delete_left_through_word; #through;
        case .delete_to_start_of_line; #through;
        case .break_line; #through;
        case .indent_or_go_to_next_tabstop; #through;
        case .paste;
            vim_repeat_record(editor, .{kind = .Action, action = action});
        case;
            // Cursor moves and unrelated application shortcuts end a recording;
            // never replay commands such as Save or Close as part of dot.
            editor.vim.repeat.recording = false;
    }
}
