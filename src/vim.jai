// Optional, deliberately small Vim command layer. Edits go through the regular
// editor action path so readonly buffers, undo, rescanning and cursor updates agree.
Vim_State :: struct {
    mode: enum { Normal; Insert; Visual; };
    pending: u32;
    count: s32;
    operator_count: s32;
    object_prefix: u32;
    object_operator: u32;
    object_count: s32;
    find_command: u32;
    find_operator: u32;
    find_count: s32;
    last_find_command: u32;
    last_find_char: u32;
}

vim_action :: (editor: *Editor, buffer: *Buffer, action: Action_Editors, select := false) {
    event: Input.Event;
    event.type = .KEYBOARD;
    event.key_pressed = 1;
    event.modifier_flags.shift_pressed = select;
    editor.cursor_moved = false;
    undo_count := buffer.undos.count;
    redo_count := buffer.redos.count;
    active_editor_handle_event(editor, buffer, event, action);
    // Focus normally previews a moved undo cursor first; Vim's u/Ctrl-R apply immediately.
    if (action == .undo && undo_count > 0 && buffer.undos.count == undo_count) ||
       (action == .redo && redo_count > 0 && buffer.redos.count == redo_count) {
        active_editor_handle_event(editor, buffer, event, action);
    }
}

vim_enter_normal :: (editor: *Editor, buffer: *Buffer) {
    if editor.vim.mode == .Insert {
        new_edit_group(buffer, editor);
        // Insert positions sit after the typed character.
        for * cursor : editor.cursors {
            start := get_real_line_start_offset(buffer, offset_to_real_line(buffer, cursor.pos));
            if cursor.pos > start then cursor.pos = prev_char_offset(buffer.bytes, cursor.pos);
        }
    }
    last_command := editor.vim.last_find_command;
    last_char := editor.vim.last_find_char;
    editor.vim = .{};
    editor.vim.last_find_command = last_command;
    editor.vim.last_find_char = last_char;
    vim_action(editor, buffer, .escape);
    for * editor.cursors { it.sel = it.pos; }
    editor.cursor_moved = true;
    editor.refresh_selection = true;
    redraw_requested = true;
}

vim_handle_char :: (editor: *Editor, buffer: *Buffer, char: u32) {
    using editor.vim;
    redraw_requested = true;
    defer {
        if mode == .Normal && pending == 0 {
            for * cursor : editor.cursors {
                start := get_real_line_start_offset(buffer, offset_to_real_line(buffer, cursor.pos));
                end := get_real_line_end_offset(buffer, offset_to_real_line(buffer, cursor.pos));
                if cursor.pos == end && end > start then cursor.pos = prev_char_offset(buffer.bytes, cursor.pos);
                cursor.sel = cursor.pos;
            }
            editor.refresh_selection = true;
        }
    }

    // A find target is literal text, including digits and command letters.
    if find_command {
        command := find_command;
        op := find_operator;
        times := find_count;
        find_command = 0;
        find_operator = 0;
        find_count = 0;
        last_find_command = command;
        last_find_char = char;
        vim_find(editor, buffer, command, char, times, op);
        return;
    }

    if object_prefix {
        around := object_prefix == #char "a";
        op := object_operator;
        times := object_count;
        object_prefix = 0;
        object_operator = 0;
        object_count = 0;
        vim_select_object(editor, buffer, char, around, times, op);
        return;
    }

    if char >= #char "0" && char <= #char "9" && (char != #char "0" || count > 0) {
        count = min(cast(s32) 1000, count * 10 + cast(s32)(char - #char "0"));
        return;
    }
    times := max(cast(s32) 1, count);
    count = 0;
    op := pending;
    pending = 0;
    if operator_count > 0 then times = min(cast(s32) 1000, times * operator_count);
    operator_count = 0;

    yank_positions: [..] s32;
    yank_positions.allocator = temp;
    if op == #char "y" {
        for editor.cursors { array_add(*yank_positions, it.pos); }
    }
    defer {
        if op == #char "y" && yank_positions.count == editor.cursors.count {
            for * cursor, i : editor.cursors { cursor.pos = yank_positions[i]; cursor.sel = cursor.pos; }
        }
    }

    if op == #char "g" {
        if char == #char "g" then vim_action(editor, buffer, .jump_to_file_start, mode == .Visual);
        return;
    }

    if (op || mode == .Visual) && (char == #char "i" || char == #char "a") {
        object_prefix = char;
        object_operator = op;
        object_count = times;
        return;
    }

    if char == #char "f" || char == #char "F" || char == #char "t" || char == #char "T" {
        find_command = char;
        find_operator = op;
        find_count = times;
        return;
    }
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
        // dd, cc and yy select whole lines, including their newline.
        vim_action(editor, buffer, .select_line);
        for 1..times-1 {
            vim_action(editor, buffer, .move_down, true);
        }
        // cc preserves the first line's indentation and the final newline.
        if op == #char "c" {
            for * cursor : editor.cursors {
                cursor.sel = get_first_nonblank_offset(buffer, cursor.sel);
                if cursor.pos > cursor.sel && buffer.bytes[cursor.pos - 1] == #char "\n" then cursor.pos -= 1;
            }
        }
        has_text := false;
        for editor.cursors { if has_selection(it) then has_text = true; }
        vim_action(editor, buffer, .copy);
        if op != #char "y" && has_text {
            new_edit_group(buffer, editor);
            vim_action(editor, buffer, .delete_right_char);
            new_edit_group(buffer, editor);
        }
        for * editor.cursors { it.sel = it.pos; }
        if op == #char "c" {
            vim_prepare_insert(editor, buffer, .At_Cursor);
            mode = .Insert;
        }
        return;
    }

    if op == #char "c" && char == #char "$" {
        vim_change_to_end(editor, buffer);
        mode = .Insert;
        return;
    }

    movement := cast(Action_Editors) INVALID_KEYMAP_ACTION;
    if char == {
        case #char "j"; movement = .move_down;
        case #char "k"; movement = .move_up;
        case #char "$"; movement = .jump_to_line_end;
        case #char "G"; movement = .jump_to_file_end;
    }
    if char == #char "h" || char == #char "l" || char == #char "w" || char == #char "b" ||
       char == #char "W" || char == #char "B" || char == #char "e" || char == #char "E" {
        for * cursor : editor.cursors {
            // Vim treats cw/cW on text like ce/cE, leaving following spaces alone.
            motion := char;
            if op == #char "c" && cursor.pos < buffer.bytes.count && !ascii_is_space(buffer.bytes[cursor.pos]) {
                if char == #char "w" then motion = #char "e";
                if char == #char "W" then motion = #char "E";
            }
            for step: 1..times {
                start := get_real_line_start_offset(buffer, offset_to_real_line(buffer, cursor.pos));
                end := get_real_line_end_offset(buffer, offset_to_real_line(buffer, cursor.pos));
                if char == #char "h" && cursor.pos > start then cursor.pos = prev_char_offset(buffer.bytes, cursor.pos);
                if char == #char "l" && cursor.pos < end then cursor.pos = next_char_offset(buffer.bytes, cursor.pos);
                if motion == #char "w" || motion == #char "W" then cursor.pos = vim_word_forward(buffer, cursor.pos, motion == #char "W");
                if motion == #char "b" || motion == #char "B" then cursor.pos = vim_word_backward(buffer, cursor.pos, motion == #char "B");
                if motion == #char "e" || motion == #char "E" then cursor.pos = vim_word_end(buffer, cursor.pos, motion == #char "E", include_current = motion != char && step == 1);
            }
            if op && (motion == #char "e" || motion == #char "E") && cursor.pos >= cursor.sel && cursor.pos < buffer.bytes.count {
                cursor.pos = next_char_offset(buffer.bytes, cursor.pos);
            }
            cursor.col_wanted = -1;
            if !op && mode != .Visual then cursor.sel = cursor.pos;
        }
        editor.cursor_moved = true;
        editor.refresh_selection = true;
        cursors_start_blinking();
    } else if char == #char "%" {
        vim_prepare_pair_tokens(buffer);
        for * cursor : editor.cursors {
            target, found := vim_matching_pair(buffer, cursor.pos);
            if !found continue;
            if op {
                // % is inclusive in either direction.
                cursor.sel = max(cursor.pos, target);
                cursor.pos = min(cursor.pos, target);
                cursor.sel = next_char_offset(buffer.bytes, cursor.sel);
            } else {
                cursor.pos = target;
                if mode != .Visual then cursor.sel = target;
            }
            cursor.col_wanted = -1;
        }
        editor.cursor_moved = true;
        editor.refresh_selection = true;
        cursors_start_blinking();
    } else if char == #char "^" {
        for * cursor : editor.cursors {
            cursor.pos = get_first_nonblank_offset(buffer, cursor.pos);
            cursor.col_wanted = -1;
            if !op && mode != .Visual then cursor.sel = cursor.pos;
        }
        editor.cursor_moved = true;
        editor.refresh_selection = true;
        cursors_start_blinking();
    } else if char == #char "0" {
        for * cursor : editor.cursors {
            cursor.pos = get_real_line_start_offset(buffer, offset_to_real_line(buffer, cursor.pos));
            cursor.col_wanted = -1;
            if !op && mode != .Visual then cursor.sel = cursor.pos;
        }
        editor.cursor_moved = true;
        editor.refresh_selection = true;
    } else if movement != cast(Action_Editors) INVALID_KEYMAP_ACTION {
        for 1..times { vim_action(editor, buffer, movement, op != 0 || mode == .Visual); }
    } else {
        if op return;  // An unsupported operator motion cancels the pending command.
        if char == {
            case #char "g"; pending = char;
            case #char "d"; #through;
            case #char "c"; #through;
            case #char "y";
                if mode == .Visual {
                    vim_action(editor, buffer, .copy);
                    if char != #char "y" {
                        new_edit_group(buffer, editor);
                        vim_action(editor, buffer, .delete_right_char);
                        new_edit_group(buffer, editor);
                    }
                    for * editor.cursors { it.sel = it.pos; }
                    mode = ifx char == #char "c" then .Insert else .Normal;
                } else {
                    pending = char;
                    operator_count = times;
                }
            case #char "v";
                if mode == .Visual {
                    vim_enter_normal(editor, buffer);
                } else {
                    mode = .Visual;
                    for * editor.cursors { it.sel = it.pos; }
                }
            case #char "i";
                vim_prepare_insert(editor, buffer, .At_Cursor);
                mode = .Insert;
            case #char "a";
                vim_prepare_insert(editor, buffer, .Append);
                mode = .Insert;
            case #char "I";
                vim_prepare_insert(editor, buffer, .First_Nonblank);
                mode = .Insert;
            case #char "A";
                vim_prepare_insert(editor, buffer, .Line_End);
                mode = .Insert;
            case #char "J";
                new_edit_group(buffer, editor);
                before := NewArray(editor.cursors.count, Cursor,, allocator = temp);
                for * cursor, i: editor.cursors {
                    before[i] = cursor.*;
                    if mode != .Visual {
                        line := offset_to_real_line(buffer, cursor.pos);
                        last := min(line + max(cast(s32) 2, times) - 1, cast(s32) buffer.line_starts.count - 1);
                        cursor.sel = get_real_line_start_offset(buffer, line);
                        cursor.pos = get_real_line_end_offset(buffer, last);
                    }
                }
                undo_count := buffer.undos.count;
                vim_action(editor, buffer, .join_lines);
                new_edit_group(buffer, editor);
                if buffer.undos.count > undo_count {
                    group := peek_pointer(buffer.undos);
                    if group.cursors_before.count == before.count {
                        for cursor, i: before { group.cursors_before[i] = cursor; }
                    }
                } else if editor.cursors.count == before.count {
                    for * cursor, i: editor.cursors { cursor.* = before[i]; }
                }
                if mode == .Visual then mode = .Normal;
            case #char "o"; #through;
            case #char "O";
                if mode == .Visual {
                    for * cursor : editor.cursors {
                        old := cursor.pos;
                        cursor.pos = cursor.sel;
                        cursor.sel = old;
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
                vim_prepare_insert(editor, buffer, .At_Cursor, start_group = false);
                mode = .Insert;
            case #char "C";
                vim_change_to_end(editor, buffer);
                mode = .Insert;
            case #char "x"; #through;
            case #char "p"; #through;
            case #char "u"; #through;
            case #char "D";
                action: Action_Editors = .delete_right_char;
                if char == #char "p" then action = .paste;
                if char == #char "u" then action = .undo;
                if char == #char "D" then action = .cut_to_end_of_line;
                new_edit_group(buffer, editor);
                if char == #char "x" && mode != .Visual {
                    before := NewArray(editor.cursors.count, Cursor,, allocator = temp);
                    for cursor, i : editor.cursors { before[i] = cursor; }
                    undo_count := buffer.undos.count;
                    any_selection := false;
                    for * cursor : editor.cursors {
                        end := get_real_line_end_offset(buffer, offset_to_real_line(buffer, cursor.pos));
                        cursor.sel = cursor.pos;
                        for 1..times {
                            if cursor.pos < end then cursor.pos = next_char_offset(buffer.bytes, cursor.pos);
                        }
                        if has_selection(cursor) then any_selection = true;
                    }
                    if any_selection {
                        vim_action(editor, buffer, action);
                        // The selection is an implementation detail of x, not its undo cursor.
                        if buffer.undos.count > undo_count {
                            group := peek_pointer(buffer.undos);
                            if group.cursors_before.count == before.count {
                                for cursor, i : before { group.cursors_before[i] = cursor; }
                            }
                        }
                    }
                } else {
                    for 1..times { vim_action(editor, buffer, action); }
                }
                new_edit_group(buffer, editor);
                if mode == .Visual then mode = .Normal;
            case #char "/"; #through;
            case #char "?"; vim_search_open(editor, buffer, char == #char "?", times);
            case #char "n"; #through;
            case #char "N"; vim_search_repeat(editor, buffer, char == #char "N", times);
        }
        return;
    }

    if op {
        has_text := false;
        for editor.cursors { if has_selection(it) then has_text = true; }
        if !has_text return;
        vim_action(editor, buffer, .copy);
        if op != #char "y" {
            new_edit_group(buffer, editor);
            vim_action(editor, buffer, .delete_right_char);
            new_edit_group(buffer, editor);
        }
        for * editor.cursors { it.sel = it.pos; }
        if op == #char "c" then mode = .Insert;
    }
}

vim_search_open :: (editor: *Editor, buffer: *Buffer, backward: bool, times: s32) {
    using bar := *editor.search_bar;
    free(vim_history.draft);
    vim_history = .{};
    reset(*vim_original_cursors);
    for editor.cursors { add(*vim_original_cursors, it); }
    vim_original_main_cursor = editor.main_cursor;
    vim_original_cursor = editor.original_cursor;
    original_cursor_position = editor.cursors[editor.main_cursor];
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
    if editor.vim.mode == .Normal {
        line := offset_to_real_line(buffer, offset);
        start := get_real_line_start_offset(buffer, line);
        end := get_real_line_end_offset(buffer, line);
        if offset == end && end > start then return prev_char_offset(buffer.bytes, offset);
    }
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
    selected_result = index;
    cursor := leave_only_main_cursor(editor);
    cursor.pos = vim_search_position(editor, buffer, results[index].offset);
    if editor.vim.mode != .Visual then cursor.sel = cursor.pos;
    cursor.col_wanted = -1;
    editor.cursor_moved = true;
    editor.refresh_selection = true;
    editor.scroll_to_cursor = .yes;
    jumped = true;
    cursors_start_blinking();
    redraw_requested = true;
}

vim_search_restore_cursors :: (editor: *Editor) {
    using bar := *editor.search_bar;
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
    vim_search_move(editor, buffer, index);
}

vim_search_finish :: (editor: *Editor, buffer: *Buffer, accept: bool) {
    using bar := *editor.search_bar;
    if accept {
        if !input.text {
            replace_text(*input, to_string(vim_pattern));
            search_and_update_results(editor, buffer, jump = true);
        }
        if !is_empty(input.text) {
            reset(*vim_pattern);
            for to_string(input.text) { add(*vim_pattern, it); }
            vim_backward = vim_prompt_backward;
        }
    }
    close_search_bar(editor, jump_to_original_cursor = !accept, keep_results = accept);
    if !accept then reset_search_results(bar);
    editor.refresh_selection = true;
    redraw_requested = true;
}

vim_search_repeat :: (editor: *Editor, buffer: *Buffer, opposite: bool, times: s32) {
    using bar := *editor.search_bar;
    if !vim_pattern return;
    replace_text(*input, to_string(vim_pattern));
    mode = .vim;
    regex_search = true;
    whole_word = false;
    case_sensitive_toggled_manually = false;
    search_and_update_results(editor, buffer);
    origin := editor.cursors[editor.main_cursor].pos;
    index := vim_search_index(editor, buffer, origin, vim_backward != opposite, times);
    vim_search_move(editor, buffer, index);
}

vim_search_handle_event :: (editor: *Editor, buffer: *Buffer, event: Input.Event) -> bool {
    using bar := *editor.search_bar;
    mods := event.modifier_flags;
    key := event.key_code;
    ctrl := mods.ctrl_pressed && !mods.alt_pressed && !mods.cmd_meta_pressed;
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

vim_word_forward :: (buffer: Buffer, pos: s32, big := false) -> s32 {
    if pos >= buffer.bytes.count return pos;
    kind := vim_word_class(buffer.bytes[pos], big);
    while pos < buffer.bytes.count && vim_word_class(buffer.bytes[pos], big) == kind {
        pos = next_char_offset(buffer.bytes, pos);
    }
    while pos < buffer.bytes.count && vim_word_class(buffer.bytes[pos]) == 0 {
        pos = next_char_offset(buffer.bytes, pos);
    }
    return pos;
}

vim_word_backward :: (buffer: Buffer, pos: s32, big := false) -> s32 {
    if pos == 0 return pos;
    pos = prev_char_offset(buffer.bytes, pos);
    while pos > 0 && vim_word_class(buffer.bytes[pos]) == 0 {
        pos = prev_char_offset(buffer.bytes, pos);
    }
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
    for byte, i: buffer.bytes {
        if !vim_pair_delimiter(buffer, cast(s32) i) continue;
        if byte == open then array_add(*stack, cast(s32) i);
        if byte != close || !stack continue;
        left := stack[stack.count - 1];
        stack.count -= 1;
        if left > origin || i < origin continue;
        remaining -= 1;
        if remaining == 0 return cast(s32) (left + (ifx around then 0 else 1)), cast(s32) (i + (ifx around then 1 else 0)), true;
    }
    return origin, origin, false;
}

vim_select_object :: (editor: *Editor, buffer: *Buffer, object: u32, around: bool, times: s32, op: u32) {
    if object != #char "w" && object != #char "W" && object != #char "\"" && object != #char "'" && object != #char "`" {
        vim_prepare_pair_tokens(buffer);
    }
    before := NewArray(editor.cursors.count, Cursor,, allocator = temp);
    any_match := false;
    any_text := false;
    for * cursor, i: editor.cursors {
        before[i] = cursor.*;
        start, end, found := vim_object_range(buffer, cursor.pos, object, around, times);
        if !found {
            if op then cursor.sel = cursor.pos;
            continue;
        }
        any_match = true;
        cursor.sel = start;
        cursor.pos = end;
        cursor.col_wanted = -1;
        if start != end then any_text = true;
    }
    if !any_match return;
    editor.cursor_moved = true;
    editor.refresh_selection = true;
    cursors_start_blinking();
    if !op return;

    // Failed or empty ranges must never fall through to delete_right_char.
    if any_text {
        new_edit_group(buffer, editor);
        vim_action(editor, buffer, .copy);
        if op != #char "y" {
            undo_count := buffer.undos.count;
            vim_action(editor, buffer, .delete_right_char);
            new_edit_group(buffer, editor);
            if buffer.undos.count > undo_count {
                group := peek_pointer(buffer.undos);
                if group.cursors_before.count == before.count {
                    for cursor, i: before { group.cursors_before[i] = cursor; }
                }
            }
        }
    }
    for * cursor, i: editor.cursors {
        if op == #char "y" then cursor.* = before[i];
        cursor.sel = cursor.pos;
    }
    // ci() also enters Insert when the pair is empty.
    if op == #char "c" then editor.vim.mode = .Insert;
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
        if matches && !(repeating && till && first) then remaining -= 1;
        first = false;
    }
    if command == #char "t" then pos = prev_char_offset(buffer.bytes, pos);
    if command == #char "T" then pos = next_char_offset(buffer.bytes, pos);
    return pos, true;
}

vim_find :: (editor: *Editor, buffer: *Buffer, command: u32, char: u32, times: s32, op: u32, repeating := false) {
    before := NewArray(editor.cursors.count, Cursor,, allocator = temp);
    any_selection := false;
    any_match := false;
    for * cursor, i : editor.cursors {
        before[i] = cursor.*;
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

    // Close any preceding insert before recording this operator's edit.
    new_edit_group(buffer, editor);
    vim_action(editor, buffer, .copy);
    if op == #char "y" {
        for * cursor, i : editor.cursors { cursor.* = before[i]; }
    } else {
        undo_count := buffer.undos.count;
        vim_action(editor, buffer, .delete_right_char);
        new_edit_group(buffer, editor);
        if buffer.undos.count > undo_count {
            group := peek_pointer(buffer.undos);
            if group.cursors_before.count == before.count {
                for cursor, i : before { group.cursors_before[i] = cursor; }
            }
        }
        if op == #char "c" then editor.vim.mode = .Insert;
    }
    for * editor.cursors { it.sel = it.pos; }
}

// All insertion commands share blank-line indentation. Nonblank lines retain
// each command's usual insertion position; I always uses the first nonblank.
Vim_Insert_Position :: enum { At_Cursor; Append; First_Nonblank; Line_End; }

vim_prepare_insert :: (editor: *Editor, buffer: *Buffer, where: Vim_Insert_Position, start_group := true) {
    if start_group then new_edit_group(buffer, editor);
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
    editor.cursor_moved = true;
    editor.refresh_selection = true;
    cursors_start_blinking();
}

// Changing to EOL from inside leading whitespace keeps that indentation. Empty
// selections are skipped so C on a blank line cannot consume its newline.
vim_change_to_end :: (editor: *Editor, buffer: *Buffer) {
    new_edit_group(buffer, editor);
    has_text := false;
    for * cursor : editor.cursors {
        if editor.vim.mode != .Visual {
            cursor.sel = max(cursor.pos, get_first_nonblank_offset(buffer, cursor.pos));
            cursor.pos = get_real_line_end_offset(buffer, offset_to_real_line(buffer, cursor.pos));
        }
        if has_selection(cursor) then has_text = true;
    }
    if has_text {
        vim_action(editor, buffer, .copy);
        vim_action(editor, buffer, .delete_right_char);
        new_edit_group(buffer, editor);
    }
    for * editor.cursors { it.sel = it.pos; }
    vim_prepare_insert(editor, buffer, .At_Cursor);
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
