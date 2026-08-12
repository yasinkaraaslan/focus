create_new_project_dialog_handle_event :: (event: Input.Event) -> handled: bool {
    using create_new_project_dialog;

    if event.type == .KEYBOARD && event.key_pressed {
        action, mapping := map_event_to_action(event, Action_Search_Dialog);
        if action == {
            case .escape;                   #through;
            case .close_dialog;             close_create_new_project_dialog();
                                            return true;
            case .open_entry;               create_project(); return true;
            case .open_entry_in_side_pane;  create_project(); return true;
        }

        handled := text_input_handle_event(*input, event);
        return handled;

    } else if event.type == .TEXT_INPUT {
        char := event.utf32;
        text_input_type_char(*input, char);
        return true;
    }
    return false;
}

show_create_new_project_dialog :: () {
    active_global_widget = .create_new_project_dialog;

    using create_new_project_dialog;
    text_input_fully_clear(*input);
    name_already_exists = false;
}

close_create_new_project_dialog :: () {
    activate_editors();
}

create_new_project_dialog: Create_New_Project_Dialog;

Create_New_Project_Dialog :: struct {
    input: Text_Input;
    name_already_exists := false;
}


#scope_file

create_project :: () {
    close_create_new_project_dialog();

    using create_new_project_dialog;

    project_name := to_string(input.text);
    if !project_name.count {
        add_user_error("Project name cannot be empty");
        return;
    }

    // Disallow path separators and other problematic characters
    for byte : input.text {
        if byte == #char "/" || byte == #char "\\" || byte == #char ":" || byte == #char "*"
        || byte == #char "?" || byte == #char "\"" || byte == #char "<" || byte == #char ">"
        || byte == #char "|" {
            add_user_error("Project name contains invalid characters");
            return;
        }
    }

    file_path := tprint("%/%.focus-config", projects_dir, project_name);

    if file_exists(file_path) {
        add_user_error("Project '%' already exists", project_name);
        return;
    }

    success := write_entire_file(file_path, EXAMPLE_PROJECT_FILE_DATA);
    if !success {
        add_user_error("Couldn't create project file '%'", file_path);
        return;
    }

    add_success_message("Project '%' has been created", project_name, dismiss_in_seconds = 3);

    if config.settings.switch_to_project_after_create {
        defer_action_switch_to_project(file_path, open_file_after = file_path);
    }
}
