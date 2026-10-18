// Optional, deliberately small Vim command layer. Edits go through the regular
// editor action path so readonly buffers, undo, rescanning and cursor updates agree.
Vim_State :: struct {
    mode: enum { Normal; Insert; Visual; };
    pending: u32;
    count: s32;
    operator_count: s32;
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
    if char == #char "h" || char == #char "l" || char == #char "w" || char == #char "b" {
        for * cursor : editor.cursors {
            for 1..times {
                start := get_real_line_start_offset(buffer, offset_to_real_line(buffer, cursor.pos));
                end := get_real_line_end_offset(buffer, offset_to_real_line(buffer, cursor.pos));
                if char == #char "h" && cursor.pos > start then cursor.pos = prev_char_offset(buffer.bytes, cursor.pos);
                if char == #char "l" && cursor.pos < end then cursor.pos = next_char_offset(buffer.bytes, cursor.pos);
                if char == #char "w" then cursor.pos = vim_word_forward(buffer, cursor.pos);
                if char == #char "b" then cursor.pos = vim_word_backward(buffer, cursor.pos);
            }
            cursor.col_wanted = -1;
            if !op && mode != .Visual then cursor.sel = cursor.pos;
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
            case #char "o"; #through;
            case #char "O";
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
            case #char "/"; vim_action(editor, buffer, .search_in_buffer);
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

// Whitespace, keyword characters and punctuation form separate Vim word groups.
vim_word_class :: (byte: u8) -> int {
    if ascii_is_space(byte) return 0;
    if ascii_is_alnum(byte) || byte >= 128 return 1;
    return 2;
}

vim_word_forward :: (buffer: Buffer, pos: s32) -> s32 {
    if pos >= buffer.bytes.count return pos;
    kind := vim_word_class(buffer.bytes[pos]);
    while pos < buffer.bytes.count && vim_word_class(buffer.bytes[pos]) == kind {
        pos = next_char_offset(buffer.bytes, pos);
    }
    while pos < buffer.bytes.count && vim_word_class(buffer.bytes[pos]) == 0 {
        pos = next_char_offset(buffer.bytes, pos);
    }
    return pos;
}

vim_word_backward :: (buffer: Buffer, pos: s32) -> s32 {
    if pos == 0 return pos;
    pos = prev_char_offset(buffer.bytes, pos);
    while pos > 0 && vim_word_class(buffer.bytes[pos]) == 0 {
        pos = prev_char_offset(buffer.bytes, pos);
    }
    kind := vim_word_class(buffer.bytes[pos]);
    while pos > 0 {
        previous := prev_char_offset(buffer.bytes, pos);
        if vim_word_class(buffer.bytes[previous]) != kind break;
        pos = previous;
    }
    return pos;
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
    if buffer.edits.count == 0 {
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
