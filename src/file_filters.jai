// Focus rules deliberately retain their historical wildcard syntax. Git rules
// have a separate parser and matcher; no Git executable or index is involved.
Filter_Reason :: enum { DEFAULT; ALLOW; OUTSIDE_INCLUDE; IGNORE; GITIGNORE; TEMPORARY; }
Filter_Result :: struct {
    ignored: bool;
    explicitly_allowed: bool;
    reason: Filter_Reason;
    source: string;
    line: s64;
}

focus_pattern_matches :: (path: string, fp: File_Pattern) -> bool {
    if begins_with(fp.pattern, "./") {
        relative_pattern := fp;
        relative_pattern.pattern = advance(fp.pattern, 2);
        for member : config.workspace.members {
            if !filter_path_within(path, member) continue;
            relative := trim_left(advance(path, member.count), "/");
            if path_pattern_match(relative, relative_pattern) return true;
        }
        return false;
    }
    if fp.should_match_whole_path return path_pattern_match(path, fp);
    chunk_start := 0;
    for i : 0..path.count {
        if i == path.count || path[i] == #char "/" {
            if path_pattern_match(slice(path, chunk_start, i - chunk_start), fp) return true;
            chunk_start = i + 1;
        }
    }
    return false;
}

focus_pattern_matches_path_or_parent :: (path: string, fp: File_Pattern) -> bool {
    candidate := path;
    while true {
        if focus_pattern_matches(candidate, fp) return true;
        if !fp.should_match_whole_path return false;
        parent := filter_parent_directory(candidate);
        if parent == candidate return false;
        candidate = parent;
    }
    return false;
}

// Paths use '/' and the platform's usual case convention, as in files.jai.
evaluate_file_filter :: (input: string, is_dir := false) -> Filter_Result {
    path := input;
    #if OS == .WINDOWS { path = to_lower_copy(path,, temp); }
    for fp : config.workspace.allow {
        if focus_pattern_matches(path, fp) return .{false, true, .ALLOW, fp.source, fp.line};
    }
    if config.workspace.include {
        included := false;
        for fp : config.workspace.include {
            if focus_pattern_matches(path, fp) { included = true; break; }
        }
        if !included return .{ignored = true, reason = .OUTSIDE_INCLUDE};
    }
    for fp : config.workspace.ignore {
        if focus_pattern_matches_path_or_parent(path, fp) return .{true, false, .IGNORE, fp.source, fp.line};
    }
    if temp_dir && filter_path_within(path, temp_dir) return .{ignored = true, reason = .TEMPORARY};
    if config.settings.respect_gitignore return git_ignore_result(path, is_dir);
    return .{};
}

filter_path_within :: (path: string, dir: string) -> bool {
    if platform_path_equals(path, dir) return true;
    prefix := dir;
    if !ends_with(prefix, "/") then prefix = tprint("%/", prefix);
    return platform_path_begins_with(path, prefix);
}

// A conservative reachability check: only a fixed, incompatible prefix proves
// that a pattern cannot match a descendant. Unanchored patterns remain broad.
focus_pattern_may_match_descendant :: (dir: string, fp: File_Pattern) -> bool {
    if begins_with(fp.pattern, "./") {
        for member : config.workspace.members {
            expanded := fp;
            expanded.pattern = tprint("%/%", trim_right(member, "/"), advance(fp.pattern, 2));
            if focus_pattern_may_match_descendant(dir, expanded) return true;
        }
        return false;
    }
    if !fp.should_match_whole_path return true;
    if focus_pattern_matches(dir, fp) return true;
    prefix_end := fp.pattern.count;
    for i : 0..fp.pattern.count-1 {
        if fp.pattern[i] == #char "*" || fp.pattern[i] == #char "?" { prefix_end = i; break; }
    }
    prefix := slice(fp.pattern, 0, prefix_end);
    if prefix_end == fp.pattern.count return filter_path_within(prefix, dir);
    dir_prefix := tprint("%/", trim_right(dir, "/"));
    return platform_path_begins_with(prefix, dir_prefix) || platform_path_begins_with(dir_prefix, prefix);
}

filter_should_descend :: (input: string) -> bool {
    dir := input;
    #if OS == .WINDOWS { dir = to_lower_copy(dir,, temp); }
    for fp : config.workspace.allow {
        if focus_pattern_may_match_descendant(dir, fp) return true;
    }
    if config.workspace.include {
        reachable := false;
        for fp : config.workspace.include {
            if focus_pattern_may_match_descendant(dir, fp) { reachable = true; break; }
        }
        if !reachable return false;
    }
    for fp : config.workspace.ignore {
        if focus_pattern_matches_path_or_parent(dir, fp) return false;
    }
    if temp_dir && filter_path_within(dir, temp_dir) return false;
    if config.settings.respect_gitignore return !git_ignore_result(dir, true).ignored;
    return true;
}

Git_Token :: struct {
    kind: Kind;
    byte: u8;
    chars: string;
    Kind :: enum { LITERAL; ANY; STAR; GLOBSTAR; GLOBSTAR_SLASH; CLASS; }
}
Git_Ignore_Rule :: struct {
    pattern: string;
    tokens: [..] Git_Token;
    directory_only: bool;
    basename_only: bool;
    negate: bool;
    valid := true;
    line: s64;
}
Git_Ignore_Directory :: struct {
    path: string;
    source: string;
    parent: *Git_Ignore_Directory;
    rules: [..] Git_Ignore_Rule;
    result: Filter_Result;  // exclusion of this directory, before its own rules
}

#scope_file
filter_cache_lock: Mutex;
filter_cache_pool: Flat_Pool;
git_directories: Table(string, *Git_Ignore_Directory);
git_warning_sources: [..] string;
git_pending_warnings: [..] string;
filter_cache_initialized := false;

#scope_export
init_file_filter_cache :: () {
    if filter_cache_initialized return;
    init(*filter_cache_lock);
    filter_cache_initialized = true;
}

reset_file_filter_cache :: () {
    if !filter_cache_initialized return;
    lock(*filter_cache_lock);
    defer unlock(*filter_cache_lock);
    reset(*filter_cache_pool);
    git_directories = .{};
    empty_strings: [..] string;
    git_warning_sources = empty_strings;
    git_pending_warnings = empty_strings;
}

// Called on the UI thread, including while the initial scan is running.
flush_file_filter_warnings :: () {
    if !filter_cache_initialized return;
    lock(*filter_cache_lock);
    defer unlock(*filter_cache_lock);
    for git_pending_warnings add_user_warning("Couldn't read ignore file '%'. Other file filters are still active.", it, tag = .workspace);
    array_reset_keeping_memory(*git_pending_warnings);
}

compile_git_ignore_rule :: (input: string, line_number: s64) -> Git_Ignore_Rule, bool {
    line := input;
    if line_number == 1 && begins_with(line, "\xef\xbb\xbf") advance(*line, 3);
    rule: Git_Ignore_Rule;
    rule.line = line_number;
    // Only unescaped trailing spaces are discarded. Leading spaces are literal.
    while ends_with(line, " ") {
        escapes := 0;
        i := line.count - 2;
        while i >= 0 && line[i] == #char "\\" { escapes += 1; i -= 1; }
        if escapes % 2 != 0 break;
        line = slice(line, 0, line.count - 1);
    }
    if !line || line[0] == #char "#" return rule, false;
    if line[0] == #char "!" { rule.negate = true; advance(*line); }
    if !line return rule, false;
    anchored := begins_with(line, "/");
    if anchored advance(*line);
    rule.directory_only = ends_with(line, "/");
    if rule.directory_only line = slice(line, 0, line.count - 1);
    if !line return rule, false;
    rule.basename_only = !anchored && !contains(line, #char "/");
    #if OS == .WINDOWS { line = to_lower_copy(line); }
    rule.pattern = line;
    i := 0;
    while i < line.count {
        c := line[i];
        if c == #char "\\" {
            i += 1;
            if i == line.count { rule.valid = false; break; }
            array_add(*rule.tokens, .{kind = .LITERAL, byte = line[i]});
        } else if c == #char "?" {
            array_add(*rule.tokens, .{kind = .ANY});
        } else if c == #char "*" {
            end := i + 1;
            while end < line.count && line[end] == #char "*" end += 1;
            globstar := end - i >= 2 && (i == 0 || line[i-1] == #char "/") && (end == line.count || line[end] == #char "/");
            if globstar && end < line.count {
                array_add(*rule.tokens, .{kind = .GLOBSTAR_SLASH});
                end += 1;
            } else {
                array_add(*rule.tokens, .{kind = ifx globstar then .GLOBSTAR else .STAR});
            }
            i = end;
            continue;
        } else if c == #char "[" {
            end := i + 1;
            if end < line.count && (line[end] == #char "!" || line[end] == #char "^") end += 1;
            if end < line.count && line[end] == #char "]" end += 1;
            while end < line.count && line[end] != #char "]" {
                if line[end] == #char "\\" && end + 1 < line.count {
                    end += 2;
                } else if line[end] == #char "[" && end + 1 < line.count && line[end+1] == #char ":" {
                    end += 2;
                    while end + 1 < line.count && !(line[end] == #char ":" && line[end+1] == #char "]") end += 1;
                    end += 2;
                } else end += 1;
            }
            if end >= line.count { rule.valid = false; break; }
            array_add(*rule.tokens, .{.CLASS, 0, slice(line, i+1, end-i-1)});
            i = end;
        } else {
            array_add(*rule.tokens, .{kind = .LITERAL, byte = c});
        }
        i += 1;
    }
    return rule, true;
}

git_named_class_matches :: (name: string, c: u8) -> bool {
    alpha := (c >= #char "a" && c <= #char "z") || (c >= #char "A" && c <= #char "Z");
    digit := c >= #char "0" && c <= #char "9";
    if name == "alnum" return alpha || digit;
    if name == "alpha" return alpha;
    if name == "blank" return c == 32 || c == 9;
    if name == "cntrl" return c < 32 || c == 127;
    if name == "digit" return digit;
    if name == "graph" return c > 32 && c < 127;
    if name == "lower" return c >= #char "a" && c <= #char "z";
    if name == "print" return c >= 32 && c < 127;
    if name == "punct" return c > 32 && c < 127 && !alpha && !digit;
    if name == "space" return c == 32 || (c >= 9 && c <= 13);
    if name == "upper" {
        #if OS == .WINDOWS { return alpha; }
        return c >= #char "A" && c <= #char "Z";
    }
    if name == "xdigit" return digit || (c >= #char "a" && c <= #char "f") || (c >= #char "A" && c <= #char "F");
    return false;
}

git_class_matches :: (input: string, c: u8) -> bool {
    chars := input;
    if c == #char "/" return false;
    negate := chars && (chars[0] == #char "!" || chars[0] == #char "^");
    if negate advance(*chars);
    matched := false;
    i := 0;
    while i < chars.count {
        if chars[i] == #char "[" && i + 1 < chars.count && chars[i+1] == #char ":" {
            end := i+2;
            while end + 1 < chars.count && !(chars[end] == #char ":" && chars[end+1] == #char "]") end += 1;
            if end + 1 >= chars.count return false;
            matched = matched || git_named_class_matches(slice(chars, i+2, end-i-2), c);
            i = end+2;
            continue;
        }
        first := chars[i];
        if first == #char "\\" && i+1 < chars.count { i += 1; first = chars[i]; }
        i += 1;
        if i+1 < chars.count && chars[i] == #char "-" {
            i += 1;
            last := chars[i];
            if last == #char "\\" && i+1 < chars.count { i += 1; last = chars[i]; }
            matched = matched || (c >= first && c <= last);
            i += 1;
        } else matched = matched || c == first;
    }
    return matched != negate;
}

// Dynamic programming bounds matching to O(pattern tokens * path bytes), even
// for adversarial wildcard patterns. Two rows keep scratch space linear.
git_tokens_match :: (path: string, rule: Git_Ignore_Rule) -> bool {
    if !rule.valid return false;
    width := path.count + 1;
    next := NewArray(width, bool,, temp);
    row := NewArray(width, bool,, temp);
    next[path.count] = true;
    ti := rule.tokens.count - 1;
    while ti >= 0 {
        token := rule.tokens[ti];
        si := path.count;
        // For **/ we must consume a whole directory, not an arbitrary prefix.
        slash_suffix := false;
        while si >= 0 {
            value := false;
            if token.kind == .STAR || token.kind == .GLOBSTAR {
                value = next[si] || (si < path.count && (token.kind == .GLOBSTAR || path[si] != #char "/") && row[si+1]);
            } else if token.kind == .GLOBSTAR_SLASH {
                if si < path.count && path[si] == #char "/" && next[si+1] slash_suffix = true;
                value = next[si] || slash_suffix;
            } else if si < path.count {
                if token.kind == .LITERAL then value = token.byte == path[si] && next[si+1];
                if token.kind == .ANY     then value = path[si] != #char "/" && next[si+1];
                if token.kind == .CLASS   then value = git_class_matches(token.chars, path[si]) && next[si+1];
            }
            row[si] = value;
            si -= 1;
        }
        next, row = row, next;
        ti -= 1;
    }
    return next[0];
}

#scope_file
// All cache storage is protected by filter_cache_lock and lives until reload.
get_git_directory :: (dir: string, scope: string) -> *Git_Ignore_Directory {
    found, existing := table_find(*git_directories, dir);
    if found return existing;
    entry := New(Git_Ignore_Directory);
    entry.path = copy_string(dir);
    entry.source = sprint("%/.gitignore", trim_right(dir, "/"));
    if !platform_path_equals(dir, scope) {
        parent := filter_parent_directory(dir);
        if parent != dir {
            entry.parent = get_git_directory(parent, scope);
            entry.result = evaluate_git_chain(entry.parent, dir, true);
        }
    }
    // Git does not read .gitignore files inside an excluded parent directory.
    if !entry.result.ignored && !git_ignore_is_symlink(entry.source) {
        if file_exists(entry.source) {
            contents, ok := read_entire_file(entry.source);
            if ok {
                line_number: s64 = 0;
                for raw_line : split(contents, #char "\n") {
                    line_number += 1;
                    line := trim_right(raw_line, "\r");
                    rule, present := compile_git_ignore_rule(line, line_number);
                    if present array_add(*entry.rules, rule);
                }
            } else if !array_find(git_warning_sources, entry.source) {
                array_add(*git_warning_sources, entry.source);
                array_add(*git_pending_warnings, entry.source);
            }
        }
    }
    table_set(*git_directories, entry.path, entry);
    return entry;
}

evaluate_git_chain :: (dir: *Git_Ignore_Directory, path: string, is_dir: bool) -> Filter_Result {
    if dir.result.ignored return dir.result;
    result: Filter_Result;
    if dir.parent result = evaluate_git_chain(dir.parent, path, is_dir);
    relative := advance(path, dir.path.count);
    relative = trim_left(relative, "/");
    for rule : dir.rules {
        if rule.directory_only && !is_dir continue;
        candidate := relative;
        if rule.basename_only candidate = filter_basename(candidate);
        if git_tokens_match(candidate, rule) {
            result = .{!rule.negate, false, .GITIGNORE, dir.source, rule.line};
        }
    }
    return result;
}

filter_basename :: (path: string) -> string {
    _, __, ___, name := path_decomp(path);
    return name;
}

filter_parent_directory :: (path: string) -> string {
    parent := get_parent_dir_path(path);
    if !parent return path;
    if parent == "/" return parent;
    #if OS == .WINDOWS { if parent.count == 3 && parent[1] == #char ":" return parent; }
    return trim_right(parent, "/");
}

git_scope_for_directory :: (dir: string) -> string {
    // The nearest repository wins, including worktrees with a .git file.
    ancestor := dir;
    while true {
        if file_exists(tprint("%/.git", trim_right(ancestor, "/"))) return ancestor;
        parent := filter_parent_directory(ancestor);
        if parent == ancestor break;
        ancestor = parent;
    }
    // Overlapping roots share the outermost workspace ignore context.
    scope := dir;
    for member : config.workspace.members {
        if filter_path_within(dir, member) && member.count < scope.count scope = member;
    }
    return scope;
}

git_ignore_is_symlink :: (path: string) -> bool {
    #if OS == .WINDOWS {
        W :: #import "Windows";
        attributes := W.GetFileAttributesW(utf8_to_wide(path,, temp));
        return attributes != W.INVALID_FILE_ATTRIBUTES && (attributes & W.FILE_ATTRIBUTE_REPARSE_POINT) != 0;
    } else {
        P :: #import "POSIX";
        stat: P.stat_t;
        if P.lstat(temp_c_string(path), *stat) < 0 return false;
        return P.S_ISLNK(stat.st_mode);
    }
}

#scope_export
git_ignore_result :: (path: string, is_dir: bool) -> Filter_Result {
    if !filter_cache_initialized return .{};
    lock(*filter_cache_lock);
    defer unlock(*filter_cache_lock);
    push_allocator(.{proc = flat_pool_allocator_proc, data = *filter_cache_pool});
    dir := ifx is_dir then path else filter_parent_directory(path);
    found, entry := table_find(*git_directories, dir);
    if !found entry = get_git_directory(dir, git_scope_for_directory(dir));
    if is_dir return entry.result;
    return evaluate_git_chain(entry, path, false);
}

// Register ancestor directories, including missing .gitignore files, so that
// creation and deletion above a workspace root are observed as well as edits.
watch_ancestor_gitignore_files :: () {
    if !config.settings.respect_gitignore return;
    for member : config.workspace.members {
        dir := member;
        if !is_directory(dir) dir = filter_parent_directory(dir);
        scope := git_scope_for_directory(dir);
        while true {
            start_watching_file_if_not_already(tprint("%/.gitignore", trim_right(dir, "/")), allow_missing = true);
            // start_watching_file only records existing files, but it always
            // registers their parent directory first, which detects creation.
            if platform_path_equals(dir, scope) break;
            parent := filter_parent_directory(dir);
            if parent == dir break;
            dir = parent;
        }
    }
}

is_file_filter_control_path :: (path: string) -> bool {
    if !config.settings.respect_gitignore return false;
    name := filter_basename(path);
    if !platform_path_equals(name, ".gitignore") && !platform_path_equals(name, ".git") return false;
    for member : config.workspace.members {
        root := member;
        if !is_directory(root) root = filter_parent_directory(root);
        if filter_path_within(path, root) return true;
        parent := filter_parent_directory(path);
        if filter_path_within(root, parent) return true;
    }
    return false;
}

file_filter_directory_change :: (change: File_Change) -> bool {
    if !config.settings.respect_gitignore return false;
    relevant := false;
    for member : config.workspace.members {
        if filter_path_within(change.full_path, member) || filter_path_within(member, change.full_path) { relevant = true; break; }
    }
    if !relevant return false;
    if change.events & .SCAN_CHILDREN return filter_should_descend(change.full_path);
    if !(change.events & (.REMOVED | .MOVED)) return false;
    if is_directory(change.full_path) return filter_should_descend(change.full_path);
    if !filter_cache_initialized return false;
    key := change.full_path;
    #if OS == .WINDOWS { key = to_lower_copy(key,, temp); }
    lock(*filter_cache_lock);
    found := table_find(*git_directories, key);
    unlock(*filter_cache_lock);
    return found && filter_should_descend(change.full_path);
}
