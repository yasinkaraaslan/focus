// Apply the source graph to workspace matches after lexical lookup. It is
// built from the indexes refreshed during the candidate scan.
filter_jai_workspace_definitions :: (candidates: *[..] Jai_Definition_Location, origin_id: s64) {
    if !candidates return;

    graph := build_jai_load_graph();
    mark_jai_reachable_files(*graph, active_only = false);
    mark_jai_reachable_files(*graph, active_only = true);

    imports := collect_jai_import_names(graph, origin_id);
    origin := *open_buffers[origin_id];
    origin_path := origin.file.full_path;
    origin_module := find_jai_module_path(*graph.paths, origin_path);

    relevant_match := false;
    visible: [..] Jai_Definition_Location;
    visible.allocator = temp;
    kept := 0;
    for candidate : candidates.* {
        id := candidate.buffer_id;
        file := graph.files[id];
        if id != origin_id && file.reachable && !file.active continue;

        module := find_jai_module_path(*graph.paths, open_buffers[id].file.full_path);
        relevant_module := false;
        if module.name {
            preferred := find_local_jai_module(*graph.paths, origin_path, module.name);
            if preferred >= 0 && module.entry != preferred && module.entry != origin_module.entry continue;
            relevant_module = module.entry == origin_module.entry || table_contains(*imports, module.name);
        }

        if relevant_module then relevant_match = true;
        if !module.name || relevant_module then array_add(*visible, candidate);
        candidates.data[kept] = candidate;
        kept += 1;
    }
    candidates.count = kept;

    // Once an actual import provides a candidate, unrelated modules with the
    // same symbol name should not compete. Keep application declarations and
    // overloads from other visible imports.
    if relevant_match {
        candidates.count = 0;
        array_add(candidates, ..visible);
    }
}


#scope_file

Jai_Load_Graph :: struct {
    paths: Table(string, s64);
    files: [] File;
    edges: [..] Edge;

    File :: struct {
        outgoing, incoming: s64 = -1;
        reachable, active: bool;
    }

    Edge :: struct {
        from, to: s64;
        next_outgoing, next_incoming: s64;
        inactive: bool;
    }
}

build_jai_load_graph :: () -> Jai_Load_Graph {
    graph: Jai_Load_Graph;
    graph.paths.allocator = temp;
    graph.edges.allocator = temp;
    graph.files = NewArray(open_buffers.count, Jai_Load_Graph.File,, allocator = temp);

    for * buffer, id : open_buffers {
        if buffer.lang != .Jai || !buffer.has_file || buffer.internal || buffer.binary continue;
        if buffer.deleted && !buffer.modified continue;
        table_set(*graph.paths, jai_navigation_path_key(buffer.file.full_path), id);
    }

    for id, path : graph.paths {
        buffer := *open_buffers[id];
        parent := path_strip_filename(path);

        for link : buffer.jai_definitions.loads {
            relative_path := get_range_as_string(buffer, link.path);
            target := resolve_jai_load_path(*graph.paths, parent, relative_path);
            if target < 0 continue;

            edge := graph.edges.count;
            array_add(*graph.edges, .{id, target, graph.files[id].outgoing, graph.files[target].incoming, link.inactive});
            graph.files[id].outgoing = edge;
            graph.files[target].incoming = edge;
        }
    }
    return graph;
}

mark_jai_reachable_files :: (graph: *Jai_Load_Graph, active_only: bool) {
    pending: [..] s64;
    pending.allocator = temp;

    mark_reached :: (files: [] Jai_Load_Graph.File, id: s64, active_only: bool) -> bool {
        flag := ifx active_only then *files[id].active else *files[id].reachable;
        if flag.* return false;
        flag.* = true;
        return true;
    }

    for id, _ : graph.paths {
        if graph.files[id].incoming >= 0 continue;
        mark_reached(graph.files, id, active_only);
        array_add(*pending, id);
    }

    while pending {
        id := pop(*pending);
        i := graph.files[id].outgoing;
        while i >= 0 {
            edge := graph.edges[i];
            i = edge.next_outgoing;
            if active_only && edge.inactive continue;
            if mark_reached(graph.files, edge.to, active_only) then array_add(*pending, edge.to);
        }
    }
}

collect_jai_import_names :: (graph: Jai_Load_Graph, origin_id: s64) -> Table(string, bool) {
    names: Table(string, bool);
    names.allocator = temp;
    visited: Table(s64, bool);
    visited.allocator = temp;
    pending: [..] s64;
    pending.allocator = temp;
    array_add(*pending, origin_id);

    while pending {
        id := pop(*pending);
        if table_contains(*visited, id) continue;
        table_set(*visited, id, true);

        buffer := *open_buffers[id];
        for span : buffer.jai_definitions.imports {
            table_set(*names, get_range_as_string(buffer, span), true);
        }

        // A source file can see imports from the program that loads it.
        i := graph.files[id].incoming;
        while i >= 0 {
            edge := graph.edges[i];
            i = edge.next_incoming;
            parent := graph.files[edge.from];
            if edge.inactive || (parent.reachable && !parent.active) continue;
            array_add(*pending, edge.from);
        }
    }
    return names;
}

Jai_Module_Path :: struct {
    name: string;
    entry: s64 = -1;
}

find_jai_module_path :: (paths: *Table(string, s64), path: string) -> Jai_Module_Path {
    if !path return .{};

    // The nearest module entry owns the file, including nested sources.
    dir := path_strip_filename(path);
    if platform_path_equals(path_filename(trim_right(dir, "/")), "modules") {
        return .{path_strip_extension(path_filename(path)), lookup_jai_path(paths, path)};
    }

    while dir {
        entry := lookup_jai_path(paths, tprint("%module.jai", dir));
        if entry >= 0 {
            dir = trim_right(dir, "/");
            marker := find_index_from_right(dir, "/modules/");
            name := ifx marker >= 0 then advance(dir, marker + "/modules/".count) else path_filename(dir);
            return .{name, entry};
        }

        parent := get_parent_dir_path(trim_right(dir, "/"));
        if !parent || parent == "/" || parent == dir break;
        dir = tprint("%/", parent);
    }

    return .{};
}

find_local_jai_module :: (paths: *Table(string, s64), origin_path: string, name: string) -> s64 {
    dir := path_strip_filename(origin_path);
    while dir {
        prefix := tprint("%modules/%", dir, name);
        entry := lookup_jai_path(paths, tprint("%.jai", prefix));
        if entry >= 0 return entry;
        entry = lookup_jai_path(paths, tprint("%/module.jai", prefix));
        if entry >= 0 return entry;

        parent := get_parent_dir_path(trim_right(dir, "/"));
        if !parent || parent == "/" || parent == dir break;
        dir = tprint("%/", parent);
    }
    return -1;
}

resolve_jai_load_path :: (paths: *Table(string, s64), parent: string, path: string) -> s64 {
    absolute := ifx is_absolute_path(path) then path else tprint("%%", parent, path);
    id := lookup_jai_path(paths, absolute);
    if id >= 0 return id;

    // Normal relative loads resolve from the table without touching disk.
    // A path containing dot segments needs the same normalization as buffers.
    if !contains(path, "./") return -1;
    resolved, ok := get_absolute_path(absolute,, temp);
    if !ok return -1;
    path_overwrite_separators(resolved, #char "/");
    return lookup_jai_path(paths, resolved);
}

lookup_jai_path :: (paths: *Table(string, s64), path: string) -> s64 {
    found, id := table_find(paths, jai_navigation_path_key(path));
    return ifx found then id else -1;
}

jai_navigation_path_key :: (path: string) -> string {
    #if OS == .WINDOWS then return to_lower_copy(path,, temp);
    return path;
}
