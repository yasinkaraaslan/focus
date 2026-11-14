tokenize_jai :: (using buffer: *Buffer, start_offset := -1, count := -1) -> [] Buffer_Region {
    tokenizer := get_jai_tokenizer(buffer, start_offset, count);

    start_scope(*tokenizer, tokenizer.t - tokenizer.buf.data, .scope_export);

    while true {
        using tokenizer;

        token := start_new_token(*tokenizer);

        if t >= max_t break;

        // Assume ASCII, unless we're in the middle of a string.
        // UTF-8 characters elsewhere are a syntax error.
        char := t.*;

        if ascii_is_alpha(char) || char == #char "_" {
            parse_identifier_keyword_or_function(*tokenizer, *token, buffer);
        } else if ascii_is_digit(char) {
            t += 1;
            parse_number(*tokenizer, *token, buffer);
            highlight(*tokenizer, *token, buffer);
        } else if char == #char "#" {
            t += 1;
            parse_directive(*tokenizer, *token, buffer);
            highlight(*tokenizer, *token, buffer);
        } else if char == #char "/" {
            t += 1;
            parse_slash_or_comment(*tokenizer, *token);
            highlight(*tokenizer, *token, buffer);
            if token.type == .comment || token.type == .multiline_comment {
                // Highlight words in comments
                comment_str  := cast(string) to_view(buffer.bytes, token.start, token.len);
                output_words := find_whole_words(*config.comment_words_automaton, comment_str);
                for output_words  memset(buffer.tokens.data + token.start + it.offset, cast(u8) it.token_type, it.len);
            }
        } else {
            t += 1;
            if char == {
                case #char ";";  token.type = .punctuation; token.punctuation = .semicolon;
                case #char ",";  token.type = .punctuation; token.punctuation = .comma;
                case #char "{";  token.type = .punctuation; token.punctuation = .l_brace;
                case #char "}";  token.type = .punctuation; token.punctuation = .r_brace;
                case #char "(";  token.type = .punctuation; token.punctuation = .l_paren;
                case #char ")";  token.type = .punctuation; token.punctuation = .r_paren;
                case #char "[";  token.type = .punctuation; token.punctuation = .l_bracket;
                case #char "]";  token.type = .punctuation; token.punctuation = .r_bracket;
                case #char "$";  token.type = .punctuation; token.punctuation = .dollar;

                case #char "?";  token.type = .operation;   token.operation   = .question;
                case #char "=";  token.type = .operation;   token.operation   = .equal;
                case #char "+";  token.type = .operation;   token.operation   = .plus;
                case #char "*";  token.type = .operation;   token.operation   = .asterisk;
                case #char "<";  token.type = .operation;   token.operation   = .less_than;
                case #char ">";  token.type = .operation;   token.operation   = .greater_than;
                case #char "!";  token.type = .operation;   token.operation   = .bang;
                case #char "&";  token.type = .operation;   token.operation   = .ampersand;
                case #char "|";  token.type = .operation;   token.operation   = .pipe;
                case #char "%";  token.type = .operation;   token.operation   = .percent;
                case #char "^";  token.type = .operation;   token.operation   = .caret;
                case #char "~";  token.type = .operation;   token.operation   = .tilde;
                case #char "`";  token.type = .operation;   token.operation   = .backtick;
                case #char "-";  token.type = .operation;   token.operation   = .minus;

                case #char ".";  parse_period_or_enum_variant(*tokenizer, *token);
                case #char "\""; parse_string_literal        (*tokenizer, *token);
                case #char ":";  parse_colon                 (*tokenizer, *token);
                case #char "@";  parse_note                  (*tokenizer, *token);

                case;            token.type = .invalid;
            }

            if t >= max_t then t = max_t;  // TODO: do we need this?
            set_token_len(*tokenizer, *token);
            highlight(*tokenizer, *token, buffer);
        }
    }

    end_scope(*tokenizer, tokenizer.t - tokenizer.buf.data);

    quick_sort(tokenizer.regions, (a, b) => (a.start - b.start));

    return tokenizer.regions;
}

tokenize_jai_for_indentation :: (buffer: *Buffer) -> [] Indentation_Token /* temp */ {
    tokens: [..] Indentation_Token;
    tokens.allocator = temp;

    tokenizer := get_jai_tokenizer(buffer);

    while true {
        src := next_jai_source_token(*tokenizer);
        token: Indentation_Token;
        token.start = src.start;
        token.len = src.len;

        if src.type == {
            case .punctuation;
                if src.punctuation == {
                    case .l_paren;   token.type = .open;  token.kind = .paren;
                    case .l_bracket; token.type = .open;  token.kind = .bracket;
                    case .l_brace;   token.type = .open;  token.kind = .brace;

                    case .r_paren;   token.type = .close; token.kind = .paren;
                    case .r_bracket; token.type = .close; token.kind = .bracket;
                    case .r_brace;   token.type = .close; token.kind = .brace;

                    case;            continue;
                }

            case .directive;
                token.type = ifx src.directive == .directive_string then .maybe_multiline else .unimportant;
            case .multiline_comment; token.type = .maybe_multiline;
            case .eof;               token.type = .eof;
            case;                    token.type = .unimportant;
        }

        array_add(*tokens, token);
        if src.type == .eof break;
    }

    return tokens;
}

#scope_file

// Positions refer to source bytes. Avoid the lookahead used for presentation.
next_jai_source_token :: (using tokenizer: *Jai_Tokenizer, $for_definitions := false) -> Token {
    token := start_new_token(tokenizer);
    if t >= max_t {
        token.type = .eof;
        token.len = 0;
        return token;
    }

    char := t.*;
    t += 1;

    if ascii_is_alpha(char) || char == #char "_" {
        read_jai_identifier_string(tokenizer);
        token.type = .identifier;
        #if for_definitions {
            maybe_mark_as_keyword(*token, string.{t - start_t, start_t});
        }
    } else if ascii_is_digit(char) {
        parse_number(tokenizer, *token, null, do_highlighting = false);
    } else if char == #char "#" {
        parse_directive(tokenizer, *token, null, do_highlighting = false, for_definitions = for_definitions);
        #if for_definitions {
            if token.type == .identifier then token.type = .invalid;  // unknown directive
        }
        if token.type == .directive && token.directive == .directive_string {
            token.len = cast(s32) (t - (buf.data + token.start));
        }
        return token;
    } else if char == #char "/" {
        parse_slash_or_comment(tokenizer, *token);
    } else {
        if char == {
            case #char "{";  token.type = .punctuation; token.punctuation = .l_brace;
            case #char "}";  token.type = .punctuation; token.punctuation = .r_brace;
            case #char "(";  token.type = .punctuation; token.punctuation = .l_paren;
            case #char ")";  token.type = .punctuation; token.punctuation = .r_paren;
            case #char "[";  token.type = .punctuation; token.punctuation = .l_bracket;
            case #char "]";  token.type = .punctuation; token.punctuation = .r_bracket;
            case #char ",";  token.type = .punctuation; token.punctuation = .comma;
            case #char ";";  token.type = .punctuation; token.punctuation = .semicolon;
            case #char ".";
                #if for_definitions {
                    token.type = .punctuation;
                    token.punctuation = .period;
                    if t < max_t && t.* == #char "." {
                        token.type = .invalid;  // range operator, not a qualifier
                        t += 1;
                    }
                } else {
                    parse_period_or_enum_variant(tokenizer, *token);
                }
            case #char "$";  token.type = .punctuation; token.punctuation = .dollar;
            case #char "="; #through;
            case #char "!"; #through;
            case #char "&"; #through;
            case #char "|";
                token.type = .invalid;
                #if for_definitions {
                    second := ifx char == #char "!" then cast(u8) #char "=" else char;
                    if t < max_t && t.* == second then t += 1;
                }
            case #char "-";
                token.type = .operation;
                token.operation = .minus;
                if t < max_t && t.* == #char ">" {
                    token.operation = .arrow;
                    t += 1;
                }
            case #char "\""; parse_string_literal(tokenizer, *token);
            case #char ":";  parse_colon(tokenizer, *token);
            case #char "@";  parse_note(tokenizer, *token);
            case;            token.type = .invalid;
        }
    }

    set_token_len(tokenizer, *token);
    return token;
}

// We're using a separate tokenizer here because we have to keep track of last 2 tokens in many places
// and we can't use a global variable for that because of threading
get_jai_tokenizer :: (using buffer: *Buffer, start_offset := -1, count := -1) -> Jai_Tokenizer {
    tokenizer := get_jai_tokenizer(to_string(bytes));

    if start_offset >= 0 {
        start_offset = clamp(start_offset, 0, bytes.count - 1);
        count        = clamp(count,        0, bytes.count - 1);
        tokenizer.t += start_offset;
        tokenizer.max_t = tokenizer.t + count;
    }

    return tokenizer;
}

get_jai_tokenizer :: (source: string) -> Jai_Tokenizer {
    tokenizer: Jai_Tokenizer;
    tokenizer.buf = source;
    tokenizer.t = source.data;
    tokenizer.max_t = source.data + source.count;
    return tokenizer;
}

set_token_len :: (using tokenizer: *Jai_Tokenizer, token: *Token) #expand {
    token.len = cast(s32) (t - start_t);
}

highlight :: (tokenizer: *Jai_Tokenizer, token: *Token, buffer: *Buffer) #expand {
    tokenizer.last_token = token.*;
    memset(buffer.tokens.data + token.start, xx token.type, token.len);
}

start_new_token :: inline (using tokenizer: *Jai_Tokenizer) -> Token {
    eat_white_space(tokenizer);

    token: Token = ---;
    token.start = cast(s32) (t - buf.data);
    start_t = t;

    return token;
}

maybe_mark_as_keyword :: inline (token: *Token, identifier_str: string) -> is_keyword: bool {
    if identifier_str.count > MAX_KEYWORD_LENGTH return false;
    ok, kw_token := table_find(*KEYWORD_MAP, identifier_str);
    if ok {
        token.type = kw_token.type;
        token.keyword = kw_token.keyword;
        return true;
    }
    return false;
}

parse_identifier_or_keyword :: (using tokenizer: *Jai_Tokenizer, token: *Token, buffer: *Buffer) {
    token.type = .identifier;

    identifier_str := read_jai_identifier_string(tokenizer);
    set_token_len(tokenizer, token);

    // Maybe it's a keyword
    is_keyword := maybe_mark_as_keyword(token, identifier_str);
    if !is_keyword return;

    // Check if we can check for modifiers
    if !array_find(Keyword.[.kw_using, .kw_cast, .kw_xx, .kw_push_context], token.keyword) return;

    // Check for modifiers
    while true {
        next_token := start_new_token(tokenizer);
        if t >= max_t return;
        if t.* != #char "," break;

        t += 1;
        next_token.type = .punctuation;
        next_token.punctuation = .comma;
        set_token_len(tokenizer, *next_token);
        highlight(tokenizer, *next_token, buffer);

        next_token = start_new_token(tokenizer);

        if t >= max_t return;
        if !ascii_is_alpha(t.*) return;

        is_modifier := false;
        modifier_str := read_jai_identifier_string(tokenizer);

        if token.keyword == {
            case .kw_using;         is_modifier = array_find(string.["only", "except", "map"], modifier_str);
            case .kw_cast;          is_modifier = array_find(string.["no_check", "trunc", "force"], modifier_str);
            case .kw_xx;            is_modifier = array_find(string.["no_check", "trunc", "force"], modifier_str);
            case .kw_push_context;  is_modifier = array_find(string.["defer_pop"], modifier_str);
        }

        if is_modifier {
            next_token.type = .directive_modifier;
        } else {
            next_token.type = .identifier;
            maybe_mark_as_keyword(*next_token, modifier_str);
        }
        set_token_len(tokenizer, *next_token);
        highlight(tokenizer, *next_token, buffer);
        if !is_modifier return;
    }
}

parse_identifier_keyword_or_function :: (using tokenizer: *Jai_Tokenizer, token: *Token, buffer: *Buffer) {
    parse_identifier_or_keyword(tokenizer, token, buffer);
    defer highlight(tokenizer, token, buffer);

    if token.type != .identifier return;

    // Maybe it's a function call or a function definition
    next_token := start_new_token(tokenizer);
    if t >= max_t return;

    char := t.*;

    // Check for:
    // func (
    if char == #char "(" {
        t += 1;
        next_token.type = .punctuation;
        token.type = .function;

        set_token_len(tokenizer, *next_token);
        highlight(tokenizer, *next_token, buffer);
        return;
    }

    // Check for:
    // func :: (
    // func :: inline
    // func :: no_inline
    // func :: #bake_arguments
    // func :: #bake_constants
    if char == #char ":" {
        t += 1;
        parse_colon(tokenizer, *next_token);

        set_token_len(tokenizer, *next_token);
        highlight(tokenizer, *next_token, buffer);

        if next_token.operation != .double_colon return;  // not a function

        next_token = start_new_token(tokenizer);
        if t >= max_t return;

        char = t.*;

        if char == #char "(" {
            t += 1;
            next_token.type = .punctuation;
            token.type = .function;

            set_token_len(tokenizer, *next_token);
            highlight(tokenizer, *next_token, buffer);
        } else if char == #char "#" {
            t += 1;
            parse_directive(tokenizer, *next_token, buffer);
            highlight(tokenizer, *next_token, buffer);
            if next_token.type == .directive && (next_token.directive == .directive_bake_arguments || next_token.directive == .directive_bake_constants) {
                token.type = .function;
            }
        } else if ascii_is_alpha(char) {
            parse_identifier_or_keyword(tokenizer, *next_token, buffer);
            highlight(tokenizer, *next_token, buffer);
            if next_token.type == .keyword && (next_token.keyword == .kw_inline || next_token.keyword == .kw_no_inline) {
                token.type = .function;
            }
        }
    }
}

parse_number :: (using tokenizer: *Jai_Tokenizer, token: *Token, buffer: *Buffer, $do_highlighting := true) {
    token.type = .number;

    if t >= max_t {
        set_token_len(tokenizer, token);
        return;
    }

    is_decimal_variant :: inline (c: u8) -> bool {
        return ascii_is_digit(c) || c == #char "." || c == #char "-" || c == #char "e" || c == #char "E";
    }

    if is_decimal_variant(t.*) || t.* == #char "_" {
        // Decimal
        seen_decimal_point  := false;
        scientific_notation := false;
        while t < max_t && (is_decimal_variant(t.*) || t.* == #char "_") {
            if t.* == #char "." {
                // Handle 0..1 (gets interpreted as a float-period-int rather than int-rangeop-int)
                if (t + 1) < max_t && (t + 1).* == #char "."  break;

                // else handle float decimal
                if seen_decimal_point  break;
                seen_decimal_point = true;
            }
            else if t.* == #char "e" || t.* == #char "E" {
                // Scientific notation (3.5e2, 1.0e-34)
                // Only works if there is a decimal point
                if scientific_notation || !seen_decimal_point  break;
                scientific_notation = true;
            }
            else if t.* == #char "-" {
                // Handle negative exponent in scientific notation (1.0e-34)
                if !scientific_notation  break;
                if (t - 1).* != #char "e" && (t - 1).* != #char "E"  break;
            }

            t += 1;
        }
    } else if t.* == #char "x" || t.* == #char "h" {
        // Hex
        t += 1;
        while t < max_t && (is_hex(t.*) || t.* == #char "_") t += 1;
    } else if t.* == #char "b" {
        // Binary
        t += 1;
        while t < max_t && (t.* == #char "1" || t.* == #char "0" || t.* == #char "_") t += 1;

        // Handle the case where a binary number is immediately followed by a decimal number:
        // e.g. 0b100101879 - we don't want to highlight everything as one number
        #if do_highlighting {
            if t < max_t && ascii_is_digit(t.*) {
                set_token_len(tokenizer, token);
                next_token := start_new_token(tokenizer);
                next_token.type = .invalid;
                while t < max_t && (ascii_is_digit(t.*) || t.* == #char "_")  t += 1;
                set_token_len(tokenizer, *next_token);
                highlight(tokenizer, *next_token, buffer);
                return;
            }
        }
    }

    set_token_len(tokenizer, token);
}

parse_directive :: (using tokenizer: *Jai_Tokenizer, token: *Token, buffer: *Buffer, $do_highlighting := true, $for_definitions := false) {
    token.type = .identifier;

    {
        defer set_token_len(tokenizer, token);

        eat_white_space(tokenizer, only_until_newline = true);  // there may be spaces between the # and the name
        if t >= max_t return;
        if !ascii_is_alpha(t.*) return;

        start_offset := cast(s32) (start_t - buf.data);

        directive_str := read_jai_identifier_string(tokenizer);

        // Check if it's one of the existing directives
        if directive_str.count > MAX_DIRECTIVE_LENGTH return;
        ok, directive := table_find(*DIRECTIVES_MAP, directive_str);
        if !ok return;

        token.type = .directive;
        token.directive = directive;

        #if !for_definitions {
            if directive == {
                case .directive_scope_export;     start_scope(tokenizer, start_offset, .scope_export);
                case .directive_scope_module;     start_scope(tokenizer, start_offset, .scope_module);
                case .directive_scope_file;       start_scope(tokenizer, start_offset, .scope_file);
            }
        }
    }

    #if for_definitions {
        if token.directive != .directive_string return;
    }

    // Check for modifiers
    while true {
        next_token := start_new_token(tokenizer);
        if t >= max_t return;
        if t.* != #char "," break;

        t += 1;
        next_token.type = .punctuation;
        next_token.punctuation = .comma;
        set_token_len(tokenizer, *next_token);
        #if do_highlighting then highlight(tokenizer, *next_token, buffer);

        next_token = start_new_token(tokenizer);

        is_modifier := false;
        modifier_str: string;

        if t >= max_t return;
        if ascii_is_alpha(t.*) {
            modifier_str = read_jai_identifier_string(tokenizer);
        } else if t.* == #char "\\" && (t + 1) < max_t && (t + 1).* == #char "%" {
            modifier_str = "\\%";
            t += modifier_str.count;
        }
        if !modifier_str return;

        if token.directive == {
            case .directive_type;           is_modifier = array_find(string.["isa", "distinct"], modifier_str);
            case .directive_import;         is_modifier = array_find(string.["file", "dir", "string"], modifier_str);
            case .directive_insert;         is_modifier = array_find(string.["scope"], modifier_str);
            case .directive_run;            is_modifier = array_find(string.["stallable"], modifier_str);
            case .directive_library;        is_modifier = array_find(string.["no_static_library", "no_dll", "system", "link_always"], modifier_str);
            case .directive_system_library; is_modifier = array_find(string.["no_static_library", "no_dll", "link_always"], modifier_str);
            case .directive_string;         is_modifier = array_find(string.["cr", "\\%"], modifier_str);
        }

        if is_modifier {
            next_token.type = .directive_modifier;
        } else {
            next_token.type = .identifier;
            maybe_mark_as_keyword(*next_token, modifier_str);
        }
        set_token_len(tokenizer, *next_token);
        #if do_highlighting then highlight(tokenizer, *next_token, buffer);
        if !is_modifier return;
    }

    // Maybe it's a here-string
    if token.directive == .directive_string {
        next_token := start_new_token(tokenizer);
        if t >= max_t return;
        if !ascii_is_alpha(t.*) && t.* != #char "_" return;

        next_token.type = .multiline_string;
        identifier_str := read_jai_identifier_string(tokenizer);

        set_token_len(tokenizer, *next_token);
        #if do_highlighting then highlight(tokenizer, *next_token, buffer);

        start := cast(s32) (t - buf.data);
        end   := find_jai_here_string_end(tokenizer, identifier_str);
        if end < 0 {
            end = xx (max_t - buf.data);
            t = max_t;
        } else {
            t = buf.data + end + identifier_str.count;
            #if do_highlighting then memset(buffer.tokens.data + end, xx Token_Type.multiline_string, identifier_str.count);  // highlight the end identifier
        }

        #if do_highlighting {
            if start < end {
                // Maybe add a heredoc region for deferred highlighting
                potential_lang_name := identifier_str;
                {
                    // Extract lang from heredoc names like BLAH_BLAH_lang
                    found, _, lang := split_from_right(identifier_str, cast(u8) #char "_");
                    if found then potential_lang_name = lang;
                }
                lang := get_lang_from_name(potential_lang_name);
                if lang != .Plain_Text {
                    array_add(*regions, Buffer_Region.{ start = start + 1, end = xx end, kind = .heredoc, lang = lang });  // start + 1 to not include the newline
                } else {
                    memset(buffer.tokens.data + start, xx Token_Type.multiline_string, end - start);  // highlight everything as string
                }
            }
        }
    }
}

find_jai_here_string_end :: (using tokenizer: Jai_Tokenizer, delimiter: string) -> s32 {
    cursor := t;
    while cursor < max_t {
        // The terminator is the first identifier on a line. Jai allows
        // indentation and punctuation after the delimiter.
        while cursor < max_t && cursor.* != #char "\n" cursor += 1;
        if cursor == max_t break;
        cursor += 1;
        while cursor < max_t && (cursor.* == #char " " || cursor.* == #char "\t") cursor += 1;

        remaining := max_t - cursor;
        if remaining < delimiter.count continue;
        if memcmp(cursor, delimiter.data, delimiter.count) != 0 continue;
        if remaining == delimiter.count || !ascii_is_alnum(cursor[delimiter.count]) {
            return xx (cursor - buf.data);
        }
    }
    return -1;
}

parse_colon :: (using tokenizer: *Jai_Tokenizer, token: *Token) {
    token.type      = .operation;
    token.operation = .colon;

    if t >= max_t return;

    if t.* == #char ":" {
        token.operation = .double_colon;
        t += 1;
    }
}

parse_period_or_enum_variant :: (using tokenizer: *Jai_Tokenizer, token: *Token) {
    token.type        = .punctuation;
    token.punctuation = .period;

    if t >= max_t return;

    // Maybe it's an enum variant
    is_enum_variant := !(  last_token.type == .identifier
                        || last_token.type == .string_literal
                        || last_token.type == .multiline_string
                        || (   last_token.type == .punctuation
                            && (   last_token.punctuation == .period                  // ..whatever
                                || last_token.punctuation == .r_bracket               // [asdf].whatever
                                || last_token.punctuation == .r_paren))               // (asdf).whatever
                        || (   last_token.type == .value
                            && (   last_token.keyword == .kw_context                  // context.whatever
                                || last_token.keyword == .kw_it                       // it.whatever
                                || last_token.keyword == .kw_it_index))               // it_index.whatever
                        || (   last_token.type == .directive
                            && (   last_token.directive == .directive_caller_location // #caller_location.whatever
                                || last_token.directive == .directive_Context         // #Context.whatever
                                || last_token.directive == .directive_file            // #file.whatever
                                || last_token.directive == .directive_filepath        // #filepath.whatever
                                || last_token.directive == .directive_this)));        // #this.whatever

    if is_enum_variant {
        eat_white_space(tokenizer, only_until_newline = true);
        if t < max_t && (ascii_is_alpha(t.*) || t.* == #char "_") {
            read_jai_identifier_string(tokenizer);
            token.type = .enum_variant;
        }
    }
}

parse_note :: (using tokenizer: *Jai_Tokenizer, token: *Token) {
    token.type = .note;

    while t < max_t && ascii_is_alnum(t.*) t += 1;
}

parse_slash_or_comment :: (using tokenizer: *Jai_Tokenizer, token: *Token) {
    token.type = .operation;
    token.operation = .slash;

    defer set_token_len(tokenizer, token);

    if t >= max_t return;

    if t.* == {
        case #char "/";
            token.type = .comment;
            t += 1;
            while t < max_t && t.* != #char "\n" t += 1;
        case #char "*";
            token.type = .multiline_comment;
            t += 1;
            num_open_comments := 0;
            while t < max_t {
                if t.* == #char "*" && (t + 1) < max_t && (t + 1).* == #char "/" {
                    if num_open_comments == 0 {
                        t += 2;
                        break;
                    } else {
                        num_open_comments -= 1;
                        t += 1;
                    }
                } else if t.* == #char "/" && (t + 1) < max_t && (t + 1).* == #char "*" {
                    num_open_comments += 1;
                    t += 1;
                }
                t += 1;
            }
    }
}

parse_string_literal :: (using tokenizer: *Jai_Tokenizer, token: *Token) {
    token.type = .string_literal;

    escape_seen := false;

    while t < max_t && t.* != #char "\n" {
        if t.* == #char "\"" && !escape_seen break;
        escape_seen = !escape_seen && t.* == #char "\\";
        t += 1;
    }
    if t >= max_t return;

    t += 1;
}

read_jai_identifier_string :: (using tokenizer: *Jai_Tokenizer) -> string /* from scratch buffer */ {
    // Most identifiers don't have slashes in them, so assume no slashes first,
    // and fall back to a slower version if we encounter a slash
    ident: string = ---;
    ident.data = t;
    ident_max_t := min(max_t, t + MAX_IDENTIFIER_LENGTH);

    // @Speed: this is a good candidate for some SIMD - refer to the Jai_Lexer implementation for an example using intrinsics
    while t < ident_max_t && ascii_is_alnum(t.*)  t += 1;

    ident.count = t - ident.data;

    if t >= ident_max_t || t.* != #char "\\" return ident;  // we haven't seen a slash - early return

    // We have a slash - continue parsing using the slower option
    memcpy(scratch_buffer.data, ident.data, ident.count);
    scratch_pos := scratch_buffer.data + ident.count;

    // Skip initial whitespace after the slash
    t += 1;
    while t < ident_max_t && t.* == #char " "  t += 1;

    // Continue parsing
    while t < ident_max_t {
        c := t.*;
        if ascii_is_alnum(c) {
            scratch_pos.* = c;
            scratch_pos += 1;
            t += 1;
        } else if c == #char "\\" {
            t += 1;
            while t < ident_max_t && t.* == #char " "  t += 1;
        } else {
            break;
        }
    }

    return string.{ scratch_pos - scratch_buffer.data, scratch_buffer.data };
}

start_scope :: (using tokenizer: *Jai_Tokenizer, offset: s64, kind: Buffer_Region.Kind) {
    if current_scope_id >= 0 then end_scope(tokenizer, offset);
    current_scope_id = regions.count;

    region := Buffer_Region.{
        start = xx offset,
        end   = -1,
        kind  = kind,
    };
    array_add(*regions, region);
}

end_scope :: inline (using tokenizer: *Jai_Tokenizer, offset: s64) {
    regions[current_scope_id].end = xx offset;
}

Jai_Tokenizer :: struct {
    using #as base: Tokenizer;

    regions: [..] Buffer_Region;
    regions.allocator = temp;
    current_scope_id := -1;

    last_token: Token;

    scratch_buffer: [MAX_IDENTIFIER_LENGTH] u8;
}

Token_Subtype :: union {
    keyword:        Keyword;
    punctuation:    Punctuation;
    operation:      Operation;
    directive:      Directive;
}

Token :: struct {
    using #as base: Base_Token;

    // Additional info to distinguish between keywords/punctuation
    using subtype: Token_Subtype;
}

PUNCTUATION :: string.[
    "dollar", "semicolon", "l_paren", "r_paren", "l_brace", "r_brace", "l_bracket", "r_bracket", "period", "comma",
];

OPERATIONS :: string.[
    "arrow", "bang", "backtick", "pipe", "equal", "percent", "less_than", "greater_than", "question",
    "minus", "asterisk", "colon", "double_colon", "slash", "plus", "ampersand", "tilde", "caret",
];

KEYWORDS :: string.[
    "break", "case", "cast", "code_of", "continue", "defer", "else", "enum", "enum_flags", "for", "initializer_of",
    "if", "ifx", "is_constant", "inline", "push_context", "return", "size_of", "struct", "then", "type_info", "type_of",
    "union", "using", "while", "xx", "operator", "remove", "interface", "no_inline",
];

TYPE_KEYWORDS :: string.[
    "__reg", "bool", "float", "float32", "float64", "int", "reg", "s16", "s32", "s64", "s8", "string",
    "u16", "u32", "u64", "u8", "void", "v128", "Any", "Code", "Type",
];

VALUE_KEYWORDS :: string.[
    "context", "it", "it_index", "null", "true", "false", "temp",
];

DIRECTIVES :: string.[
    "add_context", "align", "as", "asm", "assert", "bake_arguments", "bake_constants", "bytes", "c_call", "caller_code",
    "caller_location", "char", "code", "compiler", "complete", "cpp_method", "cpp_return_type_is_non_pod", "deprecated",
    "dump", "dynamic_specialize", "elsewhere", "expand", "file", "filepath", "foreign", "library", "system_library",
    "if", "ifx", "import", "insert", "insert_internal", "intrinsic", "line", "load",
    "location", "modify", "module_parameters", "must", "no_abc", "no_aoc", "no_alias", "no_context", "no_padding", "no_reset",
    "overlay", "place", "placeholder", "poke_name", "procedure_of_call", "program_export", "run", "runtime_support",
    "scope_export", "scope_file", "scope_module", "specified", "string", "symmetric", "this", "through", "type",
    "type_info_no_size_complaint", "type_info_none", "type_info_procedures_are_void_pointers",
    "compile_time", "no_debug", "procedure_name", "discard", "entry_point", "Context", "exists",
    // temporary:
    "v2",
];

#insert -> string {
    b: String_Builder;
    init_string_builder(*b);

    define_enum :: (b: *String_Builder, enum_name: string, prefix: string, value_lists: [][] string) {
        print_to_builder(b, "% :: enum u8 {\n", enum_name);
        for values : value_lists {
            for v : values print_to_builder(b, "    %0%;\n", prefix, v);
        }
        print_to_builder(b, "}\n");
    }

    define_enum(*b, "Punctuation",  "",           .[PUNCTUATION]);
    define_enum(*b, "Operation",    "",           .[OPERATIONS]);
    define_enum(*b, "Keyword",      "kw_",        .[KEYWORDS, TYPE_KEYWORDS, VALUE_KEYWORDS]);
    define_enum(*b, "Directive",    "directive_", .[DIRECTIVES]);

    return builder_to_string(*b);
}

Keyword_Token :: struct {
    type: Token_Type;
    keyword: Keyword;
}

KEYWORD_MAP :: #run -> Table(string, Keyword_Token) {
    table: Table(string, Keyword_Token);
    size := 5 * (KEYWORDS.count + TYPE_KEYWORDS.count + VALUE_KEYWORDS.count);
    table_resize(*table, size);

    #insert -> string {
        b: String_Builder;
        for KEYWORDS        append(*b, sprint("table_add(*table, \"%1\", Keyword_Token.{ type = .keyword, keyword = .kw_%1 });\n", it));
        for TYPE_KEYWORDS   append(*b, sprint("table_add(*table, \"%1\", Keyword_Token.{ type = .type,    keyword = .kw_%1 });\n", it));
        for VALUE_KEYWORDS  append(*b, sprint("table_add(*table, \"%1\", Keyword_Token.{ type = .value,   keyword = .kw_%1 });\n", it));
        return builder_to_string(*b);
    }

    return table;
}

DIRECTIVES_MAP :: #run -> Table(string, Directive) {
    table: Table(string, Directive);
    size := 5 * DIRECTIVES.count;
    table_resize(*table, size);

    #insert -> string {
        b: String_Builder;
        init_string_builder(*b);
        for DIRECTIVES {
            print_to_builder(*b, "table_add(*table, \"%1\", .directive_%1);\n", it);
        }
        return builder_to_string(*b);
    }

    return table;
}

MAX_KEYWORD_LENGTH :: #run -> s32 {
    result: s64;
    for KEYWORDS       { if it.count > result then result = it.count; }
    for TYPE_KEYWORDS  { if it.count > result then result = it.count; }
    for VALUE_KEYWORDS { if it.count > result then result = it.count; }
    return xx result;
}

MAX_DIRECTIVE_LENGTH :: #run -> s32 {
    result: s64;
    for DIRECTIVES { if it.count > result then result = it.count; }
    return xx result;
}

MAX_IDENTIFIER_LENGTH :: 512;


#scope_export

Jai_Definition_Index :: struct {
    revision: u64;
    ready: bool;
    symbols: [..] Jai_Declaration;
    scopes: [..] Jai_Lexical_Scope;
    loads: [..] Jai_Source_Link;
    imports: [..] Offset_Range;
}

Jai_Source_Link :: struct {
    path: Offset_Range;
    inactive: bool;
}

Jai_Declaration :: struct {
    name: Offset_Range;
    scope: s32;  // zero means file level
    file_private: bool;
}

Jai_Lexical_Scope :: struct {
    start, end: s32;
    depth: s32;
}

refresh_jai_definition_index :: (buffer: *Buffer) {
    lock(*buffer.content_lock);
    defer unlock(*buffer.content_lock);

    index := *buffer.jai_definitions;
    if index.ready && index.revision == buffer.content_revision return;

    array_reset_keeping_memory(*index.symbols);
    array_reset_keeping_memory(*index.scopes);
    array_reset_keeping_memory(*index.loads);
    array_reset_keeping_memory(*index.imports);

    scan_jai_declarations(to_string(buffer.bytes), index);
    index.revision = buffer.content_revision;
    index.ready = true;
}

jai_identifier_at :: (source: string, offset: s32, include_right_edge := true) -> name: Offset_Range, qualified: bool {
    tokenizer := get_jai_tokenizer(source);
    previous: Token;
    right_edge: Offset_Range;
    right_edge_qualified := false;

    while true {
        token := next_jai_source_token(*tokenizer, for_definitions = true);
        if token.start > offset || token.type == .eof break;
        if token.type == .comment || token.type == .multiline_comment {
            if offset < token.start + token.len return .{}, false;
            continue;
        }

        if token.type == .identifier {
            span := Offset_Range.{token.start, token.start + token.len};
            after_dot := previous.type == .punctuation && previous.punctuation == .period;
            if offset < span.end return span, after_dot;
            if include_right_edge && offset == span.end {
                right_edge = span;
                right_edge_qualified = after_dot;
            }
        }
        previous = token;
    }

    return right_edge, right_edge_qualified;
}

jai_names_equal :: (a: string, b: string) -> bool {
    if a == b return true;
    if find_index_from_left(a, #char "\\") < 0 && find_index_from_left(b, #char "\\") < 0 return false;

    // Jai lets an identifier contain backslashes and spaces after them.
    i, j := 0;
    while i < a.count || j < b.count {
        while i < a.count && (a[i] == #char "\\" || a[i] == #char " ") i += 1;
        while j < b.count && (b[j] == #char "\\" || b[j] == #char " ") j += 1;
        if i == a.count || j == b.count return i == a.count && j == b.count;
        if a[i] != b[j] return false;
        i += 1;
        j += 1;
    }
    return true;
}


#scope_file

Jai_Index_Token :: struct {
    using token: Token;
    close: s32 = -1;
    procedure_scope: s32;
    ignore_body: bool;
    conditional_body: bool;
    inactive_delta: s32;
}

scan_jai_declarations :: (source: string, index: *Jai_Definition_Index) {
    tokens: [..] Jai_Index_Token;
    defer array_free(tokens);
    openings: [..] s32;
    defer array_free(openings);

    tokenizer := get_jai_tokenizer(source);
    while true {
        token := next_jai_source_token(*tokenizer, for_definitions = true);
        if token.type == .eof break;
        if token.type == .comment || token.type == .multiline_comment continue;

        i := cast(s32) tokens.count;
        array_add(*tokens, .{token = token});
        if token.type != .punctuation continue;

        if token.punctuation == {
            case .l_brace;   #through;
            case .l_paren;   #through;
            case .l_bracket; array_add(*openings, i);
            case .r_brace;   #through;
            case .r_paren;   #through;
            case .r_bracket;
                if !openings continue;
                if token.punctuation == .r_brace {
                    // An unfinished call or subscript must not swallow the
                    // enclosing block and all declarations that follow it.
                    while openings && tokens[openings[openings.count - 1]].punctuation != .l_brace {
                        tokens[pop(*openings)].close = i;
                    }
                    if !openings continue;
                }

                opening := openings[openings.count - 1];
                if jai_delimiters_match(tokens[opening].punctuation, token.punctuation) {
                    tokens[opening].close = i;
                    openings.count -= 1;
                }
        }
    }

    mark_jai_platform_branches(source, tokens);

    array_add(*index.scopes, .{end = xx source.count});
    frames: [..] Jai_Index_Frame;
    defer array_free(frames);
    array_add(*frames, .{end_token = tokens.count});

    file_private := false;
    inactive_depth := 0;
    for * token, i : tokens {
        inactive_depth += token.inactive_delta;
        if token.type == .directive && token.directive == .directive_load {
            path := jai_literal_path(source, tokens, i + 1);
            if path.start != path.end then array_add(*index.loads, .{path, inactive_depth > 0});
        }
        if inactive_depth > 0 continue;

        while frames.count > 1 && i >= frames[frames.count - 1].end_token {
            frames.count -= 1;
        }
        frame := frames[frames.count - 1];

        if token.type == .directive && frame.declarations {
            if token.directive == {
                case .directive_scope_file;   if frame.scope == 0 then file_private = true;
                case .directive_scope_module; #through;
                case .directive_scope_export; if frame.scope == 0 then file_private = false;
                case .directive_import;
                    if frame.scope == 0 {
                        bound := i > 0 && tokens[i - 1].type == .operation && tokens[i - 1].operation == .double_colon;
                        using_import := bound && i >= 3 && tokens[i - 3].type == .keyword && tokens[i - 3].keyword == .kw_using;
                        if !bound || using_import {
                            path := jai_literal_path(source, tokens, i + 1);
                            if path.start != path.end then array_add(*index.imports, path);
                        }
                    }
            }
        }

        if jai_punctuation(token, .l_brace) || jai_punctuation(token, .l_paren) || jai_punctuation(token, .l_bracket) {
            frame.end_token = ifx token.close < 0 then tokens.count else token.close;
            if token.procedure_scope {
                frame.scope = token.procedure_scope;
                frame.declarations = true;
            } else if token.conditional_body {
                // A Jai #if inserts into the surrounding scope.
            } else if jai_punctuation(token, .l_brace) && frame.declarations && !token.ignore_body &&
                      (i == 0 || !jai_punctuation(tokens[i - 1], .period)) {
                if frame.scope {
                    frame.scope = add_jai_scope(index, frame.scope, token.start + token.len, jai_scope_end(tokens, token, source.count));
                } else {
                    frame.declarations = false;
                }
            } else {
                frame.declarations = false;
            }

            array_add(*frames, frame);
            continue;
        }

        if !frame.declarations || !jai_declaration_colon(tokens, i) continue;

        add_jai_binding_names(index, tokens, i, frame.scope, file_private && frame.scope == 0);
        if token.operation != .double_colon || i + 1 >= tokens.count continue;

        rhs := i + 1;
        head := tokens[rhs];
        if head.type == .keyword && (head.keyword == .kw_struct || head.keyword == .kw_union ||
                                    head.keyword == .kw_enum || head.keyword == .kw_enum_flags ||
                                    head.keyword == .kw_interface) {
            body := find_jai_body(tokens, rhs + 1);
            if body >= 0 then tokens[body].ignore_body = true;
            continue;
        }

        if head.type == .keyword && (head.keyword == .kw_inline || head.keyword == .kw_no_inline) then rhs += 1;
        if rhs >= tokens.count || !jai_punctuation(tokens[rhs], .l_paren) || tokens[rhs].close < 0 continue;

        arguments_end := tokens[rhs].close;
        body := find_jai_body(tokens, arguments_end + 1, procedure = true);
        if body < 0 continue;

        scope := add_jai_scope(index, frame.scope, tokens[rhs].start, jai_scope_end(tokens, tokens[body], source.count));
        tokens[body].procedure_scope = scope;

        argument := rhs + 1;
        argument_names_start := argument;
        while argument < arguments_end {
            if jai_declaration_colon(tokens, argument) {
                add_jai_binding_names(index, tokens, argument, scope, false, lower_bound = argument_names_start);
                // The next declaration can't include names from this type or its default.
                while argument < arguments_end && !jai_punctuation(tokens[argument], .comma) {
                    close := tokens[argument].close;
                    argument = ifx close >= 0 then close + 1 else argument + 1;
                }
                argument_names_start = argument + 1;
            }
            if argument >= arguments_end break;
            close := tokens[argument].close;
            argument = ifx close >= 0 then close + 1 else argument + 1;
        }
    }
}

Jai_Index_Frame :: struct {
    end_token: s64;
    scope: s32;
    declarations := true;
}

jai_punctuation :: inline (token: Jai_Index_Token, kind: Punctuation) -> bool {
    return token.type == .punctuation && token.punctuation == kind;
}

jai_delimiters_match :: inline (left: Punctuation, right: Punctuation) -> bool {
    return (left == .l_brace && right == .r_brace) ||
           (left == .l_paren && right == .r_paren) ||
           (left == .l_bracket && right == .r_bracket);
}

jai_declaration_colon :: (tokens: [] Jai_Index_Token, i: s64) -> bool {
    token := tokens[i];
    if token.type != .operation || (token.operation != .colon && token.operation != .double_colon) return false;
    if i < 1 || tokens[i - 1].type != .identifier return false;

    if i >= 2 {
        prefix := tokens[i - 2];
        if jai_punctuation(prefix, .period) return false;
        if prefix.type == .keyword && (prefix.keyword == .kw_case || prefix.keyword == .kw_for) return false;
    }
    return true;
}

add_jai_binding_names :: (index: *Jai_Definition_Index, tokens: [] Jai_Index_Token, colon: s64, scope: s32,
                          file_private: bool, lower_bound: s64 = 0) {
    i := colon - 1;
    while i >= lower_bound && tokens[i].type == .identifier {
        token := tokens[i];
        array_add(*index.symbols, .{
            name = .{token.start, token.start + token.len},
            scope = scope,
            file_private = file_private,
        });
        if i < lower_bound + 2 || !jai_punctuation(tokens[i - 1], .comma) break;

        // A dollar introduces a polymorphic parameter and is outside its name.
        i -= 2;
        if jai_punctuation(tokens[i], .dollar) break;
    }
}

find_jai_body :: (tokens: [] Jai_Index_Token, start: s64, procedure := false) -> s64 {
    if start >= tokens.count return -1;
    if procedure {
        token := tokens[start];
        // A parenthesized initializer can also follow '::'. A procedure
        // continues with a body, an arrow, a note, or a procedure directive.
        if !jai_punctuation(token, .l_brace) && token.type != .note && token.type != .directive &&
           !(token.type == .operation && token.operation == .arrow) return -1;
    }

    i := start;
    while i < tokens.count {
        token := tokens[i];
        if jai_punctuation(token, .l_brace) return i;
        if jai_punctuation(token, .r_brace) || jai_punctuation(token, .semicolon) ||
           (token.type == .directive && token.directive == .directive_foreign) ||
           jai_declaration_colon(tokens, i) return -1;

        i = ifx token.close >= 0 then token.close + 1 else i + 1;
    }
    return -1;
}

jai_scope_end :: inline (tokens: [] Jai_Index_Token, opening: Jai_Index_Token, source_count: s64) -> s32 {
    return ifx opening.close >= 0 then tokens[opening.close].start else cast(s32) source_count;
}

add_jai_scope :: (index: *Jai_Definition_Index, parent: s32, start: s32, end: s32) -> s32 {
    id := cast(s32) index.scopes.count;
    array_add(*index.scopes, .{start = start, end = end, depth = index.scopes[parent].depth + 1});
    return id;
}

jai_token_text :: inline (source: string, token: Jai_Index_Token) -> string {
    return slice(source, token.start, token.len);
}

jai_literal_path :: (source: string, tokens: [] Jai_Index_Token, i: s64) -> Offset_Range {
    if i >= tokens.count || tokens[i].type != .string_literal return .{};

    text := jai_token_text(source, tokens[i]);
    if text.count < 3 || !ends_with(text, "\"") || contains(text, #char "\\") return .{};
    return .{tokens[i].start + 1, tokens[i].start + tokens[i].len - 1};
}

Jai_Condition :: enum { unknown; no; yes; }

mark_jai_platform_branches :: (source: string, tokens: [] Jai_Index_Token) {
    for token, i : tokens {
        if !jai_if_directive(token) continue;
        if i > 0 && jai_else_keyword(tokens[i - 1]) continue;  // handled by the chain's first #if

        next := i;
        can_reach_branch := true;
        while next < tokens.count && jai_if_directive(tokens[next]) {
            header := next + 1;
            if header < tokens.count && jai_token_text(source, tokens[header]) == "#complete" then header += 1;

            body := find_jai_platform_body(tokens, header);
            if body < 0 break;
            condition := evaluate_jai_platform_condition(source, tokens, header, body);

            end := jai_platform_body_end(source, tokens, body);
            if end < 0 break;
            if jai_punctuation(tokens[body], .l_brace) {
                tokens[body].conditional_body = true;
                // In a compile-time switch, each case controls its own loads.
                if body == header + 2 && jai_token_text(source, tokens[header]) == "OS" &&
                   jai_token_text(source, tokens[header + 1]) == "==" {
                    mark_jai_platform_cases(source, tokens, body, end - 1);
                }
            }
            if !can_reach_branch || condition == .no then mark_inactive_jai_range(tokens, body, end);
            if condition == .yes then can_reach_branch = false;

            if end + 1 >= tokens.count || !jai_else_keyword(tokens[end]) break;
            next = end + 1;
            if jai_if_directive(tokens[next]) continue;

            end = jai_platform_body_end(source, tokens, next);
            if end < 0 break;
            if jai_punctuation(tokens[next], .l_brace) then tokens[next].conditional_body = true;
            if !can_reach_branch then mark_inactive_jai_range(tokens, next, end);
            break;
        }
    }
}

// Return the first token after a block or a literal #load/#import statement.
jai_platform_body_end :: (source: string, tokens: [] Jai_Index_Token, body: s64) -> s64 {
    token := tokens[body];
    if jai_punctuation(token, .l_brace) return ifx token.close >= 0 then token.close + 1 else -1;
    if token.type != .directive || (token.directive != .directive_load && token.directive != .directive_import) return -1;
    if jai_literal_path(source, tokens, body + 1).end == 0 return -1;

    end := body + 2;
    if end < tokens.count && jai_punctuation(tokens[end], .semicolon) then end += 1;
    return end;
}

find_jai_platform_body :: (tokens: [] Jai_Index_Token, start: s64) -> s64 {
    i := start;
    while i < tokens.count {
        token := tokens[i];
        if jai_punctuation(token, .l_brace) ||
           (token.type == .directive && (token.directive == .directive_load || token.directive == .directive_import)) return i;
        if jai_punctuation(token, .semicolon) || jai_punctuation(token, .r_brace) ||
           jai_if_directive(token) || jai_declaration_colon(tokens, i) return -1;
        i = ifx token.close >= 0 then token.close + 1 else i + 1;
    }
    return -1;
}

jai_if_directive :: inline (token: Jai_Index_Token) -> bool {
    return token.type == .directive && token.directive == .directive_if;
}

jai_else_keyword :: inline (token: Jai_Index_Token) -> bool {
    return token.type == .keyword && token.keyword == .kw_else;
}

mark_inactive_jai_range :: (tokens: [] Jai_Index_Token, first: s64, end: s64) {
    if first >= end return;
    tokens[first].inactive_delta += 1;
    if end < tokens.count then tokens[end].inactive_delta -= 1;
}

evaluate_jai_platform_condition :: (source: string, tokens: [] Jai_Index_Token, first: s64, end: s64, depth := 0) -> Jai_Condition {
    if first >= end || depth >= 64 return .unknown;
    if jai_punctuation(tokens[first], .l_paren) && tokens[first].close == end - 1 {
        return evaluate_jai_platform_condition(source, tokens, first + 1, end - 1, depth + 1);
    }

    // Split at the lowest precedence operator outside parentheses.
    last_or, last_and: s64 = -1;
    i := first;
    while i < end {
        if tokens[i].close >= i && tokens[i].close < end {
            i = tokens[i].close + 1;
            continue;
        }
        text := jai_token_text(source, tokens[i]);
        if text == "||" then last_or = i;
        if text == "&&" then last_and = i;
        i += 1;
    }

    if last_or >= 0 {
        left := evaluate_jai_platform_condition(source, tokens, first, last_or, depth + 1);
        right := evaluate_jai_platform_condition(source, tokens, last_or + 1, end, depth + 1);
        if left == .yes || right == .yes return .yes;
        if left == .no && right == .no return .no;
        return .unknown;
    }
    if last_and >= 0 {
        left := evaluate_jai_platform_condition(source, tokens, first, last_and, depth + 1);
        right := evaluate_jai_platform_condition(source, tokens, last_and + 1, end, depth + 1);
        if left == .no || right == .no return .no;
        if left == .yes && right == .yes return .yes;
        return .unknown;
    }
    if jai_token_text(source, tokens[first]) == "!" {
        result := evaluate_jai_platform_condition(source, tokens, first + 1, end, depth + 1);
        if result == .unknown return .unknown;
        return ifx result == .yes then .no else .yes;
    }
    if end - first == 1 {
        text := jai_token_text(source, tokens[first]);
        if text == "true" return .yes;
        if text == "false" return .no;
    }

    if end - first != 4 || jai_token_text(source, tokens[first]) != "OS" ||
       !jai_punctuation(tokens[first + 2], .period) || tokens[first + 3].type != .identifier return .unknown;

    operation := jai_token_text(source, tokens[first + 1]);
    if operation != "==" && operation != "!=" return .unknown;
    same_os := jai_token_text(source, tokens[first + 3]) == JAI_DEFINITION_OS;
    return ifx same_os == (operation == "==") then .yes else .no;
}

JAI_DEFINITION_OS :: #run enum_value_to_name(OS);

mark_jai_platform_cases :: (source: string, tokens: [] Jai_Index_Token, body: s64, end: s64) {
    starts: [..] s64;
    starts.allocator = temp;
    auto_release_temp();

    selected: s64 = -1;
    default_case: s64 = -1;
    i := body + 1;
    while i < end {
        token := tokens[i];
        if token.type == .keyword && token.keyword == .kw_case {
            // Only filter a switch with simple platform labels and no fallthrough.
            if i + 1 < end && jai_punctuation(tokens[i + 1], .semicolon) {
                default_case = starts.count;
            } else if i + 3 < end && jai_punctuation(tokens[i + 1], .period) &&
                      tokens[i + 2].type == .identifier && jai_punctuation(tokens[i + 3], .semicolon) {
                if jai_token_text(source, tokens[i + 2]) == JAI_DEFINITION_OS then selected = starts.count;
            } else {
                return;
            }
            array_add(*starts, i);
        } else if token.type == .directive && token.directive == .directive_through {
            return;
        }
        i = ifx token.close >= 0 then token.close + 1 else i + 1;
    }

    if selected < 0 then selected = default_case;
    for start, j : starts {
        if j == selected continue;
        stop := ifx j + 1 < starts.count then starts[j + 1] else end;
        mark_inactive_jai_range(tokens, start, stop);
    }
}
